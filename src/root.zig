pub const Client = @import("client.zig");
pub const Response = @import("response.zig");
pub const proxy = @import("proxy.zig");
pub const Connection = @import("transport/Connection.zig");
pub const Exchange = @import("transport/Exchange.zig");

// Pulls every module's `test` blocks into `zig build test`. Without this, lazy
// analysis skips files that nothing in the root file references.
test {
    _ = Client;
    _ = Response;
    _ = proxy;
    _ = Connection;
    _ = Exchange;
}
