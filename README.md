# logfire-zig

unofficial Zig SDK for [Pydantic Logfire](https://logfire.pydantic.dev/), built on
[otel-zig](https://github.com/zzstoatzz/otel-zig) for OTLP/protobuf export.
Follows the shape of [logfire-rust](https://github.com/pydantic/logfire-rust);
the parity table at the bottom says exactly how far that goes.

## adopting it

Three lines in your application root, then `std.log` and spans just work.

```zig
const std = @import("std");
const logfire = @import("logfire");

// every std.log.* call — yours, your dependencies', the stdlib's — becomes an
// OTEL log record carrying the current span, and still reaches stderr
pub const std_options: std.Options = .{ .log_level = .info, .logFn = logfire.logFn };

// a panic's message is shipped before the process dies
pub const panic = std.debug.FullPanic(logfire.panicFn);

pub fn main() !void {
    const lf = try logfire.configure(.{
        .service_name = "my-service",
        .service_version = "1.4.0",
        .environment = "production",
    });
    defer lf.shutdown(); // flushes, then tears down

    const span = logfire.span("process.files", .{ .count = @as(i64, 3) });
    defer span.end();

    std.log.info("starting", .{}); // renders under process.files in logfire
}
```

`build.zig.zon`:

```zig
.logfire = .{
    .url = "https://tangled.org/zzstoatzz.io/logfire-zig/archive/v0.3.2.tar.gz",
    .hash = "...", // zig build tells you
},
```

`build.zig`:

```zig
const logfire = b.dependency("logfire", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("logfire", logfire.module("logfire"));
```

Run with `LOGFIRE_TOKEN=pylf_v1_us_…`. Without a token nothing is exported and
`std.log` behaves exactly as it did before.

### the rules that keep telemetry honest

- **flush before you exit, and the flush is bounded.** Export is batched on
  a timer (500 ms). A watchdog that logs "no progress, exiting" and calls
  `std.process.exit` ships nothing unless it calls `logfire.flush()` first.
  `lf.shutdown()` flushes too. Both wait at most `exit_flush_timeout_ms`
  (3 s) per provider — never unbounded, because an exit path that waits on a
  wedged or dead export thread does not exit (0.3.1 did this; a panic on the
  export thread left a process alive-but-dead for 22 hours).
- **a panic prints its trace before it ships.** `panicFn` writes the message
  and stack trace to stderr first, then logs and flushes within
  `panic_flush_timeout_ms` (1.5 s), then aborts. A panic raised inside the
  telemetry path falls through to the default handler instead of re-entering.
- **spans across tasks need an explicit parent.** The current span lives in
  thread-local state, so a span opened inside `io.concurrent` or a spawned
  thread starts as a trace root. Capture `logfire.currentContext()` on the
  spawning side and open the task's span with `logfire.spanWithParent(parent, …)`.
- **prefer `std.log` over `logfire.info(...)`.** The direct functions exist
  for parity, but the hook is what makes stdlib and dependency logs show up
  too. Both funnel into the same pipeline.

## what a span carries

`logfire.span(name, attrs)` exports an OTEL span with your attributes, and,
by default, a **pending span** at start (`logfire.span_type = pending_span`)
so in-flight work shows in the live view before it finishes — a 10-minute
sync pass is visible at second one, not minute ten. `span.setStatus(.@"error", …)`
and `span.recordError(err)` also stamp `logfire.level_num = 17` so the span
renders as errored. `pending_spans = false` in the config turns the copies off.

Every log record carries `code.module.name` (the `std.log` scope), the level
as `severity_text`, and the current span's `trace_id`/`span_id`.

Every signal carries the resource: `service.name`, `service.version`,
`deployment.environment.name`, `process.pid`, `process.executable.*`, and
`telemetry.sdk.*` with the version read from this package.

## API

```zig
const lf = try logfire.configure(.{ .service_name = "svc" }); // *Logfire
lf.flush();      // or logfire.flush(); bounded by exit_flush_timeout_ms
lf.flushWithin(500);
lf.shutdown();   // or logfire.shutdown()

const span = logfire.span("op", .{ .user_id = @as(i64, 7) });
span.setAttribute("rows", @as(i64, 42));
span.setStatus(.ok, null);
span.recordError(error.Timeout);
span.end();

const parent = logfire.currentContext();               // ?SpanContext
const child = logfire.spanWithParent(parent, "leg", .{});

logfire.httpSpan("GET", "/api/users", .{ .status = @as(i64, 200) }); // "HTTP GET /api/users"
logfire.sqlSpan("SELECT * FROM users WHERE id = ?", "sqlite");

logfire.info("direct log {d}", .{1}); // also trace/debug/warn/err
```

Attribute values: integers, floats, bools, strings, and optionals of those
(null is omitted).

## configuration

| field | env | default |
|---|---|---|
| `token` | `LOGFIRE_WRITE_TOKEN`, `LOGFIRE_TOKEN` | — |
| `service_name` | `LOGFIRE_SERVICE_NAME`, `OTEL_SERVICE_NAME` | `logfire-zig` |
| `service_version` | `LOGFIRE_SERVICE_VERSION`, `OTEL_SERVICE_VERSION` | — |
| `environment` | `LOGFIRE_ENVIRONMENT` | — |
| `base_url` | `OTEL_EXPORTER_OTLP_ENDPOINT` | from the token's region |
| `send_to_logfire` | — | `.if_token_present` |
| `console` | — | enabled: `std.log` keeps writing to stderr |
| `pending_spans` | — | `true` |
| `batch_timeout_ms` | — | 500 |

## parity with logfire-rust

| capability | rust | zig |
|---|---|---|
| spans with typed attributes, nesting, explicit parent | ✓ | ✓ |
| pending spans on start | ✓ | ✓ |
| error status → `logfire.level_num` | ✓ | ✓ |
| logs through the language's standard facade | `log`/`tracing` | `std.log` via `logFn` |
| logs carry span context, module name, severity text | ✓ | ✓ |
| logs carry `code.file.path` / `code.line.number` | ✓ | ✗ (`std.log` has no source location) |
| resource: service name/version, environment, process, sdk | ✓ | ✓ |
| shutdown guard / flush | ✓ | ✓ (`shutdown`, `flush`) |
| panic hook | ✓ | ✓ (`panicFn`) |
| console exporter for spans | ✓ | ✗ (logs only) |
| metrics | ✓ | stubs |
| `RUST_LOG`-style runtime level filter | ✓ | compile-time `std.options.log_level` |
| W3C trace context propagation over HTTP | ✓ | ✗ |

## development

```bash
zig build test      # unit tests (pending spans, attribute handling, bridge shape)
zig build example   # LOGFIRE_TOKEN=… zig build example to see it in a project
```

## license

MIT
