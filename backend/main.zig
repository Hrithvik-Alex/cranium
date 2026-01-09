const std = @import("std");
const backend = @import("backend");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Example usage of your tokenizer
    const text = "Hello *world* with _emphasis_";
    var tokens = try backend.tokenizer.tokenize(allocator, text);
    defer tokens.deinit(allocator);

    std.debug.print("Tokenized {} tokens\n", .{tokens.items.len});
}
