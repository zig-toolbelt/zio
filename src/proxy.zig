//! Proxy configuration for `zio.Client`.
//!
//! Proxies come either from explicit URLs or from the environment. `std.http.Client`
//! implements neither `NO_PROXY` bypass rules nor lowercase environment variables
//! consistently, so both are handled here.

const std = @import("std");

const http = std.http;
const HostName = std.Io.net.HostName;
const Allocator = std.mem.Allocator;

/// How a `Client` should choose a proxy.
pub const Config = union(enum) {
    /// Never proxy, regardless of the environment.
    none,
    /// Discover proxies from the environment: `http_proxy`/`HTTP_PROXY`,
    /// `https_proxy`/`HTTPS_PROXY`, `all_proxy`/`ALL_PROXY`, and `no_proxy`/`NO_PROXY`.
    ///
    /// The map comes from `std.process.Init.environ_map`.
    environment: *const std.process.Environ.Map,
    /// Explicit proxy URLs.
    explicit: Explicit,

    pub const Explicit = struct {
        /// Proxy for `http://` targets, e.g. `"http://user:pass@proxy.corp:8080"`.
        /// A bare `"host:port"` is accepted and assumed to be `http`.
        http: ?[]const u8 = null,
        /// Proxy for `https://` targets. See `Client.Error.HttpsThroughProxyUnsupported`
        /// for the current limitation.
        https: ?[]const u8 = null,
        /// Bypass list in `NO_PROXY` syntax, e.g.
        /// `"localhost,127.0.0.1,.internal.example.com,example.org:8080"`.
        no_proxy: ?[]const u8 = null,
    };
};

/// A resolved proxy configuration. All memory is owned by the arena passed to `resolve`.
pub const Resolved = struct {
    http: ?*http.Client.Proxy = null,
    https: ?*http.Client.Proxy = null,
    bypass: Bypass = .{},

    /// Whether requests to `host`:`port` must skip the proxy.
    pub fn bypasses(self: Resolved, host: []const u8, port: u16) bool {
        return self.bypass.matches(host, port);
    }
};

/// Parsed `NO_PROXY` rules.
pub const Bypass = struct {
    /// Set by a bare `*` entry: every host bypasses the proxy.
    all: bool = false,
    rules: []const Rule = &.{},

    pub const Rule = struct {
        /// Lowercased host, with any leading `.` stripped.
        host: []const u8,
        /// When set, the rule only applies to this port.
        port: ?u16 = null,
    };

    pub fn matches(self: Bypass, host: []const u8, port: u16) bool {
        if (self.all) return true;
        for (self.rules) |rule| if (matchesRule(rule, host, port)) return true;
        return false;
    }

    /// A rule matches the host itself or any subdomain of it, following the same
    /// semantics as Go's `httpproxy` and curl: `example.com` matches both
    /// `example.com` and `api.example.com`, but not `notexample.com`.
    fn matchesRule(rule: Rule, host: []const u8, port: u16) bool {
        if (rule.port) |p| {
            if (p != port) return false;
        }
        if (rule.host.len == 0) return false;
        if (host.len == rule.host.len) return std.ascii.eqlIgnoreCase(host, rule.host);
        if (host.len > rule.host.len) {
            const start = host.len - rule.host.len;
            if (host[start - 1] != '.') return false;
            return std.ascii.eqlIgnoreCase(host[start..], rule.host);
        }
        return false;
    }
};

pub const ParseError = error{
    /// The proxy URL could not be parsed, or used a scheme other than http/https.
    InvalidProxyUrl,
} || Allocator.Error;

/// Resolves `config` into proxy structs owned by `arena`.
pub fn resolve(arena: Allocator, config: Config) ParseError!Resolved {
    return switch (config) {
        .none => .{},
        .explicit => |e| .{
            .http = if (e.http) |url| try parseUrl(arena, url) else null,
            .https = if (e.https) |url| try parseUrl(arena, url) else null,
            .bypass = try parseBypass(arena, e.no_proxy orelse ""),
        },
        .environment => |env| .{
            .http = try fromEnv(arena, env, &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" }),
            .https = try fromEnv(arena, env, &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }),
            .bypass = try parseBypass(arena, envFirst(env, &.{ "no_proxy", "NO_PROXY" }) orelse ""),
        },
    };
}

fn envFirst(env: *const std.process.Environ.Map, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = env.get(name) orelse continue;
        if (value.len == 0) continue;
        return value;
    }
    return null;
}

