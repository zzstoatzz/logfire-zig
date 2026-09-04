//! logfire-zig: otel-backed observability SDK for Logfire
//!
//! API modeled after the Rust and Python Logfire SDKs. Three surfaces, one
//! pipeline:
//!
//!   - spans:   `logfire.span("name", .{ .attr = value })` — batched OTLP export,
//!              a pending span published at start so long work is visible live
//!   - logs:    every `std.log.*` call, through `std.options.logFn = logfire.logFn`,
//!              carrying the current span's trace/span id and the std.log scope
//!   - exit:    `logfire.flush()` before any `std.process.exit` (bounded: at
//!              most `exit_flush_timeout_ms` per provider), and
//!              `pub const panic = std.debug.FullPanic(logfire.panicFn)` so a
//!              panic's trace reaches stderr and its message ships before
//!              the process dies
//!
//! usage:
//!   const logfire = @import("logfire");
//!   pub const std_options: std.Options = .{ .log_level = .info, .logFn = logfire.logFn };
//!   pub const panic = std.debug.FullPanic(logfire.panicFn);
//!
//!   pub fn main() !void {
//!       const lf = try logfire.configure(.{ .service_name = "my-service" });
//!       defer lf.shutdown();
//!       const span = logfire.span("http.request", .{ .method = "GET" });
//!       defer span.end();
//!       std.log.info("handled", .{});   // rendered under the span in logfire
//!   }

const std = @import("std");
const io = std.Options.debug_io;
const otel = @import("otel");
const otel_api = otel.api;
const otel_sdk = otel.sdk;
const otel_exporters = otel.exporters;
const build_options = @import("build_options");

const Config = @import("config").Config;

/// the package version from build.zig.zon, reported as telemetry.sdk.version
pub const version = build_options.version;

// ============================================================================
// logfire attribute conventions (shared with the python and rust clients)
// ============================================================================

/// span attribute keys the logfire backend interprets
pub const attr = struct {
    /// "span" (default), "pending_span" (emitted at start), "log"
    pub const span_type = "logfire.span_type";
    /// on a pending span: the real span's parent, hex
    pub const pending_parent_id = "logfire.pending_parent_id";
    /// OTEL severity number; 17 marks a span as errored in the UI
    pub const level_num = "logfire.level_num";
};

const LEVEL_NUM_ERROR: i64 = 17;

// ============================================================================
// global state (similar to Python's DEFAULT_LOGFIRE_INSTANCE)
// ============================================================================

var global_instance: ?*Logfire = null;

/// thread-local current span context - enables parent-child span linking
threadlocal var tl_current_span_context: ?otel_api.trace.Span.Context = null;

// ============================================================================
// Logfire - main SDK type
// ============================================================================

