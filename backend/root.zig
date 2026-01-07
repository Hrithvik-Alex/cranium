const std = @import("std");

// Export your modules
pub const tokenizer = @import("tokenizer.zig");

// You can add more modules here as your backend grows
// pub const parser = @import("parser.zig");

test {
    // This runs all tests in imported files
    std.testing.refAllDecls(@This());
}
