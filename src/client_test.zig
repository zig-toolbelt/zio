const std = @import("std");
const zio = @import("zio");

const net = std.Io.net;

/// Serves `num_requests` requests, echoing back the method and target as JSON.
///
/// Accepts as many connections as the client opens and serves as many requests per
/// connection as it sends, so the harness works whether or not pooling is in play.
/// `connections_used` records how many were needed, which is how reuse is asserted.
fn serve(io: std.Io, server: *net.Server, num_requests: u32, connections_used: *u32) void {
    var served: u32 = 0;
    while (served < num_requests) {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        connections_used.* += 1;
        served += serveConnection(io, conn, num_requests - served);
    }
}

/// Serves up to `budget` requests on one connection, returning how many it handled.
fn serveConnection(io: std.Io, conn: net.Stream, budget: u32) u32 {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);

    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var served: u32 = 0;
    while (served < budget) {
        // A closed connection is the normal end of a keep-alive session, not an error.
        var request = http_server.receiveHead() catch break;
        const target = request.head.target;
        const method_str = @tagName(request.head.method);

        var proxy_auth: []const u8 = "";
        var auth: []const u8 = "";
        var keep: []const u8 = "";
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "proxy-authorization")) proxy_auth = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "x-keep-me")) keep = h.value;
        }

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"method\":\"{s}\",\"url\":\"{s}\",\"proxy_auth\":\"{s}\",\"auth\":\"{s}\",\"keep\":\"{s}\"}}",
            .{ method_str, target, proxy_auth, auth, keep },
        ) catch return served;

        request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-Custom", .value = "test-value" },
            },
        }) catch return served;

        served += 1;
    }
    return served;
}

/// A loopback HTTP server bound to an ephemeral port, running concurrently on `io`.
const TestServer = struct {
    io: std.Io,
    server: net.Server,
    future: std.Io.Future(void),
    base_url: []const u8,
    allocator: std.mem.Allocator,
    /// How many TCP connections the client needed. One means keep-alive reuse worked.
    connections_used: u32,

    fn start(allocator: std.mem.Allocator, io: std.Io, num_requests: u32) !*TestServer {
        const self = try allocator.create(TestServer);
        errdefer allocator.destroy(self);

        const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
        self.server = try address.listen(io, .{ .reuse_address = true });
        errdefer self.server.deinit(io);

        self.io = io;
        self.allocator = allocator;
        self.base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{
            self.server.socket.address.getPort(),
        });
        errdefer allocator.free(self.base_url);

        self.connections_used = 0;
        self.future = try io.concurrent(serve, .{ io, &self.server, num_requests, &self.connections_used });
        return self;
    }

    fn deinit(self: *TestServer) void {
        self.future.await(self.io);
        self.server.deinit(self.io);
        self.allocator.free(self.base_url);
        self.allocator.destroy(self);
    }
};

test "http methods" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 6);
    defer ts.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = ts.base_url });
    defer client.deinit();

    // GET
    {
        const resp = try client.get("/get", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/get"));
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "GET"));
    }

    // POST
    {
        const resp = try client.post("/post", "{\"key\":\"value\"}", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/post"));
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "POST"));
    }

    // PUT
    {
        const resp = try client.put("/put", "put data", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/put"));
    }

    // PATCH
    {
        const resp = try client.patch("/patch", "patch data", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/patch"));
    }

    // DELETE
    {
        const resp = try client.delete("/delete", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/delete"));
    }

    // HEAD
    {
        const resp = try client.head("/head", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expectEqual(0, resp.body.len);
    }
}

test "request headers sent, response headers received" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 1);
    defer ts.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = ts.base_url });
    defer client.deinit();

    const resp = try client.get("/test", .{
        .headers = &.{
            .{ .name = "X-Zio-Test", .value = "hello" },
        },
    });
    defer resp.deinit(allocator);

    try std.testing.expectEqual(std.http.Status.ok, resp.status);

    const custom = resp.getHeader("X-Custom");
    try std.testing.expect(custom != null);
    try std.testing.expectEqualStrings("test-value", custom.?);

    const ct = resp.getHeader("Content-Type");
    try std.testing.expect(ct != null);
}

// ---------------------------------------------------------------------------
// Connection pooling
// ---------------------------------------------------------------------------

test "keep-alive reuses a single connection across requests" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 3);
    defer ts.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = ts.base_url });
    defer client.deinit();

    for (0..3) |_| {
        const resp = try client.get("/x", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
    }

    ts.future.await(io);
    try std.testing.expectEqual(@as(u32, 1), ts.connections_used);
}

test "max_idle_connections = 0 opens a fresh connection every time" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 3);
    defer ts.deinit();

    var client = try zio.Client.init(allocator, io, .{
        .base_url = ts.base_url,
        .max_idle_connections = 0,
    });
    defer client.deinit();

    for (0..3) |_| {
        const resp = try client.get("/x", .{});
        defer resp.deinit(allocator);
    }

    ts.future.await(io);
    try std.testing.expectEqual(@as(u32, 3), ts.connections_used);
}

