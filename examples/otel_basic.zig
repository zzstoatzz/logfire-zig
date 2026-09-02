//! logfire example — the adoption recipe end to end.
//!
//! run with a token to see it in a project:
//!   LOGFIRE_TOKEN=pylf_v1_us_… zig build example
//! without one, everything below still runs and std.log goes to stderr only.

const std = @import("std");
const logfire = @import("logfire");

// every std.log.* call ships as an OTEL log record under the current span,
// and still reaches stderr
pub const std_options: std.Options = .{ .log_level = .info, .logFn = logfire.logFn };

// a panic's message is flushed before the process dies
pub const panic = std.debug.FullPanic(logfire.panicFn);

const log = std.log.scoped(.example);

pub fn main() !void {
    const lf = try logfire.configure(.{
        .service_name = "logfire-zig-example",
        .service_version = logfire.version,
        .environment = "development",
    });
    defer lf.shutdown();

    log.info("application started", .{});

    {
        // published as a pending span immediately, then as the real span at end
        const span = logfire.span("example.work", .{
            .iteration = @as(i64, 1),
            .query = "prefect python",
        });
        defer span.end();

        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(50), .real) catch {};
        log.info("work completed", .{}); // carries example.work's trace/span id
    }

    {
        const outer = logfire.span("example.outer", .{});
        defer outer.end();
        {
            const inner = logfire.span("example.inner", .{});
            defer inner.end();
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(25), .real) catch {};
            inner.recordError(error.ExampleFailure); // rendered as errored
        }
    }

    log.info("example complete", .{});
}
