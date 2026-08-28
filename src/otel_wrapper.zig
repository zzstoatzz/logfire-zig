//! logfire-zig: otel-backed observability SDK for Logfire
//!
//! API modeled after Rust and Python Logfire SDKs.
//!
//! usage:
//!   const lf = try logfire.configure(.{
//!       .service_name = "my-service",
//!   });
//!   defer lf.shutdown();
//!
//!   logfire.info("server started on port {d}", .{port});
//!
//!   const span = logfire.span("http.request", .{ .method = "GET" });
//!   defer span.end();
//!
//!   logfire.counter("requests.total", 1);

const std = @import("std");
const io = std.Options.debug_io;
const otel = @import("otel");
const otel_api = otel.api;
const otel_sdk = otel.sdk;
const otel_exporters = otel.exporters;

const Config = @import("config").Config;

// ============================================================================
// global state (similar to Python's DEFAULT_LOGFIRE_INSTANCE)
// ============================================================================

var global_instance: ?*Logfire = null;
var global_allocator: ?std.mem.Allocator = null;

// ============================================================================
// thread-local span context tracking for parent-child relationships
// ============================================================================

/// thread-local current span context - enables parent-child span linking
threadlocal var tl_current_span_context: ?otel_api.trace.Span.Context = null;

// ============================================================================
// Logfire - main SDK type
// ============================================================================