pub const Logfire = struct {
    allocator: std.mem.Allocator,
    config: Config,

    trace_provider: ?*otel_sdk.trace.TracerProvider = null,
    log_provider: ?*otel_sdk.logs.LoggerProvider = null,
    pending: ?*PendingSpanEmitter = null,

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

        global_instance = self;

        if (!resolved.shouldSend()) return self;

        const token = resolved.token orelse return self;
        const endpoint = resolved.base_url orelse getEndpointFromToken(token);

        // heap-allocate auth header (must outlive exporter)
        self.auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        errdefer if (self.auth_header_value) |v| allocator.free(v);

        self.headers = try allocator.alloc(std.http.Header, 1);
        errdefer if (self.headers) |h| allocator.free(h);
        self.headers.?[0] = .{ .name = "Authorization", .value = self.auth_header_value.? };

        const otlp_config = otel_exporters.otlp.OtlpExporterConfig{
            .endpoint = endpoint,
            .transport = .http_protobuf,
            .headers = self.headers.?,
        };

        const scope = otel_api.InstrumentationScope{
            .name = resolved.service_name orelse "logfire-zig",
            .version = resolved.service_version,
        };

        // ------------------------------------------------------------------
        // traces: BatchSpanProcessor → OTLP, plus the pending-span emitter
        // ------------------------------------------------------------------
        const provider_ptr = try allocator.create(otel_sdk.trace.TracerProvider);
        errdefer allocator.destroy(provider_ptr);

        // providers are created directly rather than through setupGlobalProvider,
        // whose resource detection only supports macOS; each provider gets its
        // own Resource because each frees it in its own deinit.
        const resource = try buildResource(allocator, resolved);
        errdefer resource.deinitOwned(allocator);

        provider_ptr.* = otel_sdk.trace.TracerProvider.init(
            allocator,
            resource,
            otel_sdk.trace.createDefaultIdGenerator(),
            otel_api.trace.Sampler{ .keep = {} },
        );

        var batch: *otel_sdk.trace.BatchSpanProcessor = undefined;
        var builder = provider_ptr.pipelineBuilder();
        builder = builder.withCaptured(
            otel_sdk.trace.BatchSpanProcessor.PipelineStep.init(.{
                .export_interval_ms = @intCast(resolved.batch_timeout_ms),
                .max_queue_size = 2048,
            }).flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(otlp_config)),
            &batch,
        );
        try builder.done();

        if (resolved.pending_spans) {
            const pending = try allocator.create(PendingSpanEmitter);
            errdefer allocator.destroy(pending);
            pending.* = .{ .allocator = allocator, .sink = batch.spanProcessor() };
            try provider_ptr.registerProcessor(.{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(pending) });
            self.pending = pending;
        }

        try otel_api.provider_registry.setGlobalTracerProvider(provider_ptr.tracerProvider());
        self.trace_provider = provider_ptr;
        self.tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

        // ------------------------------------------------------------------
        // logs: BatchLogRecordProcessor → OTLP, fed by std.log through the bridge
        // ------------------------------------------------------------------
        const log_provider_ptr = try allocator.create(otel_sdk.logs.LoggerProvider);
        errdefer allocator.destroy(log_provider_ptr);

        const log_resource = try buildResource(allocator, resolved);
        errdefer log_resource.deinitOwned(allocator);

        log_provider_ptr.* = otel_sdk.logs.LoggerProvider.init(allocator, log_resource);

        // otel-zig defaults `default_min_severity` to .warn in non-Debug builds,
        // which silently drops every info-level record before it reaches the
        // exporter. The contract here is "ship what the app emits"; the
        // application's `std.options.log_level` filters at compile time.
        log_provider_ptr.default_min_severity = .trace;

        var log_builder = log_provider_ptr.pipelineBuilder();
        log_builder = log_builder.with(
            otel_sdk.logs.BatchLogRecordProcessor.PipelineStep.init(.{
                .export_interval_ms = @intCast(resolved.batch_timeout_ms),
                .max_queue_size = 2048,
            }).flowTo(otel_exporters.otlp.OtlpLogExporter.PipelineStep.init(otlp_config)),
        );
        try log_builder.done();

        try otel_api.provider_registry.setGlobalLoggerProvider(log_provider_ptr.loggerProvider());
        self.log_provider = log_provider_ptr;
        self.logger = try otel_api.getGlobalLoggerProvider().getLoggerWithScope(scope);

        // std.log → OTEL. Keeps stderr when console output is on (fly logs,
        // journald, a terminal all read stderr) and attaches the current span
        // so records render under their span.
        try otel_sdk.std_log_bridge.init(.{
            .instrumentation_scope_name = scope.name,
            .instrumentation_scope_version = scope.version,
            .include_scope_attribute = true,
            .also_default_log = if (resolved.console) |c| c.enabled else false,
            .span_context_fn = currentContext,
        });

        return self;
    }

    /// flush what is pending, then tear everything down. After this, std.log
    /// falls back to stderr and every span/log call is a no-op.
    pub fn shutdown(self: *Self) void {
        // tear down the std.log bridge first so any in-flight std.log.* calls
        // fall back to std.log.defaultLog rather than dispatching to a logger
        // whose provider is about to deinit.
        otel_sdk.std_log_bridge.deinit();

        if (self.trace_provider) |p| {
            _ = p.shutdown(exit_flush_timeout_ms);
            p.deinit(); // deinits + destroys every registered processor, the pending emitter included
            self.allocator.destroy(p);
        }
        if (self.log_provider) |p| {
            _ = p.shutdown(exit_flush_timeout_ms);
            p.deinit();
            p.destroy();
        }
        otel_api.provider_registry.unsetAllProviders();

        if (self.headers) |h| self.allocator.free(h);
        if (self.auth_header_value) |v| self.allocator.free(v);

        if (global_instance == self) global_instance = null;
        self.allocator.destroy(self);
    }

    /// flush pending telemetry (traces and logs), waiting at most
    /// `exit_flush_timeout_ms` per provider. Never unbounded: a flush runs on
    /// exit paths (watchdogs, panics), and an unbounded wait on a wedged or
    /// dead export thread turns "exit for restart" into a hang. 2026-09-03: a
    /// process panicked on its export thread, the panic hook waited for that
    /// export to finish, and the watchdog that fired ten minutes later waited
    /// on the same thing; the process sat alive and dead for 22 hours.
    pub fn flush(self: *Self) void {
        self.flushWithin(exit_flush_timeout_ms);
    }

    /// flush with an explicit per-provider bound in milliseconds
    pub fn flushWithin(self: *Self, timeout_ms: u64) void {
        if (self.trace_provider) |p| _ = p.forceFlush(timeout_ms);
        if (self.log_provider) |p| _ = p.forceFlush(timeout_ms);
    }

    // ========================================================================
    // spans
    // ========================================================================

    /// create a span parented to the current span on this thread (if any)
    pub fn createSpan(self: *Self, name: []const u8, attrs: anytype) Span {
        return self.createSpanWithParent(name, attrs, tl_current_span_context);
    }

    /// create a span under an explicit parent. otel's answer to work that
    /// crosses a thread/task boundary is explicit context propagation — the
    /// spawning side captures `logfire.currentContext()` and the task starts
    /// its span with it. the new span becomes the current span on the
    /// calling thread until `end()`, so anything it calls nests normally.
    pub fn createSpanWithParent(self: *Self, name: []const u8, attrs: anytype, parent_context: ?SpanContext) Span {
        var storage = AttrStorage(attrCount(@TypeOf(attrs))){};
        appendAttrs(&storage, attrs);
        return self.createSpanRaw(name, storage.slice(), parent_context);
    }

    fn createSpanRaw(self: *Self, name: []const u8, otel_attrs: []const otel_api.common.AttributeKeyValue, parent_context: ?SpanContext) Span {
        const tracer = if (self.tracer) |*t| t else return .{ .inner = null, .parent_context = null };
        const previous = tl_current_span_context;

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

        tl_current_span_context = span_result.getSpanContext();
        return .{ .inner = span_result, .parent_context = previous };
    }

    // ========================================================================
    // logging (direct api; std.log through logFn is the preferred surface)
    // ========================================================================

    pub fn logMessage(self: *Self, comptime level: Config.Level, comptime fmt: []const u8, args: anytype) void {
        if (self.config.console) |console| {
            if (console.enabled and @intFromEnum(level) >= @intFromEnum(console.min_level)) {
                std.debug.print("[{s}] ", .{level.name()});
                std.debug.print(fmt ++ "\n", args);
            }
        }

        const logger = if (self.logger) |*l| l else return;
        const severity = configLevelToSeverity(level);
        const empty_ctx: []const otel_api.ContextKeyValue = &.{};
        if (!logger.enabled(empty_ctx, severity)) return;

        // formatted into a stack buffer (truncated past 2KiB to avoid heap
        // allocation in the hot logging path)
        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch
            msg_buf[0 .. msg_buf.len - 12] ++ " [truncated]";

        const span_ctx = tl_current_span_context;
        logger.emitLogRecord(
            empty_ctx,
            severity,
            .{ .string = msg },
            null,
            @as(i64, @intCast(std.Io.Timestamp.now(io, .real).nanoseconds)),
            null,
            null,
            level.name(),
            if (span_ctx) |c| c.trace_id else null,
            if (span_ctx) |c| c.span_id else null,
            if (span_ctx) |c| c.trace_flags else null,
        );
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
// pending spans
// ============================================================================

/// Publishes a copy of every span the moment it starts, tagged
/// `logfire.span_type = pending_span`, so the logfire live view shows work in
/// progress instead of only work that has finished. Mirrors logfire-rust's
/// PendingSpanProcessor: the copy gets a fresh span id, is parented to the
/// real span, and closes at the real span's start time; the backend replaces
/// it when the real span arrives. Registered AFTER the batch processor it
/// feeds, so it only handles onStart — the real span's onEnd is the batch
/// processor's own.
pub const PendingSpanEmitter = struct {
    allocator: std.mem.Allocator,
    sink: otel_sdk.trace.SpanProcessor,
    emitted: std.atomic.Value(u64) = .init(0),

    /// attributes beyond this are rare; a span that exceeds it simply has no
    /// pending copy rather than a heap allocation on every start
    const MAX_ATTRS = 62;

    pub fn spanLimits(_: *PendingSpanEmitter) otel_api.trace.Span.Limits {
        return .default;
    }

    pub fn onStart(self: *PendingSpanEmitter, started: otel_sdk.trace.SpanData, resource: otel_sdk.resource.Resource) void {
        if (started.attributes.len > MAX_ATTRS) return;
        for (started.attributes) |kv| {
            // a span that already declares a non-default type (a log, another pending copy) gets no pending copy
            if (std.mem.eql(u8, kv.key, attr.span_type)) return;
        }

        var attrs: [MAX_ATTRS + 2]otel_api.common.AttributeKeyValue = undefined;
        var n: usize = 0;
        for (started.attributes) |kv| {
            attrs[n] = kv;
            n += 1;
        }
        attrs[n] = .{ .key = attr.span_type, .value = .{ .string = "pending_span" } };
        n += 1;
        var parent_hex: [16]u8 = undefined;
        if (started.parent_ctx) |parent| {
            parent.span_id.toHexString(&parent_hex);
            attrs[n] = .{ .key = attr.pending_parent_id, .value = .{ .string = &parent_hex } };
            n += 1;
        }

        var sink = self.sink;
        sink.onEnd(.{
            .scope = started.scope,
            .ctx = .{
                .trace_id = started.ctx.trace_id,
                .span_id = otel_api.common.SpanId.fromBytes(otel_sdk.trace.generateSpanId()),
                .trace_flags = started.ctx.trace_flags,
                .trace_state = null,
                .is_remote = false,
            },
            .parent_ctx = started.ctx,
            .name = started.name,
            .kind = started.kind,
            .status = started.status,
            .start_time = started.start_time,
            .end_time = started.start_time,
            .attributes = attrs[0..n],
            .events = &.{},
            .links = started.links,
        }, resource);
        _ = self.emitted.fetchAdd(1, .monotonic);
    }

    pub fn onEnd(_: *PendingSpanEmitter, _: otel_sdk.trace.SpanData, _: otel_sdk.resource.Resource) void {}
    pub fn forceFlush(_: *PendingSpanEmitter, _: ?u64) otel_api.common.FlushResult {
        return .success;
    }
    pub fn shutdown(_: *PendingSpanEmitter, _: ?u64) otel_api.common.ProcessResult {
        return .success;
    }
    pub fn deinit(_: *PendingSpanEmitter) void {}
    pub fn destroy(self: *PendingSpanEmitter) void {
        self.allocator.destroy(self);
    }
};

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

    /// end the span - takes *const so `const span = ...; defer span.end();` works
    pub fn end(self: *const Span) void {
        const mutable = @constCast(self);
        if (mutable.inner) |*s| {
            s.end(null);
            s.deinit();
            mutable.inner = null;
            tl_current_span_context = mutable.parent_context;
        }
    }

    pub fn setAttribute(self: *const Span, key: []const u8, value: anytype) void {
        const mutable = @constCast(self);
        if (mutable.inner) |*s| {
            if (toOtelValue(value)) |val| s.setAttribute(.{ .key = key, .value = val });
        }
    }

    /// set span status. `.@"error"` also stamps `logfire.level_num = 17` so
    /// the span renders as errored in the logfire UI.
    pub fn setStatus(self: *const Span, code: StatusCode, description: ?[]const u8) void {
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
            if (code == .@"error") s.setAttribute(.{ .key = attr.level_num, .value = .{ .int = LEVEL_NUM_ERROR } });
        }
    }

    /// record an error on the span (adds exception event + sets error status)
    pub fn recordError(self: *const Span, e: anyerror) void {
        const mutable = @constCast(self);
        if (mutable.inner) |*s| {
            s.recordException(e, null, null) catch {};
        }
        self.setStatus(.@"error", @errorName(e));
    }
};

