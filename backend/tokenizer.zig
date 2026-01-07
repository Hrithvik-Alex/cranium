const std = @import("std");
const Allocator = std.mem.Allocator;

const RawToken = union(enum) {
    star: void,
    underscore: void,
    newline: void,
    text: []u8,
};

// fn parse() {
//     std
// }

pub fn tokenize(allocator: Allocator, text: []const u8) !std.ArrayList(RawToken) {
    var tokens = std.ArrayList(i32).init(allocator);

    const n = text.len;
    var i = 0;

    while (i < n) {
        if (text[i] == '*') {
            tokens.append(allocator, RawToken.star);
            i += 1;
        } else if (text[i] == '_') {
            tokens.append(allocator, RawToken.underscore);
            i += 1;
        } else if (text[i] == '\n') {
            tokens.append(allocator, RawToken.newline);
            i += 1;
        } else {
            var ni = i + 1;

            while (ni < n) {
                switch (text[ni]) {
                    '*', '_', '\n' => break,
                    _ => ni += 1,
                }
            }

            tokens.append(allocator, RawToken.text);
        }
    }
}