pub const Logfire = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // otel providers
    trace_provider: ?*otel_sdk.trace.TracerProvider = null,
    log_provider: ?*otel_sdk.logs.LoggerProvider = null,

    // cached instruments
    tracer: ?otel_api.trace.Tracer = null,
    logger: ?otel_api.logs.Logger = null,

    // heap-allocated data that must outlive providers
    auth_header_value: ?[]u8 = null,
    headers: ?[]std.http.Header = null,

    const Self = @This();

    /// configure and return a Logfire instance
    /// also sets the global instance for convenience functions
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const resolved = config.resolve();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = resolved,
        };

        // set global state
        global_instance = self;
        global_allocator = allocator;

        // if not sending, return no-op instance
        if (!resolved.shouldSend()) {
            return self;
        }

        // set up OTLP exporter with Logfire endpoint
        if (resolved.token) |token| {
            const endpoint = getEndpointFromToken(token);

            // heap-allocate auth header (must outlive exporter)
            self.auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            errdefer if (self.auth_header_value) |v| allocator.free(v);

            self.headers = try allocator.alloc(std.http.Header, 1);
            errdefer if (self.headers) |h| allocator.free(h);

            self.headers.?[0] = .{
                .name = "Authorization",
                .value = self.auth_header_value.?,
            };

            const otlp_config = otel_exporters.otlp.OtlpExporterConfig{
                .endpoint = endpoint,
                .transport = .http_protobuf,
                .headers = self.headers.?,
            };

            // create trace provider manually to avoid OS-specific resource detection
            // (otel-zig's setupGlobalProvider uses detectResource which only supports macOS)
            const provider_ptr = try allocator.create(otel_sdk.trace.TracerProvider);
            errdefer allocator.destroy(provider_ptr);

            // create minimal resource with service name
            const resource = try createMinimalResource(allocator, resolved.service_name orelse "logfire-zig");
            errdefer resource.deinitOwned(allocator);

            provider_ptr.* = otel_sdk.trace.TracerProvider.init(
                allocator,
                resource,
                otel_sdk.trace.createDefaultIdGenerator(),
                otel_api.trace.Sampler{ .keep = {} },
            );

            // add OTLP exporter pipeline using BatchSpanProcessor for async export
            // (BasicSpanProcessor exports synchronously on every span.end(), causing latency)
            var builder = provider_ptr.pipelineBuilder();
            builder = builder.with(
                otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
                    .export_interval_ms = 500, // 500ms matches Python/Rust logfire
                    .max_queue_size = 2048,
                }).flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(otlp_config)),
            );
            try builder.done();

            // set as global provider (use tracerProvider() to get interface wrapper)
            try otel_api.provider_registry.setGlobalTracerProvider(provider_ptr.tracerProvider());
            self.trace_provider = provider_ptr;

            // get tracer
            const scope = otel_api.InstrumentationScope{
                .name = resolved.service_name orelse "logfire-zig",
                .version = resolved.service_version orelse "0.1.0",
            };
            self.tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

            // ----------------------------------------------------------------
            // log provider setup (mirrors trace provider above)
            //
            // identical pipeline shape: BatchLogRecordProcessor → OtlpLogExporter.
            // a separate Resource is built so each provider owns its memory
            // (the trace provider's Resource is freed in its own deinit).
            // ----------------------------------------------------------------
            const log_provider_ptr = try allocator.create(otel_sdk.logs.LoggerProvider);
            errdefer allocator.destroy(log_provider_ptr);

            const log_resource = try createMinimalResource(allocator, resolved.service_name orelse "logfire-zig");
            errdefer log_resource.deinitOwned(allocator);

            log_provider_ptr.* = otel_sdk.logs.LoggerProvider.init(allocator, log_resource);

            // otel-zig defaults `default_min_severity` to .warn in non-Debug
            // builds, which silently drops every info-level record before it
            // reaches the exporter. logfire-zig's contract is "ship what the
            // app emits"; let the application's `std.options.log_level` do
            // the filtering at compile time, not the OTEL layer at runtime.
            // matches the trace pipeline's `Sampler{ .keep = {} }` (no sampling).
            log_provider_ptr.default_min_severity = .trace;

            var log_builder = log_provider_ptr.pipelineBuilder();
            log_builder = log_builder.with(
                otel_sdk.logs.BatchLogRecordProcessor.PipelineStep.init(.{
                    .export_interval_ms = 500, // match trace cadence
                    .max_queue_size = 2048,
                }).flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(otlp_config)),
            );
            try log_builder.done();

            try otel_api.provider_registry.setGlobalLoggerProvider(log_provider_ptr.loggerProvider());
            self.log_provider = log_provider_ptr;

            // cache logger for the direct-emit path (logfire.info / .warn / etc.)
            self.logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

            // initialize the std.log bridge so std.log.* calls (from this app
            // and from any zig stdlib code) flow into the same OTEL pipeline.
            // applications opt in by setting:
            //     pub const std_options: std.Options = .{ .logFn = logfire.logFn };
            try otel_sdk.std_log_bridge.init(.{
                .instrumentation_scope_name = resolved.service_name orelse "logfire-zig",
                .instrumentation_scope_version = resolved.service_version orelse "0.1.0",
            });
        }

        return self;
    }

    /// shutdown and cleanup all resources
    pub fn shutdown(self: *Self) void {
        // tear down the std.log bridge first so any in-flight std.log.* calls
        // fall back to std.log.defaultLog rather than dispatching to a logger
        // whose provider is about to deinit.
        otel_sdk.std_log_bridge.deinit();

        if (self.trace_provider) |p| {
            _ = p.shutdown(null);
            p.deinit();
            p.destroy();
        }
        if (self.log_provider) |p| {
            _ = p.shutdown(null);
            p.deinit();
            p.destroy();
        }
        otel_api.provider_registry.unsetAllProviders();

        // free heap-allocated data
        if (self.headers) |h| self.allocator.free(h);
        if (self.auth_header_value) |v| self.allocator.free(v);

        // clear global state
        if (global_instance == self) {
            global_instance = null;
        }

        self.allocator.destroy(self);
    }

    /// force flush pending telemetry (traces and logs)
    pub fn flush(self: *Self) !void {
        if (self.trace_provider) |p| {
            _ = p.forceFlush(null);
        }
        if (self.log_provider) |p| {
            _ = p.forceFlush(null);
        }
    }

    // ========================================================================
    // spans
    // ========================================================================

    /// create a span with the given name and attributes, parented to the
    /// current span on this thread (if any)
    pub fn createSpan(self: *Self, name: []const u8, attrs: anytype) Span {
        return self.createSpanWithParent(name, attrs, tl_current_span_context);
    }

    /// create a span under an explicit parent. otel's answer to work that
    /// crosses a thread/task boundary is explicit context propagation — the
    /// spawning side captures `logfire.currentContext()` and the task starts
    /// its span with it. the new span becomes the current span on the
    /// calling thread until `end()`, so anything it calls nests normally.
    pub fn createSpanWithParent(self: *Self, name: []const u8, attrs: anytype, parent_context: ?SpanContext) Span {
        if (self.tracer) |*tracer| {
            const otel_attrs = attrsToOtel(attrs);
            const previous = tl_current_span_context;

            // build context with parent span if one exists
            var ctx_storage: [1]otel_api.ContextKeyValue = undefined;
            const ctx: []const otel_api.ContextKeyValue = if (parent_context) |parent| blk: {
                ctx_storage[0] = .{
                    .key = otel_api.trace.context_keys.active_span_context_key.key_id,
                    .value = otel_api.trace.context_keys.active_span_context_key.wrapValue(parent),
                };
                break :blk &ctx_storage;
            } else &[_]otel_api.ContextKeyValue{};

            const span_result = tracer.startSpan(name, .{
                .kind = .internal,
                .attributes = otel_attrs,
            }, ctx) catch {
                return .{ .inner = null, .parent_context = previous };
            };

            // update thread-local context with new span
            tl_current_span_context = span_result.getSpanContext();

            return .{ .inner = span_result, .parent_context = previous };
        }
        return .{ .inner = null, .parent_context = null };
    }

    // ========================================================================
    // logging
    // ========================================================================

    pub fn logMessage(self: *Self, comptime level: Config.Level, comptime fmt: []const u8, args: anytype) void {
        // console output if enabled (kept regardless of OTEL emission so local
        // dev output still works without a logfire token).
        if (self.config.console) |console| {
            if (console.enabled and @intFromEnum(level) >= @intFromEnum(console.min_level)) {
                std.debug.print("[{s}] ", .{level.name()});
                std.debug.print(fmt ++ "\n", args);
            }
        }

        // emit to otel logger if wired up. fmt + args are formatted into a
        // stack buffer (truncated past 2KiB to avoid heap allocation in the
        // hot logging path).
        if (self.logger) |*logger| {
            const severity = configLevelToSeverity(level);
            // mirror std_log_bridge's empty-context call shape — span context
            // attachment is a future improvement (see notes/observability/
            // logfire-clients.md).
            const empty_ctx: []const otel_api.ContextKeyValue = &.{};
            if (!logger.enabled(empty_ctx, severity)) return;

            var msg_buf: [2048]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch
                msg_buf[0 .. msg_buf.len - 12] ++ " [truncated]";

            logger.emitLogRecord(
                empty_ctx,
                severity,
                .{ .string = msg },
                null, // attributes
                @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)),
                null, // observed_timestamp_ns
                null, // event_name
                null, // severity_text
                null, // trace_id
                null, // span_id
                null, // flags
            );
        }
    }
};

