const std = @import("std");

// You can add more modules here as your backend grows
// pub const parser = @import("parser.zig");
pub const md_parser = @import("md_parser.zig");

test {
    // This runs all tests in imported files
    std.testing.refAllDecls(@This());
}
