//! Self-contained demo: spins up a loopback HTTP server and drives it with zio.
//! Requires no network access.

const std = @import("std");
const zio = @import("zio");

const net = std.Io.net;

/// Serves exactly `num_requests` requests, echoing back the request as JSON.
/// Handles however many connections the client chooses to open.
fn serve(io: std.Io, server: *net.Server, num_requests: u32) void {
    var served: u32 = 0;
    while (served < num_requests) {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        served += serveConnection(io, conn, num_requests - served);
    }
}

fn serveConnection(io: std.Io, conn: net.Stream, budget: u32) u32 {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);

    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var served: u32 = 0;
    while (served < budget) {
        var request = http_server.receiveHead() catch break;

        var accept: []const u8 = "*/*";
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Accept")) accept = h.value;
        }

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"method\":\"{s}\",\"url\":\"{s}\",\"accept\":\"{s}\"}}",
            .{ @tagName(request.head.method), request.head.target, accept },
        ) catch return served;

        request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return served;

        served += 1;
    }
    return served;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{
        server.socket.address.getPort(),
    });
    defer allocator.free(base_url);

    std.debug.print("Serving on {s}\n\n", .{base_url});

    var future = try io.concurrent(serve, .{ io, &server, 6 });
    defer future.await(io);

    var client = try zio.Client.init(allocator, io, .{ .base_url = base_url });
    defer client.deinit();

    {
        const res = try client.get("/get", .{
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        });
        defer res.deinit(allocator);
        std.debug.print("GET    {} {s}\n", .{ res.status, res.body });
        std.debug.print("       Content-Type: {s}\n", .{res.getHeader("content-type") orelse "n/a"});
    }

    {
        const res = try client.post("/post", "{\"name\":\"test\"}", .{});
        defer res.deinit(allocator);
        std.debug.print("POST   {} {s}\n", .{ res.status, res.body });
    }

    {
        const res = try client.put("/put", "put data", .{});
        defer res.deinit(allocator);
        std.debug.print("PUT    {} {s}\n", .{ res.status, res.body });
    }

    {
        const res = try client.patch("/patch", "patch data", .{});
        defer res.deinit(allocator);
        std.debug.print("PATCH  {} {s}\n", .{ res.status, res.body });
    }

    {
        const res = try client.delete("/delete", .{});
        defer res.deinit(allocator);
        std.debug.print("DELETE {} {s}\n", .{ res.status, res.body });
    }

    {
        const res = try client.head("/head", .{});
        defer res.deinit(allocator);
        std.debug.print("HEAD   {} body length {d} (should be 0)\n", .{ res.status, res.body.len });
    }
}