/// Map config-level severity values to the otel-zig logs API enum.
fn configLevelToSeverity(level: Config.Level) otel_api.logs.Severity {
    return switch (level) {
        .trace => .trace,
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .@"error",
    };
}

// ============================================================================
// Span wrapper
// ============================================================================

/// span status codes (per otel semantic conventions)
pub const StatusCode = enum {
    /// default - status not explicitly set
    unset,
    /// operation completed successfully
    ok,
    /// operation failed
    @"error",
};

/// an opaque handle to a span's identity (trace id + span id), safe to copy
/// across threads. capture with `currentContext()` or `Span.context()`.
pub const SpanContext = otel_api.trace.Span.Context;

pub const Span = struct {
    inner: ?otel_api.trace.Span,
    /// the thread's current context before this span started; restored on end
    parent_context: ?SpanContext,

    /// this span's context, for parenting work on another thread/task
    pub fn context(self: *const Span) ?SpanContext {
        if (self.inner) |*s| return @constCast(s).getSpanContext();
        return null;
    }

    /// end the span - takes *const for API compatibility with legacy logfire
    pub fn end(self: *const Span) void {
        if (self.inner != null) {
            // use @constCast for API compatibility (allows const span = ... pattern)
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                s.end(null);
                s.deinit();
                mutable.inner = null;

                // restore parent context (enables proper nesting)
                tl_current_span_context = mutable.parent_context;
            }
        }
    }

    pub fn setAttribute(self: *const Span, key: []const u8, value: anytype) void {
        if (self.inner != null) {
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                if (toOtelValue(value)) |val| {
                    s.setAttribute(.{ .key = key, .value = val });
                }
            }
        }
    }

    /// set span status (call with .@"error" to mark failures)
    pub fn setStatus(self: *const Span, code: StatusCode, description: ?[]const u8) void {
        if (self.inner != null) {
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                s.setStatus(.{
                    .code = switch (code) {
                        .unset => .unset,
                        .ok => .ok,
                        .@"error" => .@"error",
                    },
                    .description = description,
                });
            }
        }
    }

    /// record an error on the span (adds event + sets error status)
    pub fn recordError(self: *const Span, e: anyerror) void {
        if (self.inner != null) {
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                // otel API calls this "exception" but we use zig-idiomatic naming
                s.recordException(e, null, null) catch {};
                s.setStatus(.{
                    .code = .@"error",
                    .description = @errorName(e),
                });
            }
        }
    }
};

