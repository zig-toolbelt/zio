//! A client connection: TCP, optionally wrapped in TLS, optionally reached through an
//! HTTP `CONNECT` tunnel.
//!
//! This exists because `std.http.Client` cannot layer TLS over a tunnel — it creates the
//! `Connection` (and therefore its TLS state) at TCP-connect time and offers no way to
//! adopt a stream afterwards. See `upstream_bug.md`. Owning the socket lets us run the
//! `CONNECT` exchange on the bare stream first and only then hand the *same* stream to
//! `std.crypto.tls.Client`.
//!
//! The struct is heap-allocated and must not be moved: `std.crypto.tls.Client` keeps
//! pointers into `stream_reader`/`stream_writer`, and its own reader/writer interfaces are
//! recovered with `@fieldParentPtr`.

const std = @import("std");

const net = std.Io.net;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Connection = @This();

gpa: Allocator,
io: Io,
stream: net.Stream,
stream_reader: net.Stream.Reader,
stream_writer: net.Stream.Writer,
/// Present for `https`; null for plaintext `http`.
tls_client: ?*std.crypto.tls.Client,

socket_read_buffer: []u8,
socket_write_buffer: []u8,
tls_read_buffer: []u8,
tls_write_buffer: []u8,

/// Identity used to match a pooled connection to a request. Owned.
host: []u8,
port: u16,
protocol: Protocol,
proxy_host: ?[]u8,
proxy_port: u16,
/// Set once the connection must not be reused: the peer asked to close, the exchange
/// ended mid-stream, or an error occurred.
closing: bool,

pub const Protocol = enum { plain, tls };

/// What a request needs from a connection. A proxied connection is never handed to a
/// direct request, or to one going through a different proxy.
pub const Key = struct {
    protocol: Protocol,
    host: []const u8,
    port: u16,
    proxy_host: ?[]const u8 = null,
    proxy_port: u16 = 0,
};

pub fn matches(self: *const Connection, key: Key) bool {
    if (self.closing) return false;
    if (self.protocol != key.protocol or self.port != key.port) return false;
    if (!std.ascii.eqlIgnoreCase(self.host, key.host)) return false;

    const mine = self.proxy_host orelse {
        return key.proxy_host == null;
    };
    const theirs = key.proxy_host orelse return false;
    return self.proxy_port == key.proxy_port and std.ascii.eqlIgnoreCase(mine, theirs);
}

/// Verification material for TLS. Mirrors the shape of `std.crypto.tls.Client.Options.ca`
/// so a caller can share one bundle across every connection.
pub const TlsConfig = struct {
    lock: *Io.RwLock,
    bundle: *std.crypto.Certificate.Bundle,
    /// Wall-clock time used to judge certificate validity.
    now: Io.Timestamp,
    /// Skips both host and CA verification. Intended for tests against self-signed
    /// certificates; never enable it against untrusted networks.
    insecure_skip_verify: bool = false,
    ssl_key_log: ?*std.crypto.tls.Client.SslKeyLog = null,
};

/// Reach the origin through an HTTP proxy using `CONNECT`.
pub const Tunnel = struct {
    host: []const u8,
    port: u16,
    /// Verbatim `Proxy-Authorization` header value, e.g. `"Basic dXNlcjpwYXNz"`.
    authorization: ?[]const u8 = null,
};

pub const Options = struct {
    /// Origin host. Also the SNI name and the name the certificate is checked against,
    /// including when tunnelling — which is exactly what the upstream bug gets wrong.
    host: []const u8,
    port: u16,
    protocol: Protocol,
    /// When set, connect to the proxy and `CONNECT` to `host`:`port` through it.
    tunnel: ?Tunnel = null,
    /// Required when `protocol` is `.tls`.
    tls: ?TlsConfig = null,
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 1024,
    tls_buffer_size: usize = std.crypto.tls.Client.min_buffer_len,
};

pub const Error = error{
    /// The proxy refused the tunnel or answered with a non-2xx status.
    ProxyTunnelFailed,
    /// The proxy's response to `CONNECT` was not valid HTTP.
    ProxyTunnelMalformedResponse,
    /// `protocol` was `.tls` but no `TlsConfig` was supplied.
    TlsConfigMissing,
    TlsInitializationFailed,
} || Allocator.Error || Io.Cancelable;

