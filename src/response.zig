const std = @import("std");

const Response = @This();

status: std.http.Status,
body: []const u8,
headers: []const std.http.Header,

pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
    for (self.headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(self.headers);
    allocator.free(self.body);
}

pub fn getHeader(self: Response, name: []const u8) ?[]const u8 {
    for (self.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}