// ============================================================================
// convenience functions (use global instance)
// ============================================================================

/// configure logfire with the given options
/// returns the configured instance
pub fn configure(config: Config) !*Logfire {
    const allocator = std.heap.page_allocator;
    return Logfire.init(allocator, config);
}

/// create a span (uses global instance)
pub fn span(name: []const u8, attrs: anytype) Span {
    if (global_instance) |lf| {
        return lf.createSpan(name, attrs);
    }
    return .{ .inner = null, .parent_context = null };
}

/// the current span's context on this thread, or null. capture it before
/// spawning work elsewhere and hand it to `spanWithParent` there.
pub fn currentContext() ?SpanContext {
    return tl_current_span_context;
}

/// create a span under an explicit parent (see `Logfire.createSpanWithParent`)
pub fn spanWithParent(parent: ?SpanContext, name: []const u8, attrs: anytype) Span {
    if (global_instance) |lf| {
        return lf.createSpanWithParent(name, attrs, parent);
    }
    return .{ .inner = null, .parent_context = null };
}

/// log at trace level
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.trace, fmt, args);
}

/// log at debug level
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.debug, fmt, args);
}

/// log at info level
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.info, fmt, args);
}

/// log at warn level
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.warn, fmt, args);
}

/// log at error level
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.err, fmt, args);
}

// ============================================================================
// std.log integration
// ============================================================================

/// Drop-in for `std.options.logFn`. Routes every `std.log.*` call (from this
/// app and from any zig stdlib code that uses `std.log`) into the OTEL log
/// pipeline configured by `Logfire.init`. Falls back to `std.log.defaultLog`
/// (stderr) until `Logfire.init` runs and brings up the LoggerProvider.
///
/// Wire it up once in your application root:
/// ```zig
/// const logfire = @import("logfire");
/// pub const std_options: std.Options = .{
///     .log_level = .info,
///     .logFn = logfire.logFn,
/// };
/// ```
///
/// Implemented by re-exporting `otel-zig`'s `std_log_bridge.otelLogFn`.
/// `Logfire.init` calls `std_log_bridge.init(...)` which makes this active.
pub const logFn = otel_sdk.std_log_bridge.otelLogFn;

// ============================================================================
// metrics (stubs for now - TODO: implement with otel metrics)
// ============================================================================

pub fn counter(name: []const u8, value: i64) void {
    _ = name;
    _ = value;
    // TODO: implement with otel-zig metrics
}

pub fn counterWithOpts(name: []const u8, value: i64, opts: anytype) void {
    _ = name;
    _ = value;
    _ = opts;
}

pub fn gaugeInt(name: []const u8, value: i64) void {
    _ = name;
    _ = value;
}

pub fn gaugeDouble(name: []const u8, value: f64) void {
    _ = name;
    _ = value;
}

// ============================================================================
// instrumentation helpers (HTTP, SQL)
// ============================================================================