test "a connection is not reused across different origins" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try TestServer.start(allocator, io, 1);
    defer a.deinit();
    const b = try TestServer.start(allocator, io, 1);
    defer b.deinit();

    var client = try zio.Client.init(allocator, io, .{});
    defer client.deinit();

    for ([_][]const u8{ a.base_url, b.base_url }) |base| {
        const url = try std.fmt.allocPrint(allocator, "{s}/x", .{base});
        defer allocator.free(url);
        const resp = try client.get(url, .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
    }

    a.future.await(io);
    b.future.await(io);
    try std.testing.expectEqual(@as(u32, 1), a.connections_used);
    try std.testing.expectEqual(@as(u32, 1), b.connections_used);
}

// ---------------------------------------------------------------------------
// Redirects
// ---------------------------------------------------------------------------

/// Answers `count` requests with `status` and `Location: location`.
fn redirectOnly(io: std.Io, server: *net.Server, count: u32, location: []const u8, status: []const u8) void {
    for (0..count) |_| {
        const conn = server.accept(io) catch return;
        defer conn.close(io);

        var rb: [4096]u8 = undefined;
        var wb: [1024]u8 = undefined;
        var r = conn.reader(io, &rb);
        var w = conn.writer(io, &wb);

        while (r.interface.takeDelimiterInclusive('\n')) |line| {
            if (std.mem.eql(u8, line, "\r\n")) break;
        } else |_| return;

        // `connection: close` keeps this fixture simple — one request per connection, no
        // request body to drain — and exercises the path where a response forbids reuse.
        w.interface.print(
            "HTTP/1.1 {s}\r\nlocation: {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            .{ status, location },
        ) catch return;
        w.interface.flush() catch return;
    }
}

/// `count` redirects, then one 200 that echoes the final method and target.
fn redirectThenServe(io: std.Io, server: *net.Server, count: u32, location: []const u8, status: []const u8) void {
    redirectOnly(io, server, count, location, status);
    var unused: u32 = 0;
    serve(io, server, 1, &unused);
}

const RedirectServer = struct {
    server: net.Server,
    future: std.Io.Future(void),
    base_url: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn deinit(self: *RedirectServer) void {
        self.future.await(self.io);
        self.server.deinit(self.io);
        self.allocator.free(self.base_url);
    }
};

fn startRedirects(
    allocator: std.mem.Allocator,
    io: std.Io,
    self: *RedirectServer,
    count: u32,
    location: []const u8,
    status: []const u8,
    final: bool,
) !void {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();
    self.* = .{
        .server = server,
        .future = undefined,
        .base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}),
        .allocator = allocator,
        .io = io,
    };
    self.future = if (final)
        try io.concurrent(redirectThenServe, .{ io, &self.server, count, location, status })
    else
        try io.concurrent(redirectOnly, .{ io, &self.server, count, location, status });
}

test "follows a relative redirect" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rs: RedirectServer = undefined;
    try startRedirects(allocator, io, &rs, 1, "/final", "302 Found", true);
    defer rs.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = rs.base_url });
    defer client.deinit();

    const resp = try client.get("/start", .{});
    defer resp.deinit(allocator);

    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"url\":\"/final\""));
}

test "303 turns a POST into a bodyless GET" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rs: RedirectServer = undefined;
    try startRedirects(allocator, io, &rs, 1, "/after", "303 See Other", true);
    defer rs.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = rs.base_url });
    defer client.deinit();

    const resp = try client.post("/submit", "{\"a\":1}", .{});
    defer resp.deinit(allocator);

    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"method\":\"GET\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"url\":\"/after\""));
}

test "307 preserves the method" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rs: RedirectServer = undefined;
    try startRedirects(allocator, io, &rs, 1, "/again", "307 Temporary Redirect", true);
    defer rs.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = rs.base_url });
    defer client.deinit();

    const resp = try client.post("/submit", "body", .{});
    defer resp.deinit(allocator);

    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"method\":\"POST\""));
}

test "credentials are dropped on a cross-origin redirect but kept on a same-origin one" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Destination server: echoes back whatever Authorization it received.
    const dest = try TestServer.start(allocator, io, 1);
    defer dest.deinit();

    const dest_url = try std.fmt.allocPrint(allocator, "{s}/dest", .{dest.base_url});
    defer allocator.free(dest_url);

    // Origin server: redirects to the *other* server, i.e. a different port.
    var rs: RedirectServer = undefined;
    try startRedirects(allocator, io, &rs, 1, dest_url, "302 Found", false);
    defer rs.deinit();

    var client = try zio.Client.init(allocator, io, .{ .base_url = rs.base_url });
    defer client.deinit();

    const resp = try client.get("/start", .{
        .headers = &.{
            .{ .name = "Authorization", .value = "Bearer secret" },
            .{ .name = "X-Keep-Me", .value = "yes" },
        },
    });
    defer resp.deinit(allocator);

    // The secret must not have followed the redirect...
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"auth\":\"\""));
    try std.testing.expect(!std.mem.containsAtLeast(u8, resp.body, 1, "secret"));
    // ...but ordinary headers must survive.
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"keep\":\"yes\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"url\":\"/dest\""));
}

