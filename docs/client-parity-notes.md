> adopted from the notes repo during the 2026-08-23 curation pass; project design/retro content lives with its project.
>
> **status 2026-09-02 (v0.3.0):** everything "what logfire-zig needs to do" below is shipped, plus pending spans, span-context on logs, and the resource attributes. The README's parity table is the current gap list; this file is the reasoning behind the shape.

# logfire client architecture (cross-language)

how logfire's official clients are shaped, derived from reading [pydantic/logfire](https://github.com/pydantic/logfire) (python) and [pydantic/logfire-rust](https://github.com/pydantic/logfire-rust). this informs how `logfire-zig` (our zig client for the same backend) should be shaped — and confirms what the existing scaffold is missing.

## the universal shape

```
language-standard logging facade
        │
        ▼
   bridge / handler  ─────── direct logfire emission API ──┐
        │                                                  │
        ▼                                                  ▼
              OTEL log API (Logger.emit)
                              │
                              ▼
              SDK LoggerProvider + BatchLogProcessor
                              │
                              ▼
                    OTLP log exporter (HTTP+protobuf)
                              │
                              ▼
                      logfire collector
```

every official client implements this same pipeline. only the top layer changes.

## per-language top layer

| language | std logging facade | bridge type | install point |
|---|---|---|---|
| python  | `logging.Logger` (records pass through `Handler`s) | `LogfireLoggingHandler(logging.Handler)` with `emit(LogRecord)` | `logger.addHandler(LogfireLoggingHandler())` |
| rust    | `log` crate (records pass through one `log::Log` impl) | `LogfireLogger` impl `log::Log` | `log::set_logger(&LogfireLogger)` (also a `tracing::Subscriber` impl in `bridges/tracing.rs`) |
| zig     | `std.log` (records pass through the single `std.options.logFn`) | a function with signature `(level, scope, fmt, args)` | `pub const std_options: std.Options = .{ .logFn = … }` |

zig's hook is the simplest in shape (single function, comptime-eager) and the most invasive to set (set on a `std.options` struct at compile time). the upside: stdlib `std.log.*` calls and library calls all funnel through the one hook.

## the direct-emit API also exists in every client

each client has both:

1. **a bridge**, so application/library code that uses the standard logging facade flows through OTEL automatically
2. **a direct API** (`logfire.info(...)`, `logfire.span(...)`, etc.) for code that wants logfire-specific affordances (typed attributes, span context, etc.)

both funnel into the same OTEL log emission underneath. you don't have to choose.

python: `logfire.info(...)` and `LogfireLoggingHandler.emit(record)` both call `logfire_instance.log(...)` which builds an OTEL log record and emits.

rust: `logfire::info!(...)` macro and the `log::Log::log()` impl both call `LogfireTracer::export_log(...)` which emits via the OTEL logs SDK.

## span context correlation

both python and rust attach the **active span context** (trace_id + span_id) to log records, so logs render under their parent span in the logfire UI. rust does this explicitly: `tracing::Span::current().context()` is passed into every `export_log`.

zig has no global "active span" yet — `logfire-zig` already maintains a thread-local in `otel_wrapper.zig` (`tl_current_span_context`) for span parent-child relationships. that's the same value to attach to log records.

## what the otel-zig SDK already provides

(checked 2026-05-08)

- `otel-api/logs`: `Logger`, `LoggerProvider`, `Severity` enum (matching otel spec numeric levels)
- `otel-sdk/logs`:
  - `LoggerProvider.init(allocator, resource, scope)` — mirrors `TracerProvider.init`
  - `BatchLogRecordProcessor` with `PipelineStep`
  - `std_log_bridge.otelLogFn` — pre-built drop-in for `std.options.logFn` (handles severity mapping, format buffer, fallback to `std.log.defaultLog` when uninitialized)
  - `LogRecord` type
- `otel-sdk/exporters/otlp/logs.zig`: `OtlpLogExporter` with `PipelineStep`
- `api.provider_registry.setGlobalLoggerProvider` — global registration

→ everything but the wiring step (`LoggerProvider` instantiation + global registration) already exists. integrating is mostly mirroring the trace-provider setup that `logfire-zig` already does.

## what `logfire-zig` needs to do

from reading `logfire-zig/src/otel_wrapper.zig` (commit captured at adoption time):

- **`Logfire.init` (lines 65-147):** mirror lines 109-143 (the trace setup) for logs. create a `LoggerProvider`, attach `BatchLogRecordProcessor` + `OtlpLogExporter` via the pipeline builder, register globally via `setGlobalLoggerProvider`, populate `self.logger`.
- **`std_log_bridge.init(...)`** must also be called (it's a separate global state inside the bridge module).
- **`logFn` re-export:** logfire-zig should re-export `otel_sdk.logs.std_log_bridge.otelLogFn` (or wrap it) under `logfire.logFn` so the application's `std.options.logFn = logfire.logFn` is the single line of integration.
- **`logMessage` (lines 223-233):** today only writes to console with a `// TODO: emit to otel logger` comment. once the provider is wired, this should emit a real log record (mirroring what the bridge does), so the existing `logfire.info/warn/err/debug` direct API also funnels into OTEL.
- **`flush()` (lines 175-180):** today only flushes the trace provider. add a logger_provider flush.

once shipped, the logfire-zig adopter does:

```zig
const logfire = @import("logfire");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logfire.logFn,
};

pub fn main() !void {
    _ = try logfire.configure(.{ ... });
    // every std.log.* call from now on (including from stdlib + dependencies) ships to logfire
}
```

and existing `logfire.info(...)` / `logfire.span(...)` calls keep working — same emission, just two surfaces into it.

## why the half-implementation existed

two informed guesses (verify when fixing):
1. trace path was the high-value piece for the first cut, logs were "nice to have"
2. otel-zig's logs SDK landed after logfire-zig's first version, so when logfire-zig was written the LoggerProvider type didn't exist yet

field declarations (`log_provider`, `logger`) and shutdown handling are already in place; only `init()` is missing the wiring.