fn fromEnv(
    arena: Allocator,
    env: *const std.process.Environ.Map,
    names: []const []const u8,
) ParseError!?*http.Client.Proxy {
    const value = envFirst(env, names) orelse return null;
    return parseUrl(arena, value);
}

/// Parses a proxy URL into a `std.http.Client.Proxy`. Accepts a bare `host:port`,
/// which is treated as `http://host:port`, matching curl and Go.
pub fn parseUrl(arena: Allocator, url: []const u8) ParseError!?*http.Client.Proxy {
    if (url.len == 0) return null;

    // A bare `host:port` parses as a URI whose *scheme* is the hostname, so the presence
    // of "://" is what decides between a full URL and a host. (`std.Uri.parse` alone
    // would read "proxy.corp:3128" as scheme "proxy.corp" with path "3128".)
    const uri = if (std.mem.indexOf(u8, url, "://") != null)
        std.Uri.parse(url) catch return error.InvalidProxyUrl
    else authority: {
        const text = if (std.mem.startsWith(u8, url, "//"))
            url
        else
            try std.fmt.allocPrint(arena, "//{s}", .{url});
        break :authority std.Uri.parseAfterScheme("http", text) catch return error.InvalidProxyUrl;
    };

    const protocol = http.Client.Protocol.fromUri(uri) orelse return error.InvalidProxyUrl;
    const host = uri.getHostAlloc(arena) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidProxyUrl,
    };

    // Basic credentials from the userinfo component become `Proxy-Authorization`.
    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) a: {
        const buf = try arena.alloc(u8, http.Client.basic_authorization.valueLengthFromUri(uri));
        std.debug.assert(http.Client.basic_authorization.value(uri, buf).len == buf.len);
        break :a buf;
    } else null;

    const proxy = try arena.create(http.Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = host,
        .authorization = authorization,
        .port = uri.port orelse defaultPort(protocol),
        // Forward-proxy mode (absolute-URI request line), which is the correct form for
        // plain HTTP. Left false deliberately: `std` would otherwise prefer a CONNECT
        // tunnel, and it does not layer TLS over one. Flip this once that is fixed and
        // `Client.ProxyError` goes away.
        .supports_connect = false,
    };
    return proxy;
}

pub fn defaultPort(protocol: http.Client.Protocol) u16 {
    return switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

/// Parses a `NO_PROXY`-style list. Entries are separated by commas or whitespace.
fn parseBypass(arena: Allocator, spec: []const u8) Allocator.Error!Bypass {
    var rules: std.ArrayList(Bypass.Rule) = .empty;
    errdefer rules.deinit(arena);

    var it = std.mem.tokenizeAny(u8, spec, ", \t\r\n");
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, ". \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return .{ .all = true };

        const host, const port = splitHostPort(entry);
        if (host.len == 0) continue;

        const lowered = try arena.alloc(u8, host.len);
        _ = std.ascii.lowerString(lowered, host);
        try rules.append(arena, .{ .host = lowered, .port = port });
    }

    return .{ .rules = try rules.toOwnedSlice(arena) };
}

/// Splits a trailing `:port` off an entry. Bracketed IPv6 literals keep their brackets
/// stripped; an unparseable port is treated as part of the host.
fn splitHostPort(entry: []const u8) struct { []const u8, ?u16 } {
    if (entry[0] == '[') {
        const close = std.mem.indexOfScalar(u8, entry, ']') orelse return .{ entry, null };
        const host = entry[1..close];
        const rest = entry[close + 1 ..];
        if (rest.len > 1 and rest[0] == ':') {
            const port = std.fmt.parseInt(u16, rest[1..], 10) catch return .{ host, null };
            return .{ host, port };
        }
        return .{ host, null };
    }

    const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return .{ entry, null };
    // More than one colon means a bare IPv6 literal, which carries no port.
    if (std.mem.indexOfScalar(u8, entry, ':').? != colon) return .{ entry, null };
    const port = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch return .{ entry, null };
    return .{ entry[0..colon], port };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testBypass(arena: Allocator, spec: []const u8) !Bypass {
    return parseBypass(arena, spec);
}

test "NO_PROXY: exact host and subdomains" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const b = try testBypass(arena.allocator(), "example.com");
    try testing.expect(b.matches("example.com", 80));
    try testing.expect(b.matches("api.example.com", 80));
    try testing.expect(b.matches("a.b.example.com", 443));

    // A shared suffix that is not a dot boundary must not match.
    try testing.expect(!b.matches("notexample.com", 80));
    try testing.expect(!b.matches("example.com.evil.net", 80));
    try testing.expect(!b.matches("example.org", 80));
}

