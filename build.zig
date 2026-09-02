const std = @import("std");
const zon_version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // telemetry.sdk.version on every resource comes from the package, not a
    // string someone has to remember to bump
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon_version);
    const build_options = options.createModule();

    // otel-zig dependency
    const otel_dep = b.dependency("opentelemetry", .{
        .target = target,
        .optimize = optimize,
    });

    // config module (shared between modules)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // logfire module (otel-backed)
    const logfire_mod = b.addModule("logfire", .{
        .root_source_file = b.path("src/otel_wrapper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel", .module = otel_dep.module("otel") },
            .{ .name = "config", .module = config_mod },
            .{ .name = "build_options", .module = build_options },
        },
    });

    // tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/otel_wrapper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_dep.module("otel") },
                .{ .name = "config", .module = config_mod },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    // config.zig has its own tests but lives in a separate build module, so
    // a single test target can't surface both its tests and the wrapper's
    // (zig 0.16: a file can only belong to one module). add a second test
    // target rooted at config.zig and depend on it from `test` so a single
    // `zig build test` runs everything.
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_config_tests = b.addRunArtifact(config_tests);

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_config_tests.step);

    // example executable
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/otel_basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "logfire", .module = logfire_mod }},
        }),
    });

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "run example");
    example_step.dependOn(&run_example.step);

    // validation script for otel-zig OTLP export (not in CI, requires LOGFIRE_TOKEN)
    const validate_otel = b.addExecutable(.{
        .name = "validate-otel-export",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validate_otel_export.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_dep.module("otel") },
            },
        }),
    });

    const run_validate_otel = b.addRunArtifact(validate_otel);
    const validate_step = b.step("validate-otel", "validate otel-zig OTLP export to logfire (requires LOGFIRE_TOKEN)");
    validate_step.dependOn(&run_validate_otel.step);
}
