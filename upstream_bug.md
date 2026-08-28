# Upstream bug report (draft)

> Draft for submission to <https://codeberg.org/ziglang/zig>. Not part of the zio library.
> Related existing report: ziglang/zig#19878 (GitHub mirror, open since 2024-05-07,
> labels `bug` + `standard library`, milestone `urgent`, associated PR #23365).
> That issue reports the user-visible symptom; this one identifies the root cause and adds
> a self-contained reproducer.

---

## Title

`std.http.Client` sends requests in cleartext through a CONNECT tunnel — TLS is never layered over a proxied HTTPS connection

## Zig version

Reproduced on `0.16.0` (release) and confirmed still present on `master` by source
inspection (see *Root cause*).

## Summary

When an `https://` URL is requested through a proxy, `std.http.Client` establishes the
CONNECT tunnel correctly and then writes the plaintext HTTP request into it. No TLS
handshake is performed.

This is a **confidentiality bug, not only a functionality bug**: the request line, all
headers — including `Authorization` and `Cookie` — and the request body travel to the proxy
and onward in the clear, while the calling code believes it is using `https://`. There is no
error, no warning; from the caller's side the failure is silent unless the origin server
happens to reject the plaintext request.

## Expected behaviour

After the proxy answers `200` to `CONNECT host:443`, the client should perform a TLS
handshake with `host` over the tunnelled stream, then send the HTTP request inside TLS.

## Actual behaviour

The first bytes written into the tunnel are `47 45 54 …` (`GET / HTTP/1.1`) rather than
`16 03 …` (a TLS record containing ClientHello).

## Reproduction

Self-contained; requires no network access and no certificates. The program stands up a fake
CONNECT proxy on loopback, points `https_proxy` at it, issues one `https://` request, and
prints the first bytes the client sends once the tunnel is open.

```zig
const std = @import("std");
const net = std.Io.net;

var tunnel: [64]u8 = undefined;
var tunnel_len: usize = 0;

/// Accepts one connection, answers CONNECT with 200, then records what arrives next.
fn fakeProxy(io: std.Io, server: *net.Server) void {
    const conn = server.accept(io) catch return;
    defer conn.close(io);

    var rb: [4096]u8 = undefined;
    var wb: [512]u8 = undefined;
    var r = conn.reader(io, &rb);
    var w = conn.writer(io, &wb);

    while (r.interface.takeDelimiterInclusive('\n')) |line| {
        if (std.mem.eql(u8, line, "\r\n")) break;
    } else |_| return;

    w.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n") catch return;
    w.interface.flush() catch return;

    tunnel_len = r.interface.readSliceShort(&tunnel) catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var future = try io.concurrent(fakeProxy, .{ io, &server });

    var proxy: std.http.Client.Proxy = .{
        .protocol = .plain,
        .host = try net.HostName.init("127.0.0.1"),
        .authorization = null,
        .port = server.socket.address.getPort(),
        .supports_connect = true,
    };

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    client.https_proxy = &proxy;

    var req = try client.request(.GET, try std.Uri.parse("https://example.com/"), .{});
    defer req.deinit();
    req.sendBodiless() catch {};

    future.await(io);

    const seen = tunnel[0..tunnel_len];
    std.debug.print("first bytes through the tunnel: ", .{});
    for (seen[0..@min(seen.len, 8)]) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\nas text: {s}\n", .{seen[0..@min(seen.len, 16)]});
}
```

Run with `zig run repro.zig`.

### Output on 0.16.0

```
first bytes through the tunnel: 47 45 54 20 2f 20 48 54
as text: GET / HTTP/1.1
```

Expected `16 03 ...`.

## Root cause

Line numbers refer to `lib/std/http/Client.zig` on `master`.

1. `connect()` (`:1600`) picks the proxy and, when `proxy.supports_connect` is set (`:1616`),
   delegates to `connectProxied()`.

2. `connectProxied()` (`:1526`) opens the transport with the **proxy's** protocol:

   ```zig
   const connection = try client.connectTcpOptions(.{
       .host = proxy.host,
       .port = proxy.port,
       .protocol = proxy.protocol,     // <-- .plain for an http:// proxy
       .proxied_host = proxied_host,
       .proxied_port = proxied_port,
   });
   ```

   It then sends `CONNECT`, checks for `200`, and returns that same connection. For an
   `http://` proxy this is a `Connection.Plain` — no TLS anywhere.

3. `request()` (`:1684`) takes whatever `connect()` returns and uses it verbatim (`:1728`):

   ```zig
   const connection = options.connection orelse c: {
       ...
       break :c try client.connect(host_name, uriPort(uri, protocol), protocol);
   };
   ```

   There is no step that upgrades an established connection to TLS.

4. Consistent with the above, `Connection.Tls.create` is called from exactly one place —
   `connectTcpOptions` (`:1466`), i.e. at TCP-connect time. Grepping the file for
   `Tls.create` yields that single call site, so no code path can wrap a tunnel.

The structural issue is that `Connection` models *at most one* TLS layer, established
eagerly when the socket is opened. A proxied HTTPS connection needs the layer applied
*after* the CONNECT exchange completes on the raw stream.

## Suggested fix

In `connectProxied()`, once the tunnel returns `200`, replace the plain connection with a
TLS one over the same `Io.net.Stream`, using `proxied_host` for SNI and certificate
verification (which is already what `Connection.Tls.create` does with its `remote_host`
argument). Concretely, that means either:

- allowing `Connection.Tls.create` to adopt an existing stream that has already been written
  to and read from, and swapping the pool entry after the tunnel is established; or
- deferring `Connection` creation in `connectProxied` until after the CONNECT exchange, doing
  the exchange on the bare stream first.

Until then, refusing the combination outright would be preferable to the current silent
cleartext transmission.

## Why this cannot be worked around by library code

Downstream libraries cannot implement CONNECT themselves, because a `*Connection` can only
be obtained from `Client`'s own connect functions:

- `Connection.Plain` (`:241`) and `Connection.Tls` (`:294`) are private, as are their
  `create` functions;
- `RequestOptions.connection` accepts only a `*Connection` produced by `connectTcp`,
  `connectTcpOptions`, `connectUnix`, `connectProxied`, or `connect`.

So there is no way to hand `std.http.Client` a socket on which a handshake has already been
performed. The same gap blocks SOCKS5 support for any downstream user.

Exporting `Connection.Plain.create` / `Connection.Tls.create` (or an equivalent "adopt this
stream" entry point) would resolve both, independently of the fix above.

## Secondary bug found nearby

`createProxyFromEnvVar()` silently ignores a proxy given without a scheme, e.g.
`http_proxy=proxy.corp:3128`:

```zig
const uri = Uri.parse(content) catch try Uri.parseAfterScheme("http", content);
const protocol = Protocol.fromUri(uri) orelse return null;
```

`Uri.parse("proxy.corp:3128")` **succeeds**, reading `proxy.corp` as the scheme and `3128`
as the path, so the `parseAfterScheme` fallback never runs. `Protocol.fromUri` then returns
`null` and the function returns `null` — the proxy is dropped with no diagnostic.

curl and Go both accept the schemeless form. A fix is to branch on whether the value contains
`"://"` rather than on whether `Uri.parse` succeeds.