// ============================================================================
// convenience functions (use global instance)
// ============================================================================

/// configure logfire with the given options
/// returns the configured instance
pub fn configure(config: Config) !*Logfire {
    return Logfire.init(std.heap.page_allocator, config);
}

/// create a span (uses global instance)
pub fn span(name: []const u8, attrs: anytype) Span {
    if (global_instance) |lf| return lf.createSpan(name, attrs);
    return .{ .inner = null, .parent_context = null };
}

/// the current span's context on this thread, or null. capture it before
/// spawning work elsewhere and hand it to `spanWithParent` there.
pub fn currentContext() ?SpanContext {
    return tl_current_span_context;
}

/// create a span under an explicit parent (see `Logfire.createSpanWithParent`)
pub fn spanWithParent(parent: ?SpanContext, name: []const u8, attrs: anytype) Span {
    if (global_instance) |lf| return lf.createSpanWithParent(name, attrs, parent);
    return .{ .inner = null, .parent_context = null };
}

/// the most any exit-path flush waits, per provider. Export batches every
/// `batch_timeout_ms` (500 ms default) and the OTLP transport retries inside
/// its own budget, so a healthy exporter finishes well inside this; an
/// unhealthy one must not hold the process.
pub const exit_flush_timeout_ms: u64 = 3000;