pub fn connect(gpa: Allocator, io: Io, options: Options) !*Connection {
    if (options.protocol == .tls and options.tls == null) return error.TlsConfigMissing;

    const self = try gpa.create(Connection);
    errdefer gpa.destroy(self);

    // `std.crypto.tls.Client` asserts the socket reader can hold a whole TLS record.
    const socket_read_len = if (options.protocol == .tls)
        @max(options.read_buffer_size, options.tls_buffer_size)
    else
        options.read_buffer_size;

    const socket_read_buffer = try gpa.alloc(u8, socket_read_len);
    errdefer gpa.free(socket_read_buffer);
    const socket_write_buffer = try gpa.alloc(u8, options.write_buffer_size);
    errdefer gpa.free(socket_write_buffer);

    // The TLS layer needs room for a max-size record plus the HTTP head it will surface.
    const tls_read_len = if (options.protocol == .tls)
        options.tls_buffer_size + options.read_buffer_size
    else
        0;
    const tls_read_buffer = try gpa.alloc(u8, tls_read_len);
    errdefer gpa.free(tls_read_buffer);
    const tls_write_buffer = try gpa.alloc(u8, if (options.protocol == .tls) options.tls_buffer_size else 0);
    errdefer gpa.free(tls_write_buffer);

    const host_copy = try gpa.dupe(u8, options.host);
    errdefer gpa.free(host_copy);
    const proxy_host_copy: ?[]u8 = if (options.tunnel) |t| try gpa.dupe(u8, t.host) else null;
    errdefer if (proxy_host_copy) |p| gpa.free(p);

    // Connect to the proxy when tunnelling, otherwise straight to the origin.
    const connect_host = if (options.tunnel) |t| t.host else options.host;
    const connect_port = if (options.tunnel) |t| t.port else options.port;

    const host_name = net.HostName.init(connect_host) catch return error.TlsInitializationFailed;
    const stream = try host_name.connect(io, connect_port, .{ .mode = .stream });
    errdefer stream.close(io);

    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .stream_reader = stream.reader(io, socket_read_buffer),
        .stream_writer = stream.writer(io, socket_write_buffer),
        .tls_client = null,
        .socket_read_buffer = socket_read_buffer,
        .socket_write_buffer = socket_write_buffer,
        .tls_read_buffer = tls_read_buffer,
        .tls_write_buffer = tls_write_buffer,
        .host = host_copy,
        .port = options.port,
        .protocol = options.protocol,
        .proxy_host = proxy_host_copy,
        .proxy_port = if (options.tunnel) |t| t.port else 0,
        .closing = false,
    };

    // Run the CONNECT exchange on the bare stream, before any TLS.
    if (options.tunnel) |t| try self.establishTunnel(options.host, options.port, t);

    if (options.protocol == .tls) {
        const cfg = options.tls.?;
        const tls_client = try gpa.create(std.crypto.tls.Client);
        errdefer gpa.destroy(tls_client);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        tls_client.* = std.crypto.tls.Client.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .host = if (cfg.insecure_skip_verify)
                    .no_verification
                else
                    .{ .explicit = options.host },
                .ca = if (cfg.insecure_skip_verify) .no_verification else .{ .bundle = .{
                    .gpa = gpa,
                    .io = io,
                    .lock = cfg.lock,
                    .bundle = cfg.bundle,
                } },
                .ssl_key_log = cfg.ssl_key_log,
                .read_buffer = tls_read_buffer,
                .write_buffer = tls_write_buffer,
                .entropy = &entropy,
                .realtime_now = cfg.now,
                // Safe for HTTP: Content-Length / chunked framing detects truncation.
                .allow_truncation_attacks = true,
            },
        ) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.TlsInitializationFailed,
        };
        self.tls_client = tls_client;
    }

    return self;
}

pub fn deinit(self: *Connection) void {
    const gpa = self.gpa;
    if (self.tls_client) |tls_client| gpa.destroy(tls_client);
    self.stream.close(self.io);
    if (self.proxy_host) |p| gpa.free(p);
    gpa.free(self.host);
    gpa.free(self.tls_write_buffer);
    gpa.free(self.tls_read_buffer);
    gpa.free(self.socket_write_buffer);
    gpa.free(self.socket_read_buffer);
    gpa.destroy(self);
}

