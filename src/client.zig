const std = @import("std");
const Response = @import("response.zig");
const proxy = @import("proxy.zig");
const Connection = @import("transport/Connection.zig");
const Exchange = @import("transport/Exchange.zig");
const Pool = @import("transport/Pool.zig");

const Client = @This();

allocator: std.mem.Allocator,
io: std.Io,
base_url: []const u8,
max_redirects: u8,
/// Owns the proxy structs and their strings.
arena: std.heap.ArenaAllocator,
proxies: proxy.Resolved,
/// Loaded lazily on the first TLS request, then reused. `ca_now` doubles as the
/// "already scanned" flag and as the instant certificate validity is judged against.
ca_bundle: std.crypto.Certificate.Bundle,
ca_lock: std.Io.RwLock,
ca_now: ?std.Io.Timestamp,
/// Idle keep-alive connections, reused across requests to the same origin.
pool: Pool,

pub const Options = struct {
    base_url: []const u8 = "",
    /// Proxy selection. Defaults to no proxying; pass `.{ .environment = init.environ_map }`
    /// to honour `HTTP_PROXY` and friends.
    proxy: proxy.Config = .none,
    /// How many `3xx` responses to follow before giving up with `error.TooManyRedirects`.
    max_redirects: u8 = 3,
    /// Idle connections kept for reuse. Zero disables pooling, making every request send
    /// `connection: close`.
    max_idle_connections: usize = 8,
};

pub const RequestOptions = struct {
    headers: []const std.http.Header = &.{},
};