/// a panic gets less: the process is dying and the trace is already on stderr
pub const panic_flush_timeout_ms: u64 = 1500;

/// flush pending spans and logs now, waiting at most
/// `exit_flush_timeout_ms` per provider. Call before `std.process.exit`: the
/// batch processors export on a timer, so anything emitted in the last
/// `batch_timeout_ms` is still in memory when the process ends. A watchdog
/// that logs "no progress, exiting" and exits without this ships nothing —
/// and one that waits on this without a bound never exits.
pub fn flush() void {
    if (global_instance) |lf| lf.flush();
}

/// flush with an explicit per-provider bound in milliseconds
pub fn flushWithin(timeout_ms: u64) void {
    if (global_instance) |lf| lf.flushWithin(timeout_ms);
}

/// flush and tear down the global instance (idempotent, bounded)
pub fn shutdown() void {
    if (global_instance) |lf| lf.shutdown();
}

var panicking = std.atomic.Value(bool).init(false);

/// a `std.debug.FullPanic` hook that ships the panic message before dying:
///   pub const panic = std.debug.FullPanic(logfire.panicFn);
///
/// Order matters. The message and stack trace go to stderr FIRST, because
/// stderr is what the host captures whether or not export ever completes.
/// Then the message is logged and flushed within `panic_flush_timeout_ms`.
/// A panic raised while this hook runs (from inside the telemetry path)
/// skips straight to the default handler instead of re-entering it.
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (panicking.swap(true, .acq_rel)) std.debug.defaultPanic(msg, first_trace_addr);

    std.debug.print("panic: {s}\n", .{msg});
    std.debug.dumpCurrentStackTrace(.{ .first_address = first_trace_addr });

    std.log.err("panic: {s}", .{msg});
    flushWithin(panic_flush_timeout_ms);
    std.process.abort();
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
/// pipeline configured by `Logfire.init`, keeps writing to stderr while
/// console output is enabled, and attaches the current span. Falls back to
/// `std.log.defaultLog` (stderr only) until `Logfire.init` runs.
///
/// Wire it up once in your application root:
/// ```zig
/// const logfire = @import("logfire");
/// pub const std_options: std.Options = .{
///     .log_level = .info,
///     .logFn = logfire.logFn,
/// };
/// ```
pub const logFn = otel_sdk.std_log_bridge.otelLogFn;

