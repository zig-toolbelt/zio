const std = @import("std");
const Response = @import("Response.zig");

const Client = @This();

allocator: std.mem.Allocator,
http_client: std.http.Client,
base_url: []const u8,

pub const Options = struct {
    base_url: []const u8 = "",
};

pub const GetOptions = struct {};

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

fn request(self: *Client, method: std.http.Method, path: []const u8, data: ?[]const u8) !Response {
    const full_url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
        path
    else
        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });

    defer if (full_url.ptr != path.ptr) self.allocator.free(full_url);

    var body_slice: ?[]u8 = null;
    if (data) |d| body_slice = try self.allocator.dupe(u8, d);
    errdefer if (body_slice) |bs| self.allocator.free(bs);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();

    const result = try self.http_client.fetch(.{
        .method = method,
        .payload = body_slice,
        .location = .{ .url = full_url },
        .response_writer = &aw.writer,
    });

    return .{
        .status = result.status,
        .body = try aw.toOwnedSlice(),
    };
}

pub fn get(self: *Client, url: []const u8, options: GetOptions) !Response {
    _ = options;
    return try self.request(.GET, url, null);
}

pub fn post(self: *Client, path: []const u8, data: ?[]const u8) !Response {
    return try self.request(.POST, path, data);
}

pub fn put(self: *Client, path: []const u8, data: ?[]const u8) !Response {
    return try self.request(.PUT, path, data);
}

pub fn patch(self: *Client, path: []const u8, data: ?[]const u8) !Response {
    return try self.request(.PATCH, path, data);
}

pub fn delete(self: *Client, path: []const u8) !Response {
    return try self.request(.DELETE, path, null);
}

pub fn head(self: *Client, path: []const u8) !Response {
    return try self.request(.HEAD, path, null);
}
