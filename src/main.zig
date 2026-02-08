const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zio.Client.init(allocator, .{
        .base_url = "https://example.com",
    });
    defer client.deinit();

    const response = try client.get("/", .{});
    defer response.deinit(allocator);

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});
}