// ============================================================================
// metrics (stubs - TODO: implement with otel-zig metrics)
// ============================================================================

pub fn counter(name: []const u8, value: i64) void {
    _ = name;
    _ = value;
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

/// create an HTTP span named "HTTP {method} {path}" with the semconv
/// `http.request.method` and `url.path` attributes, plus any extra attrs
pub fn httpSpan(method: []const u8, path: []const u8, attrs: anytype) Span {
    var name_buf: [256]u8 = undefined;
    const span_name = std.fmt.bufPrint(&name_buf, "HTTP {s} {s}", .{ method, path }) catch "HTTP request";

    var storage = AttrStorage(attrCount(@TypeOf(attrs)) + 2){};
    storage.push("http.request.method", .{ .string = method });
    storage.push("url.path", .{ .string = path });
    appendAttrs(&storage, attrs);

    if (global_instance) |lf| return lf.createSpanRaw(span_name, storage.slice(), tl_current_span_context);
    return .{ .inner = null, .parent_context = null };
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

/// The resource every signal is tagged with. Detection is hand-rolled: the
/// SDK's ProcessDetector only supports macOS, and the process.* fields it
/// would add are the two below anyway.
fn buildResource(allocator: std.mem.Allocator, config: Config) !otel_sdk.resource.Resource {
    const builtin = @import("builtin");

    var attrs = otel_api.common.AttributeBuilder.init(allocator);
    attrs = attrs.add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "logfire-zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.version", .value = .{ .string = version } });
    attrs = attrs.add(.{ .key = "service.name", .value = .{ .string = config.service_name orelse "logfire-zig" } });
    if (config.service_version) |v| attrs = attrs.add(.{ .key = "service.version", .value = .{ .string = v } });
    if (config.environment) |e| attrs = attrs.add(.{ .key = "deployment.environment.name", .value = .{ .string = e } });

    const pid = std.c.getpid();
    attrs = attrs.add(.{ .key = "process.pid", .value = .{ .int = @intCast(pid) } });

    switch (builtin.os.tag) {
        .linux => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buf)) |len| {
                const path = buf[0..len];
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, std.fs.path.basename(path));
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            } else |_| {}
        },
        .macos => {
            var size: u32 = std.fs.max_path_bytes;
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (std.c._NSGetExecutablePath(&buf, &size) == 0) {
                const path = std.mem.sliceTo(&buf, 0);
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, std.fs.path.basename(path));
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            }
        },
        else => {},
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
            if (value) |v| return toOtelValue(v);
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

