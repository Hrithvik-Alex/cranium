// super dumb editor cause i cba
const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

// TODO: create a slice that is only upto size for consumers
buffer: []u8,
size: usize,
capacity: usize,

const INITIAL_CAPACITY = 1024;

pub fn create(allocator: Allocator, text: []const u8) !Self {
    var capacity: usize = INITIAL_CAPACITY;
    while (capacity < text.len) : (capacity *= 2) {}
    const buffer = try allocator.alloc(u8, capacity);
    @memcpy(buffer[0..text.len], text);
    return Self{
        .buffer = buffer,
        .size = text.len,
        .capacity = INITIAL_CAPACITY,
    };
}

fn maybe_resize(self: *Self, allocator: Allocator, new_size: usize) !void {
    if (new_size <= self.capacity) return;
    self.capacity = @max(self.capacity * 2, new_size);

    const new_buffer = try allocator.alloc(u8, self.capacity);
    @memcpy(new_buffer[0..self.size], self.buffer);

    allocator.free(self.buffer);
    self.buffer = new_buffer;
}

pub fn insert(self: *Self, allocator: Allocator, i: usize, text: []const u8) !void {
    try self.maybe_resize(allocator, text.len + self.size);

    @memmove(self.buffer[i + text.len .. self.size + text.len], self.buffer[i..self.size]);
    @memcpy(self.buffer[i .. i + text.len], text);
    self.size += text.len;
}

// [start, end)
pub fn delete_range(self: *Self, start: usize, end: usize) !void {
    const move_size = self.size - end;
    @memmove(self.buffer[start .. start + move_size], self.buffer[end .. end + move_size]);
    self.size -= (end - start);
}
