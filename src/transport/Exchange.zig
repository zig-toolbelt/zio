//! One HTTP/1.1 request/response exchange over a `Connection`.
//!
//! Request-head serialisation is ours; response framing, chunked decoding and content
//! decompression are delegated to `std.http.Reader`, which accepts any `std.Io.Reader`
//! and therefore works just as well over our own TLS or tunnelled streams.
//!
//! `std.http.Reader` is self-referential, so an `Exchange` must be initialised in place
//! and never moved afterwards.

const std = @import("std");
const Connection = @import("Connection.zig");

const Io = std.Io;
const http = std.http;

const Exchange = @This();

connection: *Connection,
reader: http.Reader,

pub const default_user_agent = "zio (+https://github.com/etroynov/zio)";
pub const default_max_head_len = 16 * 1024;

pub const Options = struct {
    method: http.Method,
    uri: std.Uri,
    /// Emit the absolute URI in the request line, as a forward proxy requires.
    /// Origin-form (`/path?query`) otherwise.
    absolute_target: bool = false,
    /// Caller-supplied headers. Any of them suppresses the corresponding default below,
    /// matched case-insensitively.
    headers: []const http.Header = &.{},
    body: ?[]const u8 = null,
    keep_alive: bool = true,
    /// `null` omits the header entirely.
    user_agent: ?[]const u8 = default_user_agent,
    /// Advertise the encodings `std.http.Decompress` can handle.
    accept_encoding: bool = true,
    /// Verbatim `Proxy-Authorization` value, for forward-proxy requests.
    proxy_authorization: ?[]const u8 = null,
};

/// Initialises in place. `self` must outlive the exchange and must not be moved.
pub fn init(self: *Exchange, connection: *Connection, max_head_len: usize) void {
    self.* = .{
        .connection = connection,
        .reader = .{
            .in = connection.reader(),
            // Populated by `std.http.Reader` when a body reader is requested.
            .interface = undefined,
            .state = .ready,
            .max_head_len = max_head_len,
        },
    };
}

/// Writes the request head and body, then flushes.
pub fn send(self: *Exchange, options: Options) Io.Writer.Error!void {
    const w = self.connection.writer();
    try writeHead(w, options);
    // Bodies are fixed-size slices today, so `content-length` framing suffices and
    // `std.http.BodyWriter` is not needed. Streaming uploads will want it.
    if (options.body) |body| try w.writeAll(body);
    try w.flush();
}

/// Reads and parses the response head. Must be called exactly once, after `send`.
pub fn receiveHead(self: *Exchange) !http.Client.Response.Head {
    const bytes = try self.reader.receiveHead();
    return http.Client.Response.Head.parse(bytes);
}

/// Returns a reader over the decoded response body. `head` must come from `receiveHead`.
///
/// `decompress` and `decompress_buffer` must outlive the returned reader;
/// `decompress_buffer` must be at least `head.content_encoding.minBufferCapacity()`.
pub fn bodyReader(
    self: *Exchange,
    head: http.Client.Response.Head,
    transfer_buffer: []u8,
    decompress: *http.Decompress,
    decompress_buffer: []u8,
) *Io.Reader {
    return self.reader.bodyReaderDecompressing(
        transfer_buffer,
        head.transfer_encoding,
        head.content_length,
        head.content_encoding,
        decompress,
        decompress_buffer,
    );
}

/// The underlying framing error, when a body read fails with `error.ReadFailed`.
pub fn bodyErr(self: *const Exchange) ?http.Reader.BodyError {
    return self.reader.body_err;
}