/// number of fields an attrs struct literal carries (0 for anything else)
fn attrCount(comptime T: type) usize {
    return if (@typeInfo(T) == .@"struct") @typeInfo(T).@"struct".fields.len else 0;
}

/// Stack-resident attribute list sized at comptime for one call site. The
/// tracer copies attributes on startSpan, so the storage only has to outlive
/// the call. (The previous implementation kept one static buffer per attrs
/// type, which two threads starting the same span raced on.)
fn AttrStorage(comptime capacity: usize) type {
    return struct {
        items: [capacity]otel_api.common.AttributeKeyValue = undefined,
        len: usize = 0,

        pub fn push(self: *@This(), key: []const u8, value: otel_api.common.AttributeValue) void {
            self.items[self.len] = .{ .key = key, .value = value };
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const otel_api.common.AttributeKeyValue {
            return self.items[0..self.len];
        }
    };
}

/// append every non-null field of an attrs struct literal into `storage`
fn appendAttrs(storage: anytype, attrs: anytype) void {
    const T = @TypeOf(attrs);
    if (@typeInfo(T) != .@"struct") return;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (toOtelValue(@field(attrs, field.name))) |val| storage.push(field.name, val);
    }
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
    const expected_fn_ptr: @TypeOf(std.log.defaultLog) = logFn;
    _ = expected_fn_ptr;
}

