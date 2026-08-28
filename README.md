<div align="center">
  <img width="350" alt="Zio logo" src="logo.svg" />
</div>

<div align="center">

[![Zig](https://img.shields.io/badge/Zig-%3E%3D0.16.0-blue?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/build-passing-brightgreen)](zig%20build%20test)
[![License](https://img.shields.io/badge/license-MIT-brightgreen.svg)](LICENSE)

</div>

<hr>
<br>

**Zio** is a minimal HTTP client library for [Zig](https://ziglang.org/), inspired by [Dio](https://pub.dev/packages/dio) (Dart). Built on top of `std.http.Client` with zero external dependencies.

**Features:**
- Built for Zig 0.16 and the new `std.Io` interface.
- `Client` with `base_url` support for relative URL resolution.
- Full HTTP method support: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`.
- Custom **request headers** via `RequestOptions`.
- `Response` with `status`, `body`, and **response headers** (`getHeader(name)`).
- **Proxy** support for `http://` and `https://`: explicit or from the environment, with
  `NO_PROXY` bypass rules, `Proxy-Authorization`, and real `CONNECT` tunnelling for TLS.
- **Redirect** following with credential stripping across origins.
- **Keep-alive connection pooling**, keyed by origin and proxy.
- Proper memory management (`init` / `deinit(allocator)`).


## Installation

1. Run `zig fetch` to add the dependency:

```sh
zig fetch --save https://github.com/etroynov/zio/archive/refs/tags/0.3.0.tar.gz
```

2. In `build.zig` import the module:

```zig
const zio_dep = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zio", zio_dep.module("zio"));
```


## Quick Start

```zig
const std = @import("std");
const zio = @import("zio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var client = zio.Client.init(allocator, init.io, .{
        .base_url = "https://api.example.com",
    });
    defer client.deinit();

    const response = try client.get("/get?a=1", .{
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    defer response.deinit(allocator);

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
    std.debug.print("Content-Type: {s}\n", .{response.getHeader("Content-Type") orelse "n/a"});
}
```

`zig build run` starts a self-contained demo that spins up a loopback HTTP server and
drives every method against it — no network access required.

## API

```zig
const zio = @import("zio");
```

### Client

```zig
// Init — `io` is a `std.Io` instance, see "Obtaining an Io" below.
var client = zio.Client.init(allocator, io, .{ .base_url = "https://api.example.com" });
defer client.deinit();

// Methods
const res = try client.get("/path", .{});
const res = try client.post("/path", "body", .{});
const res = try client.put("/path", "body", .{});
const res = try client.patch("/path", "body", .{});
const res = try client.delete("/path", .{});
const res = try client.head("/path", .{});
defer res.deinit(allocator);

// With request headers
const res = try client.get("/path", .{
    .headers = &.{
        .{ .name = "Authorization", .value = "Bearer token" },
        .{ .name = "Accept", .value = "application/json" },
    },
});
```

`base_url` is optional. If `path` starts with `http://` or `https://`, it is used as-is.

### Obtaining an `Io`

Zig 0.16 requires an explicit `std.Io` instance for all I/O. The easiest source is the
`std.process.Init` parameter of `main`:

```zig
pub fn main(init: std.process.Init) !void {
    var client = zio.Client.init(init.gpa, init.io, .{});
    defer client.deinit();
}
```

Outside of `main` — in tests, or in a library that manages its own event loop — build one:

```zig
var threaded: std.Io.Threaded = .init(allocator, .{});
defer threaded.deinit();

var client = zio.Client.init(allocator, threaded.io(), .{});
defer client.deinit();
```

### Proxies

Configure proxies explicitly, or discover them from the environment:

```zig
// Explicit.
var client = try zio.Client.init(allocator, io, .{
    .proxy = .{ .explicit = .{
        .http = "http://user:pass@proxy.corp:8080",
        .no_proxy = "localhost,127.0.0.1,.internal.example.com",
    } },
});

// From HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY.
var client = try zio.Client.init(allocator, io, .{
    .proxy = .{ .environment = init.environ_map },
});
```

Both lowercase and uppercase environment variables are read, lowercase first. Credentials in
the proxy URL become a `Proxy-Authorization: Basic …` header. A bare `"host:port"` is accepted
and assumed to be `http`.

`NO_PROXY` follows the same semantics as curl and Go: `example.com` exempts both
`example.com` and any subdomain of it, a leading dot is ignored, `host:port` restricts the
rule to one port, and a lone `*` exempts everything. `std.http.Client` implements none of
this, so zio applies the rules itself.

`https://` through a proxy uses a `CONNECT` tunnel, with TLS negotiated against the origin
host over that tunnel — so the certificate is checked against the real destination, not the
proxy. zio implements this itself: `std.http.Client` in Zig 0.16 opens the tunnel but never
layers TLS over it, sending the request to the proxy in cleartext. See
[upstream_bug.md](upstream_bug.md).

### Connection pooling

Idle keep-alive connections are reused across requests to the same origin. The pool holds
`max_idle_connections` (default 8) and evicts oldest-first; setting it to `0` disables
pooling, making every request send `connection: close`.

A connection returns to the pool only when the response permitted reuse and its body was
fully consumed, so a request abandoned mid-body closes its socket rather than poisoning the
pool. Connections are keyed by scheme, host, port and proxy — a tunnelled connection is
never handed to a direct request.

### Redirects

Up to `max_redirects` (default 3) `3xx` responses are followed; exceeding that gives
`error.TooManyRedirects`. Relative and absolute `Location` values both work. `301`, `302`
and `303` turn the request into a bodyless `GET`; `307` and `308` preserve method and body.

`Authorization`, `Cookie` and `Proxy-Authorization` are dropped when a redirect crosses to a
different scheme, host or port. Other headers are carried through.

### Response

```zig
res.status                        // std.http.Status
res.body                          // []const u8
res.headers                       // []const std.http.Header
res.getHeader("Content-Type")     // ?[]const u8 — case-insensitive lookup
res.deinit(allocator)
```

## Contributing

Contributions are welcome! Please:

1. Fork the repo.
2. Create your feature branch (`git checkout -b feature/foo`).
3. Commit changes (`git commit -am 'Add some foo'`).
4. Push to branch (`git push origin feature/foo`).
5. Create Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file.
