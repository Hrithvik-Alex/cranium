const std = @import("std");
const Allocator = std.mem.Allocator;

/// A gap buffer data structure for efficient text editing.
/// The buffer contains text with a "gap" at the cursor position.
pub const GapBuffer = struct {
    buffer: []u8,
    gap_start: usize,
    gap_end: usize,
    allocator: Allocator,

    pub fn initFromSlice(allocator: Allocator, content: []const u8) !GapBuffer {
        const initial_gap: usize = 1024;
        const total_len = content.len + initial_gap;
        const buffer = try allocator.alloc(u8, total_len);

        @memcpy(buffer[0..content.len], content);

        return GapBuffer{
            .buffer = buffer,
            .gap_start = content.len,
            .gap_end = total_len,
            .allocator = allocator,
        };
    }

    pub fn gapSize(self: *const GapBuffer) usize {
        return self.gap_end - self.gap_start;
    }

    pub fn len(self: *const GapBuffer) usize {
        return self.buffer.len - self.gapSize();
    }

    pub fn ensureGap(self: *GapBuffer, needed: usize) !void {
        if (self.gapSize() >= needed) return;

        const min_growth = needed - self.gapSize();
        const grow_by = @max(min_growth, self.buffer.len / 2 + 1);
        const new_len = self.buffer.len + grow_by;
        const new_buffer = try self.allocator.alloc(u8, new_len);

        const left_len = self.gap_start;
        const right_len = self.buffer.len - self.gap_end;
        const new_gap_end = new_len - right_len;

        @memcpy(new_buffer[0..left_len], self.buffer[0..left_len]);
        @memcpy(new_buffer[new_gap_end..new_len], self.buffer[self.gap_end..self.buffer.len]);

        self.allocator.free(self.buffer);
        self.buffer = new_buffer;
        self.gap_end = new_gap_end;
    }

    pub fn moveGap(self: *GapBuffer, new_pos: usize) void {
        if (new_pos == self.gap_start) return;
        if (new_pos < self.gap_start) {
            const move_len = self.gap_start - new_pos;
            std.mem.copyBackwards(u8, self.buffer[self.gap_end - move_len .. self.gap_end], self.buffer[new_pos..self.gap_start]);
            self.gap_start = new_pos;
            self.gap_end -= move_len;
        } else {
            const move_len = new_pos - self.gap_start;
            std.mem.copyForwards(u8, self.buffer[self.gap_start..self.gap_start + move_len], self.buffer[self.gap_end..self.gap_end + move_len]);
            self.gap_start += move_len;
            self.gap_end += move_len;
        }
    }

    pub fn insert(self: *GapBuffer, pos: usize, text: []const u8) !void {
        if (pos > self.len()) return error.OutOfBounds;
        self.moveGap(pos);
        try self.ensureGap(text.len);
        @memcpy(self.buffer[self.gap_start .. self.gap_start + text.len], text);
        self.gap_start += text.len;
    }

    pub fn delete(self: *GapBuffer, pos: usize, count: usize) !void {
        if (pos > self.len()) return error.OutOfBounds;
        self.moveGap(pos);
        const delete_len = @min(count, self.buffer.len - self.gap_end);
        self.gap_end += delete_len;
    }

    /// Get the byte at a logical index (excluding the gap).
    pub fn byteAt(self: *const GapBuffer, index: usize) u8 {
        if (index < self.gap_start) return self.buffer[index];
        return self.buffer[index + self.gapSize()];
    }

    /// Copy the logical text into a contiguous buffer owned by allocator.
    pub fn toOwnedSlice(self: *const GapBuffer, allocator: Allocator) ![]u8 {
        const total_len = self.len();
        const out = try allocator.alloc(u8, total_len);

        const left_len = self.gap_start;
        const right_len = self.buffer.len - self.gap_end;

        @memcpy(out[0..left_len], self.buffer[0..left_len]);
        @memcpy(out[left_len..total_len], self.buffer[self.gap_end .. self.gap_end + right_len]);
        return out;
    }

    /// Get the start of the previous UTF-8 codepoint from the given byte index.
    pub fn prevCodepointStart(self: *const GapBuffer, index: usize) usize {
        if (index == 0) return 0;
        var i = index - 1;
        while (i > 0) {
            const byte = self.byteAt(i);
            if ((byte & 0xC0) != 0x80) break;
            i -= 1;
        }
        return i;
    }

    /// Get the end of the next UTF-8 codepoint from the given byte index.
    pub fn nextCodepointEnd(self: *const GapBuffer, index: usize) usize {
        if (index >= self.len()) return self.len();
        const first = self.byteAt(index);
        const cp_len: usize = if (first < 0x80)
            1
        else if ((first & 0xE0) == 0xC0)
            2
        else if ((first & 0xF0) == 0xE0)
            3
        else if ((first & 0xF8) == 0xF0)
            4
        else
            1;
        return @min(index + cp_len, self.len());
    }
};