test "flush is bounded and returns promptly with no exporter" {
    const lf = try configure(.{ .service_name = "t", .send_to_logfire = .no });
    defer lf.shutdown();
    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    lf.flush();
    lf.flushWithin(10);
    const elapsed_ms: u64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds - t0, std.time.ns_per_ms));
    try std.testing.expect(elapsed_ms < exit_flush_timeout_ms);
    try std.testing.expect(panic_flush_timeout_ms < exit_flush_timeout_ms);
}

test "panicFn signature matches std.debug.FullPanic" {
    const P = std.debug.FullPanic(panicFn);
    _ = P;
}

test "logFn falls back to defaultLog when bridge not initialized" {
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

    const attrs = .{ .alpha = @as(f64, 0.5), .top_k = @as(i64, 3), .skipped = @as(?i64, null) };
    var storage = AttrStorage(attrCount(@TypeOf(attrs))){};
    appendAttrs(&storage, attrs);
    try testing.expectEqual(@as(usize, 2), storage.len);
    try testing.expectEqualStrings("alpha", storage.slice()[0].key);
    try testing.expectEqual(@as(f64, 0.5), storage.slice()[0].value.float);
}

test "attribute storage is per call, not per type" {
    // two storages for the same attrs type must not alias
    const attrs_a = .{ .n = @as(i64, 1) };
    const attrs_b = .{ .n = @as(i64, 2) };
    var sa = AttrStorage(1){};
    var sb = AttrStorage(1){};
    appendAttrs(&sa, attrs_a);
    appendAttrs(&sb, attrs_b);
    try std.testing.expectEqual(@as(i64, 1), sa.slice()[0].value.int);
    try std.testing.expectEqual(@as(i64, 2), sb.slice()[0].value.int);
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
    const h = httpSpan("GET", "/x", .{ .extra = @as(i64, 1) });
    defer h.end();
    flush();
}

/// records what a downstream processor would receive
const CapturingProcessor = struct {
    allocator: std.mem.Allocator,
    ended: std.ArrayList(otel_sdk.trace.SpanData) = .empty,

    pub fn spanLimits(_: *CapturingProcessor) otel_api.trace.Span.Limits {
        return .default;
    }
    pub fn onEnd(self: *CapturingProcessor, s: otel_sdk.trace.SpanData, _: otel_sdk.resource.Resource) void {
        const owned = otel_sdk.trace.SpanData.initOwned(self.allocator, s) catch return;
        self.ended.append(self.allocator, owned) catch {};
    }
    pub fn forceFlush(_: *CapturingProcessor, _: ?u64) otel_api.common.FlushResult {
        return .success;
    }
    pub fn shutdown(_: *CapturingProcessor, _: ?u64) otel_api.common.ProcessResult {
        return .success;
    }
    pub fn deinit(self: *CapturingProcessor) void {
        for (self.ended.items) |*s| s.deinitOwned(self.allocator);
        self.ended.deinit(self.allocator);
    }
    pub fn destroy(_: *CapturingProcessor) void {}

    fn attrString(s: otel_sdk.trace.SpanData, key: []const u8) ?[]const u8 {
        for (s.attributes) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value.string;
        return null;
    }
};

