//! A pool of idle keep-alive connections, keyed by origin and proxy.
//!
//! Connections are only ever returned here after an exchange that left the stream at a
//! clean message boundary; see `Connection.closing`. Eviction is oldest-first once
//! `max_idle` is reached.

const std = @import("std");
const Connection = @import("Connection.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Pool = @This();

gpa: Allocator,
idle: std.ArrayList(*Connection),
max_idle: usize,
mutex: Io.Mutex,

pub fn init(gpa: Allocator, max_idle: usize) Pool {
    return .{
        .gpa = gpa,
        .idle = .empty,
        .max_idle = max_idle,
        .mutex = .init,
    };
}

pub fn deinit(self: *Pool) void {
    for (self.idle.items) |conn| conn.deinit();
    self.idle.deinit(self.gpa);
    self.* = undefined;
}

/// Takes an idle connection matching `key`, or null when there is none. The caller owns
/// the connection until it calls `release`.
pub fn acquire(self: *Pool, io: Io, key: Connection.Key) ?*Connection {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // Newest first: the most recently used connection is the least likely to have been
    // closed by the peer in the meantime.
    var i = self.idle.items.len;
    while (i > 0) {
        i -= 1;
        const conn = self.idle.items[i];
        if (conn.matches(key)) {
            _ = self.idle.swapRemove(i);
            return conn;
        }
    }
    return null;
}

/// Returns a connection to the pool, or closes it when it cannot be reused.
pub fn release(self: *Pool, io: Io, conn: *Connection) void {
    if (conn.closing or self.max_idle == 0) {
        conn.deinit();
        return;
    }

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.idle.items.len >= self.max_idle) {
        const evicted = self.idle.orderedRemove(0);
        evicted.deinit();
    }
    self.idle.append(self.gpa, conn) catch {
        // Out of memory is no reason to leak a socket.
        conn.deinit();
    };
}

/// Closes every idle connection, keeping the pool usable.
pub fn clear(self: *Pool, io: Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    for (self.idle.items) |conn| conn.deinit();
    self.idle.clearRetainingCapacity();
}

pub fn idleCount(self: *Pool, io: Io) usize {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.idle.items.len;
}
