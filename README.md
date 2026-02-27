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

**Zio** is a minimal HTTP client library for [Zig](https://ziglang.org/), inspired by [Dio](https://pub.dev/packages/dio) (Dart). Built on top of `std.http.Client` with zero external dependencies.

**Features:**
- `Client` with `base_url` support for relative URL resolution.
- Full HTTP method support: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`.
- `Response` with `status` and `body`.
- Proper memory management (`init` / `deinit(allocator)`).


## Installation

1. Run `zig fetch` to add the dependency:

```sh
zig fetch --save https://github.com/etroynov/zio/archive/refs/tags/0.1.0.tar.gz
```

This will automatically add the entry to your `build.zig.zon`:

```zon
.dependencies = .{
    .zio = .{
        .url = "https://github.com/etroynov/zio/archive/refs/tags/0.1.0.tar.gz",
        .hash = "<computed by zig fetch>",
    },
},
```

2. In `build.zig` import the module:

```zig
const zio_dep = b.dependency("zio", .{});
exe.root_module.addImport("zio", zio_dep.module("zio"));
```


## Quick Start

```zig
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

    const response = try client.get("/get?a=1", .{});
    defer response.deinit(allocator);

    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

Run with: `zig build run`

## API

```zig
const zio = @import("zio");
```

### Client

```zig
// Init
var client = zio.Client.init(allocator, .{ .base_url = "https://api.example.com" });
defer client.deinit();

// Methods
const res = try client.get("/path", .{});
const res = try client.post("/path", "body");
const res = try client.put("/path", "body");
const res = try client.patch("/path", "body");
const res = try client.delete("/path");
const res = try client.head("/path");
defer res.deinit(allocator);
```

`base_url` is optional. If `path` starts with `http://` or `https://`, it is used as-is.

### Response

```zig
res.status  // std.http.Status
res.body    // []const u8
res.deinit(allocator)
```

## Contributing

Contributions are welcome! Please:

1. Fork the repo.
2. Create your feature branch (`git checkout -b feature/foo`).
3. Commit changes (`git commit -am 'Add some foo'`).
4. Push to branch (`git push origin feature/foo`).
5. Create Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file.
