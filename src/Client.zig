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

pub fn get(self: *Client, url: []const u8, options: GetOptions) !Response {
    _ = options;

    const full_url = if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))
        url
    else
        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, url });

    defer if (full_url.ptr != url.ptr) self.allocator.free(full_url);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer aw.deinit();

    const result = try self.http_client.fetch(.{
        .location = .{ .url = full_url },
        .response_writer = &aw.writer,
    });

    return .{
        .status = result.status,
        .body = try aw.toOwnedSlice(),
    };
}
