const std = @import("std");
const zio = @import("zio");

fn serverThread(server: *std.net.Server, num_requests: u32) void {
    const conn = server.accept() catch return;
    defer conn.stream.close();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.stream.reader(&read_buf);
    var writer = conn.stream.writer(&write_buf);

    var http_server = std.http.Server.init(reader.interface(), &writer.interface);

    for (0..num_requests) |_| {
        var request = http_server.receiveHead() catch return;
        const target = request.head.target;
        const method_str = @tagName(request.head.method);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"method\":\"{s}\",\"url\":\"{s}\"}}", .{ method_str, target }) catch return;

        request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-Custom", .value = "test-value" },
            },
        }) catch return;
    }
}

test "http methods" {
    const allocator = std.testing.allocator;

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const port = std.mem.bigToNative(u16, server.listen_address.in.sa.port);
    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    const thread = try std.Thread.spawn(.{}, serverThread, .{ &server, 6 });

    var client = zio.Client.init(allocator, .{ .base_url = base_url });
    defer client.deinit();

    // GET
    {
        const resp = try client.get("/get", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/get"));
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "GET"));
    }

    // POST
    {
        const resp = try client.post("/post", "{\"key\":\"value\"}", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/post"));
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "POST"));
    }

    // PUT
    {
        const resp = try client.put("/put", "put data", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/put"));
    }

    // PATCH
    {
        const resp = try client.patch("/patch", "patch data", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/patch"));
    }

    // DELETE
    {
        const resp = try client.delete("/delete", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.containsAtLeast(u8, resp.body, 1, "/delete"));
    }

    // HEAD
    {
        const resp = try client.head("/head", .{});
        defer resp.deinit(allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expectEqual(0, resp.body.len);
    }

    thread.join();
}

test "request headers sent, response headers received" {
    const allocator = std.testing.allocator;

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const port = std.mem.bigToNative(u16, server.listen_address.in.sa.port);
    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url);

    const thread = try std.Thread.spawn(.{}, serverThread, .{ &server, 1 });

    var client = zio.Client.init(allocator, .{ .base_url = base_url });
    defer client.deinit();

    const resp = try client.get("/test", .{
        .headers = &.{
            .{ .name = "X-Zio-Test", .value = "hello" },
        },
    });
    defer resp.deinit(allocator);

    try std.testing.expectEqual(std.http.Status.ok, resp.status);

    // Check response headers
    const custom = resp.getHeader("X-Custom");
    try std.testing.expect(custom != null);
    try std.testing.expectEqualStrings("test-value", custom.?);

    const ct = resp.getHeader("Content-Type");
    try std.testing.expect(ct != null);

    thread.join();
}