fn hasHeader(headers: []const http.Header, name: []const u8) bool {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

fn writeHead(w: *Io.Writer, o: Options) Io.Writer.Error!void {
    try w.writeAll(@tagName(o.method));
    try w.writeByte(' ');
    if (o.method == .CONNECT) {
        try o.uri.writeToStream(w, .{ .authority = true });
    } else {
        try o.uri.writeToStream(w, .{
            .scheme = o.absolute_target,
            .authentication = o.absolute_target,
            .authority = o.absolute_target,
            .path = true,
            .query = true,
        });
    }
    try w.writeAll(" HTTP/1.1\r\n");

    if (!hasHeader(o.headers, "host")) {
        try w.writeAll("host: ");
        try o.uri.writeToStream(w, .{ .authority = true });
        try w.writeAll("\r\n");
    }

    if ((o.uri.user != null or o.uri.password != null) and !hasHeader(o.headers, "authorization")) {
        try w.writeAll("authorization: ");
        try http.Client.basic_authorization.write(o.uri, w);
        try w.writeAll("\r\n");
    }

    if (o.user_agent) |ua| {
        if (!hasHeader(o.headers, "user-agent")) try w.print("user-agent: {s}\r\n", .{ua});
    }

    if (!hasHeader(o.headers, "connection")) {
        try w.writeAll(if (o.keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
    }

    if (o.accept_encoding and !hasHeader(o.headers, "accept-encoding")) {
        try w.writeAll("accept-encoding: gzip, deflate, zstd\r\n");
    }

    if (o.proxy_authorization) |auth| try w.print("proxy-authorization: {s}\r\n", .{auth});

    if (o.method.requestHasBody() and !hasHeader(o.headers, "content-length")) {
        try w.print("content-length: {d}\r\n", .{if (o.body) |b| b.len else 0});
    }

    for (o.headers) |h| {
        std.debug.assert(h.name.len != 0);
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }

    try w.writeAll("\r\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Renders a request head to a string so the wire format can be asserted directly.
fn renderHead(buf: []u8, o: Options) ![]u8 {
    var w: Io.Writer = .fixed(buf);
    try writeHead(&w, o);
    return w.buffered();
}

test "request line: origin form by default, absolute form for a forward proxy" {
    var buf: [512]u8 = undefined;
    const uri = try std.Uri.parse("http://example.com/a/b?q=1");

    const origin = try renderHead(&buf, .{ .method = .GET, .uri = uri, .user_agent = null });
    try testing.expect(std.mem.startsWith(u8, origin, "GET /a/b?q=1 HTTP/1.1\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, origin, 1, "host: example.com\r\n"));

    var buf2: [512]u8 = undefined;
    const absolute = try renderHead(&buf2, .{
        .method = .GET,
        .uri = uri,
        .absolute_target = true,
        .user_agent = null,
    });
    try testing.expect(std.mem.startsWith(u8, absolute, "GET http://example.com/a/b?q=1 HTTP/1.1\r\n"));
}

test "request line: empty path becomes /" {
    var buf: [512]u8 = undefined;
    const head = try renderHead(&buf, .{
        .method = .GET,
        .uri = try std.Uri.parse("http://example.com"),
        .user_agent = null,
    });
    try testing.expect(std.mem.startsWith(u8, head, "GET / HTTP/1.1\r\n"));
}

test "caller headers suppress the matching defaults, case-insensitively" {
    var buf: [512]u8 = undefined;
    const head = try renderHead(&buf, .{
        .method = .GET,
        .uri = try std.Uri.parse("http://example.com/"),
        .headers = &.{
            .{ .name = "Host", .value = "override.example" },
            .{ .name = "USER-AGENT", .value = "custom/1" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    });

    try testing.expect(!std.mem.containsAtLeast(u8, head, 1, "host: example.com"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "override.example"));
    try testing.expect(!std.mem.containsAtLeast(u8, head, 1, default_user_agent));
    try testing.expect(!std.mem.containsAtLeast(u8, head, 1, "gzip"));
}

test "userinfo in the URI becomes an Authorization header" {
    var buf: [512]u8 = undefined;
    const head = try renderHead(&buf, .{
        .method = .GET,
        .uri = try std.Uri.parse("http://user:pass@example.com/"),
        .user_agent = null,
    });
    try testing.expect(std.mem.containsAtLeast(u8, head, 1, "authorization: Basic dXNlcjpwYXNz\r\n"));
}

test "content-length is emitted only for methods that carry a body" {
    var buf: [512]u8 = undefined;
    const get = try renderHead(&buf, .{
        .method = .GET,
        .uri = try std.Uri.parse("http://example.com/"),
        .user_agent = null,
    });
    try testing.expect(!std.mem.containsAtLeast(u8, get, 1, "content-length"));

    var buf2: [512]u8 = undefined;
    const post = try renderHead(&buf2, .{
        .method = .POST,
        .uri = try std.Uri.parse("http://example.com/"),
        .body = "hello",
        .user_agent = null,
    });
    try testing.expect(std.mem.containsAtLeast(u8, post, 1, "content-length: 5\r\n"));

    var buf3: [512]u8 = undefined;
    const empty_post = try renderHead(&buf3, .{
        .method = .POST,
        .uri = try std.Uri.parse("http://example.com/"),
        .user_agent = null,
    });
    try testing.expect(std.mem.containsAtLeast(u8, empty_post, 1, "content-length: 0\r\n"));
}

const net = std.Io.net;

/// Reads a request head, then replies with `response` verbatim.
fn cannedOrigin(io: Io, server: *net.Server, response: []const u8, seen: *[512]u8, seen_len: *usize) void {
    const conn = server.accept(io) catch return;
    defer conn.close(io);

    var rb: [4096]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var r = conn.reader(io, &rb);
    var w = conn.writer(io, &wb);

    while (r.interface.takeDelimiterInclusive('\n')) |line| {
        const n = @min(line.len, seen.len - seen_len.*);
        @memcpy(seen[seen_len.*..][0..n], line[0..n]);
        seen_len.* += n;
        if (std.mem.eql(u8, line, "\r\n")) break;
    } else |_| return;

    w.interface.writeAll(response) catch return;
    w.interface.flush() catch return;
}

/// Drives one exchange against a canned response and returns the decoded body.
fn roundTrip(gpa: std.mem.Allocator, io: Io, response: []const u8, o: Options, request_out: *[512]u8, request_len: *usize) ![]u8 {
    const addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var future = try io.concurrent(cannedOrigin, .{ io, &server, response, request_out, request_len });
    defer future.await(io);

    const conn = try Connection.connect(gpa, io, .{
        .host = "127.0.0.1",
        .port = port,
        .protocol = .plain,
    });
    defer conn.deinit();

    var ex: Exchange = undefined;
    ex.init(conn, default_max_head_len);

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{port});
    defer gpa.free(url);

    var opts = o;
    opts.uri = try std.Uri.parse(url);

    try ex.send(opts);
    const head = try ex.receiveHead();

    var transfer_buf: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const body_reader = ex.bodyReader(head, &transfer_buf, &decompress, &decompress_buf);

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    _ = body_reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return ex.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
    return aw.toOwnedSlice();
}

test "end to end: content-length body" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seen: [512]u8 = undefined;
    var seen_len: usize = 0;

    const body = try roundTrip(
        gpa,
        io,
        "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello",
        .{ .method = .GET, .uri = undefined },
        &seen,
        &seen_len,
    );
    defer gpa.free(body);

    try testing.expectEqualStrings("hello", body);
    try testing.expect(std.mem.startsWith(u8, seen[0..seen_len], "GET / HTTP/1.1\r\n"));
}

test "end to end: chunked body is dechunked by std.http.Reader" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seen: [512]u8 = undefined;
    var seen_len: usize = 0;

    const body = try roundTrip(
        gpa,
        io,
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
        .{ .method = .GET, .uri = undefined },
        &seen,
        &seen_len,
    );
    defer gpa.free(body);

    try testing.expectEqualStrings("hello world", body);
}

test "keep-alive and proxy-authorization" {
    var buf: [512]u8 = undefined;
    const head = try renderHead(&buf, .{
        .method = .GET,
        .uri = try std.Uri.parse("http://example.com/"),
        .keep_alive = false,
        .proxy_authorization = "Basic dXNlcjpwYXNz",
        .user_agent = null,
    });
    try testing.expect(std.mem.containsAtLeast(u8, head, 1, "connection: close\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, head, 1, "proxy-authorization: Basic dXNlcjpwYXNz\r\n"));
}
