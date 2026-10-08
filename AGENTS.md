# logfire-zig

zig 0.15+ SDK for pydantic logfire - OTLP HTTP/JSON export for traces, logs, metrics.

## goal

**full parity with logfire-rust client.** not simpler, not "good enough" - parity.

## reference projects

look at these for patterns, don't reinvent:

- `~/tangled.org/zzstoatzz.io/prefect-server/` - zig http server, json handling
- `~/tangled.org/zat.dev/zat/` - zig AT Protocol client
- `~/tangled.org/zzstoatzz.io/pub-search/` - zig backend patterns
- `~/tangled.org/zzstoatzz.io/notes/languages/ziglang/` - zig notes, by topic and by version

## zig 0.15 patterns

### JSON serialization - use std.json.Stringify

**DO NOT manually concatenate JSON strings.** use the stdlib:

```zig
const json = std.json;

fn buildJson(alloc: std.mem.Allocator, data: MyData) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &output.writer };

    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(data.name);
    try jw.objectField("count");
    try jw.write(data.count);
    try jw.endObject();

    return output.toOwnedSlice();
}
```

for raw JSON passthrough:
```zig
try jw.beginWriteRaw();
try jw.writer.writeAll(raw_json_string);
jw.endWriteRaw();
```

### ArrayList (unmanaged in 0.15)

pass allocator to each method:

```zig
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(alloc);

try buf.appendSlice(alloc, data);
try buf.print(alloc, "{d}", .{value});

// borrow: buf.items (don't hold after deinit)
// transfer ownership: buf.toOwnedSlice(alloc)
```

### HTTP client

```zig
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();

var aw: std.Io.Writer.Allocating = .init(allocator);
defer aw.deinit();

const result = client.fetch(.{
    .location = .{ .url = url },
    .response_writer = &aw.writer,
    .method = .POST,
    .payload = body,
    .headers = .{
        .content_type = .{ .override = "application/json" },
        .accept_encoding = .{ .override = "identity" },  // disable gzip (bug in 0.15)
    },
}) catch return error.RequestFailed;
```

### env vars

```zig
const token = std.posix.getenv("LOGFIRE_WRITE_TOKEN") orelse
    std.posix.getenv("LOGFIRE_TOKEN");
```

## testing

```bash
zig build test     # run tests
zig build example  # run examples/otel_basic.zig
```

test with real export requires LOGFIRE_WRITE_TOKEN in .env

## rust client reference

`gh api repos/pydantic/logfire-rust/contents/src` - check metrics.rs for API parity
