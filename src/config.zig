//! logfire configuration
//!
//! mirrors the rust client's builder pattern.
//! supports both explicit config and environment variables.

const std = @import("std");

fn cGetenv(name: [*:0]const u8) ?[]const u8 {
    if (std.c.getenv(name)) |p| return std.mem.span(p);
    return null;
}

pub const Config = struct {
    /// service name (required for logfire)
    /// env: LOGFIRE_SERVICE_NAME, OTEL_SERVICE_NAME
    service_name: ?[]const u8 = null,

    /// service version
    /// env: LOGFIRE_SERVICE_VERSION, OTEL_SERVICE_VERSION
    service_version: ?[]const u8 = null,

    /// deployment environment (e.g., "production", "staging")
    /// env: LOGFIRE_ENVIRONMENT
    environment: ?[]const u8 = null,

    /// logfire/OTLP write token
    /// env: LOGFIRE_TOKEN
    token: ?[]const u8 = null,

    /// base URL for logfire API
    /// env: OTEL_EXPORTER_OTLP_ENDPOINT
    /// defaults based on token region (us/eu)
    base_url: ?[]const u8 = null,

    /// whether to send to logfire
    /// if false, just prints to console
    send_to_logfire: SendToLogfire = .if_token_present,

    /// minimum log level to capture
    default_level: Level = .info,

    /// console output options
    console: ?ConsoleOptions = .{},

    /// batch export settings
    batch_size: usize = 512,
    batch_timeout_ms: u64 = 500,

    pub const SendToLogfire = enum {
        yes,
        no,
        if_token_present,
    };

    pub const Level = enum {
        trace,
        debug,
        info,
        warn,
        err,

        pub fn severity(self: Level) u8 {
            return switch (self) {
                .trace => 1,
                .debug => 5,
                .info => 9,
                .warn => 13,
                .err => 17,
            };
        }

        pub fn name(self: Level) []const u8 {
            return @tagName(self);
        }
    };

    pub const ConsoleOptions = struct {
        enabled: bool = true,
        colors: bool = true,
        min_level: Level = .info,
    };

    /// resolve config from explicit values + environment
    pub fn resolve(self: Config) Config {
        var resolved = self;

        // token
        if (resolved.token == null) {
            resolved.token = cGetenv("LOGFIRE_WRITE_TOKEN") orelse
                cGetenv("LOGFIRE_TOKEN");
        }

        // service name
        if (resolved.service_name == null) {
            resolved.service_name = cGetenv("LOGFIRE_SERVICE_NAME") orelse
                cGetenv("OTEL_SERVICE_NAME");
        }

        // service version
        if (resolved.service_version == null) {
            resolved.service_version = cGetenv("LOGFIRE_SERVICE_VERSION") orelse
                cGetenv("OTEL_SERVICE_VERSION");
        }

        // environment
        if (resolved.environment == null) {
            resolved.environment = cGetenv("LOGFIRE_ENVIRONMENT");
        }

        // base URL - derive from token region if not explicit
        if (resolved.base_url == null) {
            if (cGetenv("OTEL_EXPORTER_OTLP_ENDPOINT")) |endpoint| {
                resolved.base_url = endpoint;
            } else if (resolved.token) |token| {
                resolved.base_url = getBaseUrlFromToken(token);
            }
        }

        return resolved;
    }

    /// determine if we should actually send data
    pub fn shouldSend(self: Config) bool {
        return switch (self.send_to_logfire) {
            .yes => true,
            .no => false,
            .if_token_present => self.token != null,
        };
    }
};

/// extract region from logfire token and return appropriate endpoint
/// token format: pylf_v{version}_{region}_{token}
fn getBaseUrlFromToken(token: []const u8) []const u8 {
    // pylf_v1_eu_xxxxx -> eu
    // pylf_v1_us_xxxxx -> us
    if (std.mem.startsWith(u8, token, "pylf_v")) {
        var it = std.mem.splitScalar(u8, token, '_');
        _ = it.next(); // pylf
        _ = it.next(); // v1
        if (it.next()) |region| {
            if (std.mem.eql(u8, region, "eu")) {
                return "https://logfire-eu.pydantic.dev";
            }
        }
    }
    // default to US
    return "https://logfire-us.pydantic.dev";
}

// tests

test "resolve from environment" {
    // can't easily test env vars, but test the default resolution
    const config = Config{
        .service_name = "test",
    };
    const resolved = config.resolve();
    try std.testing.expectEqualStrings("test", resolved.service_name.?);
}

test "getBaseUrlFromToken us" {
    const url = getBaseUrlFromToken("pylf_v1_us_abc123");
    try std.testing.expectEqualStrings("https://logfire-us.pydantic.dev", url);
}

test "getBaseUrlFromToken eu" {
    const url = getBaseUrlFromToken("pylf_v1_eu_abc123");
    try std.testing.expectEqualStrings("https://logfire-eu.pydantic.dev", url);
}

test "getBaseUrlFromToken unknown defaults to us" {
    const url = getBaseUrlFromToken("some_other_token");
    try std.testing.expectEqualStrings("https://logfire-us.pydantic.dev", url);
}