/// create an HTTP span with formatted name: "HTTP {method} {path}"
/// adds standard http.request.method and url.path attributes
pub fn httpSpan(method: []const u8, path: []const u8, attrs: anytype) Span {
    var name_buf: [256]u8 = undefined;
    const span_name = std.fmt.bufPrint(&name_buf, "HTTP {s} {s}", .{ method, path }) catch "HTTP request";

    // merge standard HTTP attrs with user attrs
    const T = @TypeOf(attrs);
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".fields.len > 0) {
        // user provided extra attrs - for now just use standard ones
        // TODO: merge attrs properly
        return span(span_name, .{
            .@"http.request.method" = method,
            .@"url.path" = path,
        });
    } else {
        return span(span_name, .{
            .@"http.request.method" = method,
            .@"url.path" = path,
        });
    }
}

/// create a SQL span with truncated query as name
/// adds db.system attribute
pub fn sqlSpan(sql: []const u8, db_system: []const u8) Span {
    var name_buf: [128]u8 = undefined;
    const span_name = truncateSql(&name_buf, sql);
    return span(span_name, .{ .@"db.system" = db_system });
}

/// truncate SQL for display (max 60 chars, break at word boundary)
fn truncateSql(buf: []u8, sql: []const u8) []const u8 {
    const max_len: usize = 60;
    if (sql.len <= max_len) {
        return std.fmt.bufPrint(buf, "{s}", .{sql}) catch sql[0..@min(sql.len, buf.len)];
    }

    // find a good break point (space)
    var end: usize = max_len;
    while (end > 40 and sql[end] != ' ') : (end -= 1) {}
    if (end <= 40) end = max_len;

    return std.fmt.bufPrint(buf, "{s}...", .{sql[0..end]}) catch sql[0..@min(sql.len, buf.len)];
}

// ============================================================================
// helpers
// ============================================================================

/// create a minimal resource without OS-specific detection
/// this avoids otel-zig's ProcessDetector which only supports macOS
fn createMinimalResource(allocator: std.mem.Allocator, service_name: []const u8) !otel_sdk.resource.Resource {
    const builtin = @import("builtin");

    // build attributes
    var attrs = otel_api.common.AttributeBuilder.init(allocator);

    // telemetry SDK info
    attrs = attrs.add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "logfire-zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.version", .value = .{ .string = "0.1.0" } });

    // service name
    attrs = attrs.add(.{ .key = "service.name", .value = .{ .string = service_name } });

    // process.pid (works on all POSIX systems)
    const pid = std.c.getpid();
    attrs = attrs.add(.{ .key = "process.pid", .value = .{ .int = @intCast(pid) } });

    // process.executable.name via /proc/self/exe (Linux) or _NSGetExecutablePath (macOS)
    switch (builtin.os.tag) {
        .linux => {
            // read /proc/self/exe symlink
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buf)) |len| {
                const path = buf[0..len];
                const basename = std.fs.path.basename(path);
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, basename);
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            } else |_| {}
        },
        .macos => {
            var size: u32 = std.fs.max_path_bytes;
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (std.c._NSGetExecutablePath(&buf, &size) == 0) {
                const path = std.mem.sliceTo(&buf, 0);
                const basename = std.fs.path.basename(path);
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, basename);
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            }
        },
        else => {}, // skip executable info on other OSes
    }

    return try otel_sdk.resource.Resource.initOwnedFromBuilder(allocator, null, &attrs);
}

fn getEndpointFromToken(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "pylf_v")) {
        var it = std.mem.splitScalar(u8, token, '_');
        _ = it.next(); // pylf
        _ = it.next(); // v1
        if (it.next()) |region| {
            if (std.mem.eql(u8, region, "eu")) {
                return "https://logfire-eu.pydantic.dev:443";
            }
        }
    }
    return "https://logfire-us.pydantic.dev:443";
}

fn toOtelValue(value: anytype) ?otel_api.common.AttributeValue {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .bool => .{ .bool = value },
        .optional => {
            // handle optional types - return null if the value is null
            if (value) |v| {
                return toOtelValue(v);
            }
            return null;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string = value };
            }
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    return .{ .string = value };
                }
            }
            @compileError("unsupported pointer type");
        },
        else => @compileError("unsupported type for attribute: " ++ @typeName(T)),
    };
}

