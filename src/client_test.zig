const std = @import("std");
const zio = @import("zio");

test "http methods" {
    const allocator = std.testing.allocator;

    var client = zio.Client.init(allocator, .{ .base_url = "https://httpbin.org" });
    defer client.deinit();

    // GET
    {
        const resp = try client.get("/get", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/get"));
    }

    // POST
    {
        const data = "{\"key\":\"value\"}";
        const resp = try client.post("/post", data);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/post"));
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, data));
    }

    // PUT
    {
        const data = "put body";
        const resp = try client.put("/put", data);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/put"));
    }

    // PATCH
    {
        const data = "patch body";
        const resp = try client.patch("/patch", data);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/patch"));
    }

    // DELETE
    {
        const resp = try client.delete("/delete");
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/delete"));
    }

    // HEAD
    {
        const resp = try client.head("/get");
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expectEqual(0, resp.body.len);
    }
}