pub const Error = error{
    /// The redirect chain exceeded `Options.max_redirects`.
    TooManyRedirects,
    /// A `3xx` response carried no usable `Location`.
    RedirectMissingLocation,
    UnsupportedUriScheme,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Client {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    return .{
        .allocator = allocator,
        .io = io,
        .base_url = options.base_url,
        .max_redirects = options.max_redirects,
        .proxies = try proxy.resolve(arena.allocator(), options.proxy),
        .arena = arena,
        .ca_bundle = .empty,
        .ca_lock = .init,
        .ca_now = null,
        .pool = .init(allocator, options.max_idle_connections),
    };
}

pub fn deinit(self: *Client) void {
    self.pool.deinit();
    self.ca_bundle.deinit(self.allocator);
    self.arena.deinit();
}

/// Scans the system certificate store once, on first use.
fn tlsConfig(self: *Client) !Connection.TlsConfig {
    if (self.ca_now == null) {
        const now = std.Io.Clock.real.now(self.io);
        try self.ca_bundle.rescan(self.allocator, self.io, now);
        self.ca_now = now;
    }
    return .{ .lock = &self.ca_lock, .bundle = &self.ca_bundle, .now = self.ca_now.? };
}

fn isAbsolute(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

fn isRedirect(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

/// Headers that must not survive a redirect to a different origin.
fn isCredentialHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization");
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.mem.eql(u8, a.scheme, b.scheme)) return false;
    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    var a_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var b_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const ah = a_host.toRaw(&a_buf) catch return false;
    const bh = b_host.toRaw(&b_buf) catch return false;
    if (!std.ascii.eqlIgnoreCase(ah, bh)) return false;
    return (a.port orelse defaultPort(a.scheme)) == (b.port orelse defaultPort(b.scheme));
}

fn defaultPort(scheme: []const u8) u16 {
    return if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
}

fn doRequest(
    self: *Client,
    method: std.http.Method,
    path: []const u8,
    data: ?[]const u8,
    options: RequestOptions,
) !Response {
    // Owns the current URL whenever it is not the caller's `path` verbatim.
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |b| self.allocator.free(b);

    var url: []const u8 = if (isAbsolute(path)) path else blk: {
        const joined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        owned_url = joined;
        break :blk joined;
    };

    var current_method = method;
    var current_body = data;
    var headers = options.headers;
    var redirects_left = self.max_redirects;

    // Owns the filtered header list once a cross-origin redirect drops credentials.
    var owned_headers: ?[]std.http.Header = null;
    defer if (owned_headers) |h| self.allocator.free(h);

    while (true) {
        const uri = try std.Uri.parse(url);
        const result = try self.exchange(uri, current_method, current_body, headers);

        switch (result) {
            .response => |resp| return resp,
            .redirect => |r| {
                // `r.location` is already copied out of the connection buffer.
                defer self.allocator.free(r.location);

                if (redirects_left == 0) return error.TooManyRedirects;
                redirects_left -= 1;

                const next = try self.resolveRedirect(uri, r.location);
                errdefer self.allocator.free(next);

                const next_uri = try std.Uri.parse(next);
                if (!sameOrigin(uri, next_uri)) {
                    if (try self.stripCredentials(headers)) |filtered| {
                        if (owned_headers) |old| self.allocator.free(old);
                        owned_headers = filtered;
                        headers = filtered;
                    }
                }

                // 301/302/303 turn the request into a bodyless GET; 307/308 preserve it.
                if (r.status != .temporary_redirect and r.status != .permanent_redirect) {
                    current_method = .GET;
                    current_body = null;
                }

                if (owned_url) |b| self.allocator.free(b);
                owned_url = next;
                url = next;
            },
        }
    }
}

/// Returns a newly allocated header list with credential-bearing entries removed, or
/// `null` when there was nothing to remove. Entries alias the caller's strings.
fn stripCredentials(self: *Client, headers: []const std.http.Header) !?[]std.http.Header {
    var keep: usize = 0;
    for (headers) |h| {
        if (!isCredentialHeader(h.name)) keep += 1;
    }
    if (keep == headers.len) return null;

    const out = try self.allocator.alloc(std.http.Header, keep);
    var i: usize = 0;
    for (headers) |h| {
        if (isCredentialHeader(h.name)) continue;
        out[i] = h;
        i += 1;
    }
    return out;
}

fn resolveRedirect(self: *Client, base: std.Uri, location: []const u8) ![]u8 {
    if (isAbsolute(location)) return self.allocator.dupe(u8, location);

    // `resolveInPlace` expects the reference at the head of `aux` and uses the rest
    // as scratch for the resolved components.
    const aux = try self.allocator.alloc(u8, location.len * 2 + 512);
    defer self.allocator.free(aux);
    @memcpy(aux[0..location.len], location);
    var aux_slice: []u8 = aux;
    const resolved = std.Uri.resolveInPlace(base, location.len, &aux_slice) catch
        return error.RedirectMissingLocation;

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();
    try resolved.writeToStream(&aw.writer, .{
        .scheme = true,
        .authority = true,
        .path = true,
        .query = true,
    });
    return aw.toOwnedSlice();
}

const Outcome = union(enum) {
    response: Response,
    redirect: struct {
        status: std.http.Status,
        /// Heap-allocated copy; the caller frees it.
        location: []u8,
    },
};

/// Performs exactly one request/response round trip, without following redirects.
fn exchange(
    self: *Client,
    uri: std.Uri,
    method: std.http.Method,
    body: ?[]const u8,
    headers: []const std.http.Header,
) !Outcome {
    const protocol: Connection.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        .tls
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        .plain
    else
        return error.UnsupportedUriScheme;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);
    const port = uri.port orelse defaultPort(uri.scheme);

    const configured = switch (protocol) {
        .plain => self.proxies.http,
        .tls => self.proxies.https,
    };
    const via_proxy = if (configured) |p| !self.proxies.bypasses(host.bytes, port) and !isSelf(p, host.bytes, port) else false;
    const p = if (via_proxy) configured.? else null;

    // Plain HTTP uses forward-proxy form: connect to the proxy, send an absolute URI.
    // HTTPS tunnels with CONNECT and then runs TLS over the tunnel — the thing
    // `std.http.Client` cannot do (see upstream_bug.md).
    const forward = via_proxy and protocol == .plain;
    const tunnel: ?Connection.Tunnel = if (via_proxy and protocol == .tls) .{
        .host = p.?.host.bytes,
        .port = p.?.port,
        .authorization = p.?.authorization,
    } else null;

    // A forward proxy terminates the TCP connection, so it is part of the pool identity
    // only for tunnels; for forward proxying the connection simply *is* to the proxy.
    const key: Connection.Key = .{
        .protocol = protocol,
        .host = if (forward) p.?.host.bytes else host.bytes,
        .port = if (forward) p.?.port else port,
        .proxy_host = if (tunnel) |t| t.host else null,
        .proxy_port = if (tunnel) |t| t.port else 0,
    };

    const keep_alive = self.pool.max_idle > 0;

    const conn = self.pool.acquire(self.io, key) orelse try Connection.connect(self.allocator, self.io, .{
        .host = key.host,
        .port = key.port,
        .protocol = protocol,
        .tunnel = tunnel,
        .tls = if (protocol == .tls) try self.tlsConfig() else null,
    });
    // Anything that goes wrong mid-exchange leaves the stream at an unknown offset.
    var released = false;
    errdefer if (!released) {
        conn.closing = true;
        self.pool.release(self.io, conn);
    };

    var ex: Exchange = undefined;
    ex.init(conn, Exchange.default_max_head_len);

    try ex.send(.{
        .method = method,
        .uri = uri,
        .absolute_target = forward,
        .headers = headers,
        .body = body,
        .keep_alive = keep_alive,
        .proxy_authorization = if (forward) p.?.authorization else null,
    });

    const response_head = try ex.receiveHead();

    if (isRedirect(response_head.status)) {
        const raw = response_head.location orelse return error.RedirectMissingLocation;
        // Copy before the body is drained: `location` points into the connection buffer.
        const location = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(location);

        try self.discardBody(&ex, response_head, method);
        conn.closing = !keep_alive or !response_head.keep_alive or ex.reader.state != .ready;
        released = true;
        self.pool.release(self.io, conn);

        return .{ .redirect = .{ .status = response_head.status, .location = location } };
    }

    const response = try self.collect(&ex, response_head, method);
    conn.closing = !keep_alive or !response_head.keep_alive or ex.reader.state != .ready;
    released = true;
    self.pool.release(self.io, conn);
    return .{ .response = response };
}

