<div align="center">
  <img width="350" alt="Zio logo" src="logo.svg" />
</div>

<div align="center">

[![Zig](https://img.shields.io/badge/Zig-%3E%3D0.15.2-blue?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/build-passing-brightgreen)](zig%20build%20test)
[![License](https://img.shields.io/badge/license-MIT-brightgreen.svg)](LICENSE)

</div>

<hr>
<br>

**Zio** is a powerful HTTP client for [Zig](https://ziglang.org/), inspired by [Dio](https://pub.dev/packages/dio) (Dart). Supports global settings, interceptors, FormData, request aborting and timeouts, file uploading/downloading, custom adapters, and much more.

**Current Features:**
- `Client` with `base_url` support for relative URLs.
- GET requests using `std.http.Client`.
- `Response` with status and body.
- Proper memory management (`init`/`deinit()`).


## Installation

### As a Library (Module)
1. Add dependency to your `build.zig.zon`:

```zon
.zio = .{
    .url = "https://github.com/your-username/zio/archive/main.tar.gz",
    .hash = "zig fetch --save https://...",  // compute automatically
};
```

2. In `build.zig` import the module:

```zig
/dev/null/build.zig#Lexample
const zio_dep = b.dependency("zio", .{});
exe.root_module.addImport("zio", zio_dep.module("zio"));
```

### Demo CLI
```sh
git clone https://github.com/your/zio.git
cd zio
zig build run  # runs src/main.zig
```

## Quick Start

```zigprj/zio/src/main.zig#L1-27
const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zio.Client.init(allocator, .{
        .base_url = "https://httpbin.org",
    });
    defer client.deinit();

    const response = try client.get("/get?a=1", .{});
    defer response.deinit(allocator);

    std.debug.print("Status: {d}\n", .{ @enumToInt(response.status) });
    std.debug.print("Body: {s}\n", .{ response.body });
}
```

Compilation: `zig build-exe src/main.zig`

## API

Import: `const zio = @import("zio");`

### Client

```zigprj/zio/src/Client.zig#L4-67
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

    var aw: std.http.Writer.AllocatingWriter = .{ .writer = std.io.allocatorWriter(self.allocator), .allocator = self.allocator };
    const result = try self.http_client.fetch(.{
        .location = .{ .url = full_url },
        .response_writer = aw.writer(),
    });

    return .{
        .status = result.status,
        .body = try aw.toOwnedSlice(),
    };
}
```

### Response

```zigprj/zio/src/Response.zig#L3-12
const std = @import("std");

const Response = @This();

status: std.http.Status,
body: []const u8,

pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
    allocator.free(self.body);
}
```

## Contributing

Contributions are welcome! Please:

1. Fork the repo.
2. Create your feature branch (`git checkout -b feature/foo`).
3. Commit changes (`git commit -am 'Add some foo'`).
4. Push to branch (`git push origin feature/foo`).
5. Create Pull Request.

See `plan.md` for planned features.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file (create one with MIT template).