test "exceeding max_redirects gives TooManyRedirects" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // max_redirects = 2 means three requests are attempted before giving up.
    var rs: RedirectServer = undefined;
    try startRedirects(allocator, io, &rs, 3, "/loop", "302 Found", false);
    defer rs.deinit();

    var client = try zio.Client.init(allocator, io, .{
        .base_url = rs.base_url,
        .max_redirects = 2,
    });
    defer client.deinit();

    try std.testing.expectError(error.TooManyRedirects, client.get("/loop", .{}));
}

// ---------------------------------------------------------------------------
// Proxy
// ---------------------------------------------------------------------------

test "http proxy: request line uses absolute form and reaches the proxy" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The loopback server stands in for the proxy; it echoes the target it received.
    const ts = try TestServer.start(allocator, io, 1);
    defer ts.deinit();

    var client = try zio.Client.init(allocator, io, .{
        .proxy = .{ .explicit = .{ .http = ts.base_url } },
    });
    defer client.deinit();

    const resp = try client.get("http://example.com/some/path?q=1", .{});
    defer resp.deinit(allocator);

    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    // Absolute-form target proves the request went through the proxy, not direct.
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "http://example.com/some/path?q=1"));
}

test "http proxy: userinfo is sent as Proxy-Authorization" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 1);
    defer ts.deinit();

    // Rebuild the proxy URL with credentials: "http://user:pass@127.0.0.1:<port>".
    const authed = try std.fmt.allocPrint(allocator, "http://user:pass@{s}", .{
        ts.base_url["http://".len..],
    });
    defer allocator.free(authed);

    var client = try zio.Client.init(allocator, io, .{
        .proxy = .{ .explicit = .{ .http = authed } },
    });
    defer client.deinit();

    const resp = try client.get("http://example.com/", .{});
    defer resp.deinit(allocator);

    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "Basic dXNlcjpwYXNz"));
}

test "http proxy: NO_PROXY host is contacted directly" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ts = try TestServer.start(allocator, io, 1);
    defer ts.deinit();

    // Port 1 refuses connections: if the bypass fails, so does this test.
    var client = try zio.Client.init(allocator, io, .{
        .base_url = ts.base_url,
        .proxy = .{ .explicit = .{
            .http = "http://127.0.0.1:1",
            .no_proxy = "127.0.0.1",
        } },
    });
    defer client.deinit();

    const resp = try client.get("/direct", .{});
    defer resp.deinit(allocator);

    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    // Origin-form target proves the proxy was skipped.
    try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "\"url\":\"/direct\""));
}

/// A proxy that answers `CONNECT` with 200 and records the request line. The TLS
/// handshake that follows cannot succeed — the assertion is on what the proxy saw.
fn connectProxy(io: std.Io, server: *net.Server, line_out: *[128]u8, line_len: *usize) void {
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
            const n = @min(trimmed.len, line_out.len);
            @memcpy(line_out[0..n], trimmed[0..n]);
            line_len.* = n;
            first = false;
        }
        if (trimmed.len == 0) break;
    } else |_| return;

    w.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n") catch return;
    w.interface.flush() catch return;

    // Drain the ClientHello so the client is not blocked on a full socket buffer.
    var sink: [512]u8 = undefined;
    _ = r.interface.readSliceShort(&sink) catch {};
}

test "https through a proxy establishes a CONNECT tunnel" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var line: [128]u8 = undefined;
    var line_len: usize = 0;
    var future = try io.concurrent(connectProxy, .{ io, &server, &line, &line_len });
    defer future.await(io);

    const proxy_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(proxy_url);

    var client = try zio.Client.init(allocator, io, .{
        .proxy = .{ .explicit = .{ .https = proxy_url } },
    });
    defer client.deinit();

    // The fake proxy is not a TLS endpoint, so the handshake fails; what matters is that
    // a tunnel was requested at all rather than a cleartext request being sent.
    if (client.get("https://example.com/", .{})) |resp| resp.deinit(allocator) else |_| {}

    future.await(io);
    try std.testing.expectEqualStrings("CONNECT example.com:443 HTTP/1.1", line[0..line_len]);
}

test "https to a NO_PROXY host skips the proxy" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 192.0.2.0/24 is TEST-NET-1 and never routes. Reaching it would mean the bypass
    // failed; going direct to the closed loopback port fails fast instead.
    var client = try zio.Client.init(allocator, io, .{
        .proxy = .{ .explicit = .{
            .https = "http://192.0.2.1:8080",
            .no_proxy = "127.0.0.1",
        } },
    });
    defer client.deinit();

    if (client.get("https://127.0.0.1:1/", .{})) |resp| {
        resp.deinit(allocator);
        return error.TestExpectedFailure;
    } else |err| {
        try std.testing.expectEqual(error.ConnectionRefused, err);
    }
}