fn attrsToOtel(attrs: anytype) []const otel_api.common.AttributeKeyValue {
    const T = @TypeOf(attrs);
    if (@typeInfo(T) != .@"struct") {
        return &[_]otel_api.common.AttributeKeyValue{};
    }

    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) {
        return &[_]otel_api.common.AttributeKeyValue{};
    }

    // use static storage per type - populated at runtime
    // note: not thread-safe, but attributes are copied by otel-zig immediately
    const Storage = struct {
        var result: [fields.len]otel_api.common.AttributeKeyValue = undefined;
        var count: usize = 0;
    };

    Storage.count = 0;
    inline for (fields) |field| {
        if (toOtelValue(@field(attrs, field.name))) |val| {
            Storage.result[Storage.count] = .{
                .key = field.name,
                .value = val,
            };
            Storage.count += 1;
        }
    }
    return Storage.result[0..Storage.count];
}

// ============================================================================
// tests
// ============================================================================

// note: config.zig has its own tests but is set up as a separate build
// module, so it can't be `@import("config.zig")`'d here for test discovery.
// build.zig has a separate `test-config` target that runs them.

test "configLevelToSeverity maps every Config.Level" {
    const testing = std.testing;
    try testing.expectEqual(otel_api.logs.Severity.trace, configLevelToSeverity(.trace));
    try testing.expectEqual(otel_api.logs.Severity.debug, configLevelToSeverity(.debug));
    try testing.expectEqual(otel_api.logs.Severity.info, configLevelToSeverity(.info));
    try testing.expectEqual(otel_api.logs.Severity.warn, configLevelToSeverity(.warn));
    try testing.expectEqual(otel_api.logs.Severity.@"error", configLevelToSeverity(.err));
}

test "logFn signature matches std.options.logFn shape" {
    // Compile-time sanity check: `logFn` must be assignable to a value of
    // type `@TypeOf(std.log.defaultLog)`. If otel-zig changes the bridge
    // signature, this fails the build instead of the deploy.
    const expected_fn_ptr: @TypeOf(std.log.defaultLog) = logFn;
    _ = expected_fn_ptr;
}

test "logFn falls back to defaultLog when bridge not initialized" {
    // logFn must be safe to call before `Logfire.init` runs (and the bridge
    // gets initialized inside it). otel-zig's bridge handles this with a
    // fast-path check on its own atomic init flag.
    logFn(.info, .testing, "boot-time message: {d}", .{42});
}

test "toOtelValue covers every primitive attribute type" {
    // float attributes went uncovered until 2026-08-28: the arm wrote
    // `.double`, otel-zig's union spells it `.float`, and nothing here
    // instantiated the comptime branch — consumers only found out when they
    // passed an f64 into `logfire.span(...)` and the build failed.
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 0.5), toOtelValue(@as(f64, 0.5)).?.float);
    try testing.expectEqual(@as(f64, 0.25), toOtelValue(@as(f32, 0.25)).?.float);
    try testing.expectEqual(@as(f64, 1.5), toOtelValue(1.5).?.float);
    try testing.expectEqual(@as(i64, 7), toOtelValue(@as(u32, 7)).?.int);
    try testing.expectEqual(true, toOtelValue(true).?.bool);
    try testing.expectEqualStrings("s", toOtelValue(@as([]const u8, "s")).?.string);
    try testing.expectEqualStrings("lit", toOtelValue("lit").?.string);
    try testing.expect(toOtelValue(@as(?f64, null)) == null);

    const attrs = attrsToOtel(.{ .alpha = @as(f64, 0.5), .top_k = @as(i64, 3), .skipped = @as(?i64, null) });
    try testing.expectEqual(@as(usize, 2), attrs.len);
    try testing.expectEqualStrings("alpha", attrs[0].key);
    try testing.expectEqual(@as(f64, 0.5), attrs[0].value.float);
}

test "explicit parent context api is usable before configure" {
    // without a configured instance every span is a no-op; the api must
    // still compose so call sites don't need to know whether export is on
    const testing = std.testing;
    try testing.expect(currentContext() == null);
    const outer = span("outer", .{});
    defer outer.end();
    const captured = outer.context();
    const inner = spanWithParent(captured, "inner", .{});
    defer inner.end();
    try testing.expect(inner.context() == null);
}
