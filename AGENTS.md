# logfire-zig

Zig SDK for Pydantic Logfire. Use the compiler and dependencies pinned in
`build.zig.zon`. The compatibility target is the
[Logfire Rust client](https://github.com/pydantic/logfire-rust); verify behavior
against the relevant implementation before changing the API or export semantics.

Serialize JSON with the standard library rather than string concatenation.
Use the installed compiler's APIs and current source examples; old Zig 0.15
snippets do not describe this package's current toolchain.

Run `zig build test` and `zig build example`. A real export needs
`LOGFIRE_WRITE_TOKEN` from the local environment; keep credentials out of logs
and Git, and distinguish a local test from a verified export.
