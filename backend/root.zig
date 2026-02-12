const std = @import("std");
test {
    // This runs all tests in imported files
    std.testing.refAllDecls(@This());
}