test "NO_PROXY: leading dot is equivalent to bare host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const b = try testBypass(arena.allocator(), ".internal.corp");
    try testing.expect(b.matches("internal.corp", 80));
    try testing.expect(b.matches("db.internal.corp", 80));
    try testing.expect(!b.matches("internal.corp.io", 80));
}

test "NO_PROXY: port-scoped entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const b = try testBypass(arena.allocator(), "example.com:8080");
    try testing.expect(b.matches("example.com", 8080));
    try testing.expect(b.matches("api.example.com", 8080));
    try testing.expect(!b.matches("example.com", 80));
}

test "NO_PROXY: wildcard, case, separators and empties" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const star = try testBypass(a, "example.com,*");
    try testing.expect(star.matches("anything.at.all", 1234));

    const mixed = try testBypass(a, "EXAMPLE.com");
    try testing.expect(mixed.matches("ExAmPlE.CoM", 80));
    try testing.expect(mixed.matches("API.Example.Com", 80));

    const spaced = try testBypass(a, "  localhost , 127.0.0.1\t,, .corp  ");
    try testing.expect(spaced.matches("localhost", 80));
    try testing.expect(spaced.matches("127.0.0.1", 80));
    try testing.expect(spaced.matches("host.corp", 80));
    try testing.expect(!spaced.matches("example.com", 80));

    const empty = try testBypass(a, "");
    try testing.expect(!empty.matches("localhost", 80));
    try testing.expect(!empty.all);
}

test "NO_PROXY: bracketed IPv6 with and without port" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_port = try testBypass(a, "[::1]:8080");
    try testing.expect(with_port.matches("::1", 8080));
    try testing.expect(!with_port.matches("::1", 80));

    const bare = try testBypass(a, "[fe80::1]");
    try testing.expect(bare.matches("fe80::1", 443));
}

test "proxy URL: scheme, host and default ports" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const explicit_port = (try parseUrl(a, "http://proxy.corp:8080")).?;
    try testing.expectEqual(http.Client.Protocol.plain, explicit_port.protocol);
    try testing.expectEqualStrings("proxy.corp", explicit_port.host.bytes);
    try testing.expectEqual(@as(u16, 8080), explicit_port.port);
    try testing.expectEqual(@as(?[]const u8, null), explicit_port.authorization);

    const http_default = (try parseUrl(a, "http://proxy.corp")).?;
    try testing.expectEqual(@as(u16, 80), http_default.port);

    const https_default = (try parseUrl(a, "https://proxy.corp")).?;
    try testing.expectEqual(http.Client.Protocol.tls, https_default.protocol);
    try testing.expectEqual(@as(u16, 443), https_default.port);
}

test "proxy URL: bare host:port defaults to http" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const p = (try parseUrl(arena.allocator(), "proxy.corp:3128")).?;
    try testing.expectEqual(http.Client.Protocol.plain, p.protocol);
    try testing.expectEqualStrings("proxy.corp", p.host.bytes);
    try testing.expectEqual(@as(u16, 3128), p.port);
}

test "proxy URL: userinfo becomes Proxy-Authorization" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const p = (try parseUrl(arena.allocator(), "http://user:pass@proxy.corp:3128")).?;
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", p.authorization.?);
}

test "proxy URL: empty yields null, junk yields an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(?*http.Client.Proxy, null), try parseUrl(a, ""));
    try testing.expectError(error.InvalidProxyUrl, parseUrl(a, "ftp://proxy.corp"));
}

test "resolve: none ignores everything" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const r = try resolve(arena.allocator(), .none);
    try testing.expectEqual(@as(?*http.Client.Proxy, null), r.http);
    try testing.expectEqual(@as(?*http.Client.Proxy, null), r.https);
    try testing.expect(!r.bypasses("example.com", 80));
}

test "resolve: explicit config wires both protocols and bypass" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const r = try resolve(arena.allocator(), .{ .explicit = .{
        .http = "http://p1.corp:8080",
        .https = "http://p2.corp:8443",
        .no_proxy = "localhost,.internal",
    } });

    try testing.expectEqual(@as(u16, 8080), r.http.?.port);
    try testing.expectEqual(@as(u16, 8443), r.https.?.port);
    try testing.expect(r.bypasses("localhost", 80));
    try testing.expect(r.bypasses("db.internal", 5432));
    try testing.expect(!r.bypasses("example.com", 80));
}