/// Consumes a response body that the caller does not want, so the connection is left at a
/// message boundary and stays poolable.
fn discardBody(
    self: *Client,
    ex: *Exchange,
    response_head: std.http.Client.Response.Head,
    method: std.http.Method,
) !void {
    if (!method.responseHasBody()) return;

    const min = response_head.content_encoding.minBufferCapacity();
    const decompress_buf: []u8 = if (min == 0) &.{} else try self.allocator.alloc(u8, min);
    defer if (decompress_buf.len > 0) self.allocator.free(decompress_buf);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = ex.bodyReader(response_head, &transfer_buf, &decompress, decompress_buf);
    _ = reader.discardRemaining() catch |err| switch (err) {
        error.ReadFailed => return ex.bodyErr() orelse error.ReadFailed,
    };
}

/// True when the proxy is the very host we are trying to reach, in which case going
/// "through" it would be a loop.
fn isSelf(p: *const std.http.Client.Proxy, host: []const u8, port: u16) bool {
    return p.port == port and std.ascii.eqlIgnoreCase(p.host.bytes, host);
}

/// Buffers the whole response into an owned `Response`.
fn collect(
    self: *Client,
    ex: *Exchange,
    response_head: std.http.Client.Response.Head,
    method: std.http.Method,
) !Response {
    var header_list: std.ArrayList(std.http.Header) = .empty;
    errdefer {
        for (header_list.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        header_list.deinit(self.allocator);
    }

    var it = response_head.iterateHeaders();
    while (it.next()) |h| {
        const name = try self.allocator.dupe(u8, h.name);
        errdefer self.allocator.free(name);
        const value = try self.allocator.dupe(u8, h.value);
        errdefer self.allocator.free(value);
        try header_list.append(self.allocator, .{ .name = name, .value = value });
    }

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();

    if (method.responseHasBody()) {
        const decompress_buf: []u8 = switch (response_head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buf.len > 0) self.allocator.free(decompress_buf);

        var transfer_buf: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = ex.bodyReader(response_head, &transfer_buf, &decompress, decompress_buf);
        _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
            error.ReadFailed => return ex.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };
    }

    const body = try aw.toOwnedSlice();
    errdefer self.allocator.free(body);
    return .{
        .status = response_head.status,
        .body = body,
        .headers = try header_list.toOwnedSlice(self.allocator),
    };
}

pub fn get(self: *Client, path: []const u8, options: RequestOptions) !Response {
    return self.doRequest(.GET, path, null, options);
}

pub fn post(self: *Client, path: []const u8, data: ?[]const u8, options: RequestOptions) !Response {
    return self.doRequest(.POST, path, data, options);
}

pub fn put(self: *Client, path: []const u8, data: ?[]const u8, options: RequestOptions) !Response {
    return self.doRequest(.PUT, path, data, options);
}

pub fn patch(self: *Client, path: []const u8, data: ?[]const u8, options: RequestOptions) !Response {
    return self.doRequest(.PATCH, path, data, options);
}

pub fn delete(self: *Client, path: []const u8, options: RequestOptions) !Response {
    return self.doRequest(.DELETE, path, null, options);
}

pub fn head(self: *Client, path: []const u8, options: RequestOptions) !Response {
    return self.doRequest(.HEAD, path, null, options);
}