test "pending span is published at start, parented to the real span" {
    const testing = std.testing;
    // both processors are registered with the provider, which deinits and
    // destroys them in its own deinit — the emitter must therefore be heap
    // allocated, as Logfire.init does it
    var capture = CapturingProcessor{ .allocator = testing.allocator };
    const emitter = try testing.allocator.create(PendingSpanEmitter);
    emitter.* = .{
        .allocator = testing.allocator,
        .sink = .{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(&capture) },
    };

    var provider = otel_sdk.trace.TracerProvider.init(
        testing.allocator,
        otel_sdk.resource.Resource{ .attributes = &.{}, .schema_url = null },
        otel_sdk.trace.createDefaultIdGenerator(),
        otel_sdk.trace.samplers.always_on,
    );
    defer provider.deinit();
    try provider.registerProcessor(.{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(&capture) });
    try provider.registerProcessor(.{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(emitter) });

    var tp = provider.tracerProvider();
    var tracer = try tp.getTracerWithScope(.{ .name = "t", .version = null, .schema_url = null, .attributes = &.{} });
    const attrs = [_]otel_api.common.AttributeKeyValue{.{ .key = "q_len", .value = .{ .int = 3 } }};
    var real = try tracer.startSpan("search", .{ .kind = .internal, .attributes = &attrs }, &.{});

    // at start: exactly the pending copy has reached the sink
    try testing.expectEqual(@as(usize, 1), capture.ended.items.len);
    const pending = capture.ended.items[0];
    try testing.expectEqualStrings("pending_span", CapturingProcessor.attrString(pending, attr.span_type).?);
    try testing.expect(CapturingProcessor.attrString(pending, attr.pending_parent_id) == null); // root span: no parent id
    try testing.expectEqualStrings("search", pending.name);
    try testing.expectEqual(pending.start_time, pending.end_time);
    try testing.expect(std.mem.eql(u8, &pending.parent_ctx.?.span_id.bytes, &real.getSpanContext().span_id.bytes));
    try testing.expect(!std.mem.eql(u8, &pending.ctx.span_id.bytes, &real.getSpanContext().span_id.bytes));
    try testing.expect(std.mem.eql(u8, &pending.ctx.trace_id.bytes, &real.getSpanContext().trace_id.bytes));
    // the real span's own attributes ride along
    var saw_q_len = false;
    for (pending.attributes) |kv| if (std.mem.eql(u8, kv.key, "q_len")) {
        saw_q_len = true;
    };
    try testing.expect(saw_q_len);

    real.end(null);
    real.deinit();
    // the real span arrives once, and is not itself tagged pending
    try testing.expectEqual(@as(usize, 2), capture.ended.items.len);
    try testing.expect(CapturingProcessor.attrString(capture.ended.items[1], attr.span_type) == null);
    try testing.expectEqual(@as(u64, 1), emitter.emitted.load(.monotonic));
}

test "a child's pending span names its parent" {
    const testing = std.testing;
    // both processors are registered with the provider, which deinits and
    // destroys them in its own deinit — the emitter must therefore be heap
    // allocated, as Logfire.init does it
    var capture = CapturingProcessor{ .allocator = testing.allocator };
    const emitter = try testing.allocator.create(PendingSpanEmitter);
    emitter.* = .{
        .allocator = testing.allocator,
        .sink = .{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(&capture) },
    };
    var provider = otel_sdk.trace.TracerProvider.init(
        testing.allocator,
        otel_sdk.resource.Resource{ .attributes = &.{}, .schema_url = null },
        otel_sdk.trace.createDefaultIdGenerator(),
        otel_sdk.trace.samplers.always_on,
    );
    defer provider.deinit();
    try provider.registerProcessor(.{ .bridge = otel_sdk.trace.BridgeSpanProcessor.init(emitter) });
    defer capture.deinit(); // not registered: nothing else frees it

    var tp = provider.tracerProvider();
    var tracer = try tp.getTracerWithScope(.{ .name = "t", .version = null, .schema_url = null, .attributes = &.{} });
    var parent = try tracer.startSpan("parent", null, &.{});
    const parent_ctx = parent.getSpanContext();
    var ctx_kv = [_]otel_api.ContextKeyValue{.{
        .key = otel_api.trace.context_keys.active_span_context_key.key_id,
        .value = otel_api.trace.context_keys.active_span_context_key.wrapValue(parent_ctx),
    }};
    var child = try tracer.startSpan("child", null, &ctx_kv);

    try testing.expectEqual(@as(usize, 2), capture.ended.items.len);
    var hex: [16]u8 = undefined;
    parent_ctx.span_id.toHexString(&hex);
    try testing.expectEqualStrings(&hex, CapturingProcessor.attrString(capture.ended.items[1], attr.pending_parent_id).?);

    child.end(null);
    child.deinit();
    parent.end(null);
    parent.deinit();
}
