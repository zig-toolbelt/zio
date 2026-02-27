const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zio.Client.init(allocator, .{
        .base_url = "https://httpbin.org",
    });
    defer client.deinit();

    const response = try client.get("/", .{});
    defer response.deinit(allocator);

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body length: {d}\n", .{response.body.len});

    // Examples for new HTTP methods using httpbin.org
    const post_response = try client.post("/post", "{\"name\":\"test\"}");
    defer post_response.deinit(allocator);
    std.debug.print("\nPOST Status: {}\n", .{post_response.status});
    std.debug.print("POST Body preview: {s}\n", .{post_response.body[0..@min(post_response.body.len, 100)]});

    const put_response = try client.put("/put", "put data");
    defer put_response.deinit(allocator);
    std.debug.print("PUT Status: {}\n", .{put_response.status});

    const patch_response = try client.patch("/patch", "patch data");
    defer patch_response.deinit(allocator);
    std.debug.print("PATCH Status: {}\n", .{patch_response.status});

    const delete_response = try client.delete("/delete");
    defer delete_response.deinit(allocator);
    std.debug.print("DELETE Status: {}\n", .{delete_response.status});

    const head_response = try client.head("/get");
    defer head_response.deinit(allocator);
    std.debug.print("HEAD Status: {}\n", .{head_response.status});
    std.debug.print("HEAD Body length: {d} (should be 0)\n", .{head_response.body.len});
}
