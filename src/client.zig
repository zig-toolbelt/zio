const std = @import("std");
const Response = @import("Response.zig");

const Client = @This();

allocator: std.mem.Allocator,
http_client: std.http.Client,
base_url: []const u8,

pub const Options = struct {
    base_url: []const u8 = "",
};

pub const RequestOptions = struct {
    headers: []const std.http.Header = &.{},
};

pub const GetOptions = RequestOptions;

pub fn init(allocator: std.mem.Allocator, options: Options) Client {
    return .{
        .allocator = allocator,
        .http_client = .{ .allocator = allocator },
        .base_url = options.base_url,
    };
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

fn doRequest(self: *Client, method: std.http.Method, path: []const u8, data: ?[]const u8, options: RequestOptions) !Response {
    const full_url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
        path
    else
        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer if (full_url.ptr != path.ptr) self.allocator.free(full_url);

    const uri = try std.Uri.parse(full_url);

    var req = try self.http_client.request(method, uri, .{
        .extra_headers = options.headers,
    });
    defer req.deinit();

    // Send request
    if (method.requestHasBody()) {
        req.transfer_encoding = .{ .content_length = if (data) |d| d.len else 0 };
        var bw = try req.sendBodyUnflushed(&.{});
        if (data) |payload| try bw.writer.writeAll(payload);
        try bw.end();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);

    var header_list: std.ArrayList(std.http.Header) = .{};
    errdefer {
        for (header_list.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        header_list.deinit(self.allocator);
    }
    var hit = resp.head.iterateHeaders();
    while (hit.next()) |h| {
        const name_dup = try self.allocator.dupe(u8, h.name);
        errdefer self.allocator.free(name_dup);
        const value_dup = try self.allocator.dupe(u8, h.value);
        try header_list.append(self.allocator, .{ .name = name_dup, .value = value_dup });
    }

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();

    const decompress_buf: []u8 = switch (resp.head.content_encoding) {
        .identity => &.{},
        .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buf.len > 0) self.allocator.free(decompress_buf);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = resp.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return resp.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };

    const body_slice = try aw.toOwnedSlice();
    errdefer self.allocator.free(body_slice);
    return .{
        .status = resp.head.status,
        .body = body_slice,
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