/// The stream to read the HTTP response from: the TLS plaintext side when encrypted.
pub fn reader(self: *Connection) *Io.Reader {
    if (self.tls_client) |tls_client| return &tls_client.reader;
    return &self.stream_reader.interface;
}

/// The stream to write the HTTP request to.
pub fn writer(self: *Connection) *Io.Writer {
    if (self.tls_client) |tls_client| return &tls_client.writer;
    return &self.stream_writer.interface;
}

/// Performs `CONNECT host:port` against the already-connected proxy and consumes its
/// response head, leaving the stream positioned at the start of the tunnelled data.
fn establishTunnel(self: *Connection, host: []const u8, port: u16, tunnel: Tunnel) !void {
    const w = &self.stream_writer.interface;

    try w.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ host, port, host, port });
    if (tunnel.authorization) |auth| try w.print("Proxy-Authorization: {s}\r\n", .{auth});
    try w.writeAll("\r\n");
    try w.flush();

    const r = &self.stream_reader.interface;

    const status_line = r.takeDelimiterInclusive('\n') catch return error.ProxyTunnelMalformedResponse;
    const status = parseStatus(status_line) orelse return error.ProxyTunnelMalformedResponse;
    if (status / 100 != 2) return error.ProxyTunnelFailed;

    // Discard the remaining head. A 2xx CONNECT response has no body.
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return error.ProxyTunnelMalformedResponse;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), "")) break;
    }
}

/// Extracts the status code from an HTTP status line such as `HTTP/1.1 200 OK`.
fn parseStatus(line: []const u8) ?u16 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return null; // version
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

test parseStatus {
    try std.testing.expectEqual(@as(?u16, 200), parseStatus("HTTP/1.1 200 Connection established\r\n"));
    try std.testing.expectEqual(@as(?u16, 407), parseStatus("HTTP/1.1 407 Proxy Authentication Required\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatus("garbage\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatus("HTTP/1.1\r\n"));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// What a fake proxy observed, so tests can assert on the wire bytes.
const ProxyLog = struct {
    request_line: [128]u8 = undefined,
    request_line_len: usize = 0,
    auth: [128]u8 = undefined,
    auth_len: usize = 0,
    tunnel: [16]u8 = undefined,
    tunnel_len: usize = 0,

    fn requestLine(self: *const ProxyLog) []const u8 {
        return self.request_line[0..self.request_line_len];
    }
    fn authorization(self: *const ProxyLog) []const u8 {
        return self.auth[0..self.auth_len];
    }
    fn tunnelBytes(self: *const ProxyLog) []const u8 {
        return self.tunnel[0..self.tunnel_len];
    }
};

/// Accepts one connection, answers `CONNECT` with `status`, and on 2xx records the first
/// bytes the client then writes into the tunnel.
fn fakeProxy(io: Io, server: *net.Server, status: []const u8, log: *ProxyLog) void {
    const conn = server.accept(io) catch return;
    defer conn.close(io);

    var rb: [4096]u8 = undefined;
    var wb: [512]u8 = undefined;
    var r = conn.reader(io, &rb);
    var w = conn.writer(io, &wb);

    var first = true;
    while (r.interface.takeDelimiterInclusive('\n')) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (first) {
            const n = @min(trimmed.len, log.request_line.len);
            @memcpy(log.request_line[0..n], trimmed[0..n]);
            log.request_line_len = n;
            first = false;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "proxy-authorization:")) {
            const value = std.mem.trim(u8, trimmed["proxy-authorization:".len..], " ");
            const n = @min(value.len, log.auth.len);
            @memcpy(log.auth[0..n], value[0..n]);
            log.auth_len = n;
        }
        if (trimmed.len == 0) break;
    } else |_| return;

    w.interface.print("HTTP/1.1 {s}\r\n\r\n", .{status}) catch return;
    w.interface.flush() catch return;

    if (!std.mem.startsWith(u8, status, "2")) return;
    log.tunnel_len = r.interface.readSliceShort(&log.tunnel) catch return;
}

const TestProxy = struct {
    server: net.Server,
    future: Io.Future(void),
    log: ProxyLog,
    io: Io,

    fn start(io: Io, self: *TestProxy, status: []const u8) !u16 {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .future = undefined,
            .log = .{},
            .io = io,
        };
        const port = self.server.socket.address.getPort();
        self.future = try io.concurrent(fakeProxy, .{ io, &self.server, status, &self.log });
        return port;
    }

    fn stop(self: *TestProxy) void {
        self.future.await(self.io);
        self.server.deinit(self.io);
    }
};

