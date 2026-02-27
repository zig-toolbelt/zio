const std = @import("std");

const Response = @This();

status: std.http.Status,
body: []const u8,

pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
    allocator.free(self.body);
}