test "CONNECT tunnel carries a TLS ClientHello, not cleartext" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var proxy: TestProxy = undefined;
    const port = try TestProxy.start(io, &proxy, "200 Connection established");
    defer proxy.stop();

    var bundle: std.crypto.Certificate.Bundle = .empty;
    var lock: Io.RwLock = .init;

    // The handshake cannot complete — the fake proxy is not a TLS server — but the bytes
    // it captures are the whole point of the test.
    const result = connect(gpa, io, .{
        .host = "example.com",
        .port = 443,
        .protocol = .tls,
        .tunnel = .{ .host = "127.0.0.1", .port = port },
        .tls = .{
            .lock = &lock,
            .bundle = &bundle,
            .now = Io.Clock.real.now(io),
            .insecure_skip_verify = true,
        },
    });
    if (result) |conn| conn.deinit() else |_| {}

    proxy.future.await(io);

    try testing.expectEqualStrings("CONNECT example.com:443 HTTP/1.1", proxy.log.requestLine());

    const seen = proxy.log.tunnelBytes();
    try testing.expect(seen.len >= 3);
    // 0x16 = TLS handshake record, 0x03 = TLS major version.
    try testing.expectEqual(@as(u8, 0x16), seen[0]);
    try testing.expectEqual(@as(u8, 0x03), seen[1]);
    // The regression this guards against: std sends "GET ..." here instead.
    try testing.expect(!std.mem.startsWith(u8, seen, "GET"));
}

test "CONNECT tunnel forwards Proxy-Authorization" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var proxy: TestProxy = undefined;
    const port = try TestProxy.start(io, &proxy, "200 Connection established");
    defer proxy.stop();

    var bundle: std.crypto.Certificate.Bundle = .empty;
    var lock: Io.RwLock = .init;

    const result = connect(gpa, io, .{
        .host = "example.com",
        .port = 443,
        .protocol = .tls,
        .tunnel = .{ .host = "127.0.0.1", .port = port, .authorization = "Basic dXNlcjpwYXNz" },
        .tls = .{
            .lock = &lock,
            .bundle = &bundle,
            .now = Io.Clock.real.now(io),
            .insecure_skip_verify = true,
        },
    });
    if (result) |conn| conn.deinit() else |_| {}

    proxy.future.await(io);
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", proxy.log.authorization());
}

test "a proxy refusing CONNECT surfaces ProxyTunnelFailed" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var proxy: TestProxy = undefined;
    const port = try TestProxy.start(io, &proxy, "407 Proxy Authentication Required");
    defer proxy.stop();

    var bundle: std.crypto.Certificate.Bundle = .empty;
    var lock: Io.RwLock = .init;

    try testing.expectError(error.ProxyTunnelFailed, connect(gpa, io, .{
        .host = "example.com",
        .port = 443,
        .protocol = .tls,
        .tunnel = .{ .host = "127.0.0.1", .port = port },
        .tls = .{
            .lock = &lock,
            .bundle = &bundle,
            .now = Io.Clock.real.now(io),
            .insecure_skip_verify = true,
        },
    }));
}

test "plain connection speaks HTTP directly" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Origin = struct {
        fn serve(inner_io: Io, server: *net.Server) void {
            const conn = server.accept(inner_io) catch return;
            defer conn.close(inner_io);
            var rb: [2048]u8 = undefined;
            var wb: [512]u8 = undefined;
            var r = conn.reader(inner_io, &rb);
            var w = conn.writer(inner_io, &wb);
            while (r.interface.takeDelimiterInclusive('\n')) |line| {
                if (std.mem.eql(u8, line, "\r\n")) break;
            } else |_| return;
            w.interface.writeAll("HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n") catch return;
            w.interface.flush() catch return;
        }
    };

    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var future = try io.concurrent(Origin.serve, .{ io, &server });
    defer future.await(io);

    const conn = try connect(gpa, io, .{
        .host = "127.0.0.1",
        .port = port,
        .protocol = .plain,
    });
    defer conn.deinit();

    const w = conn.writer();
    try w.writeAll("GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n");
    try w.flush();

    const line = try conn.reader().takeDelimiterInclusive('\n');
    try testing.expect(std.mem.startsWith(u8, line, "HTTP/1.1 204"));
}
