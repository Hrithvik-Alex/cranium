const std = @import("std");
const Allocator = std.mem.Allocator;

const RawToken = union(enum) {
    star: void,
    underscore: void,
    newline: void,
    text: []const u8,
};

// fn parse() {
//     std
// }
//
//

const BlockType = enum {
    Document,
    Paragraph,
    Heading,
    CodeBlock,
    OrderedList,
    OrderedListItem,
    UnorderedList,
    UnorderedListItem,
};

const Block = struct {
    blockType: BlockType,
    children: [*]Block,
    content: ?[]const u8,

    fn can_continue(self: *Block, line: []const u8) bool {
        const words = std.mem.tokenizeAny(u8, line, " ").next();

        if (line.len == 0 and self.blockType != BlockType.Document) return false;

        return switch (self.blockType) {
            BlockType.Document => true,
            BlockType.Paragraph => true,
            BlockType.Heading => true,
            BlockType.CodeBlock => !std.mem.eql(line, "```"),
            BlockType.UnorderedList => (words[0].len == 1) and (words[0][0] == '-'),
            BlockType.OrderedList => true, //TODO: check alphanumeric + '.'
        };
    }
};

fn parseBlocks(allocator: Allocator, text: []const u8) !std.ArrayList(Block) {
    const lines = std.mem.tokenizeAny(u8, text, "\n");

    var document_block = allocator.create(Block{ .blockType = .Document, .children = .{}, .content = .{} });

    var block_stack = std.ArrayList(*Block).empty;
    block_stack.append(allocator, document_block);

    while (lines.next()) |line| {
        if (block_stack.items.len == 0) {
            var block = Block{ .blockType = BlockType.Paragraph, .children = .{} };

            high_level_blocks.append(allocator, block);
            block_stack.append(allocator, &block);
        }
    }

    return blocks;
}

pub fn tokenize(allocator: Allocator, text: []const u8) !std.ArrayList(RawToken) {
    var tokens = std.ArrayList(RawToken).empty;

    const n = text.len;
    var i: usize = 0;

    while (i < n) {
        if (text[i] == '*') {
            try tokens.append(allocator, RawToken.star);
            i += 1;
        } else if (text[i] == '_') {
            try tokens.append(allocator, RawToken.underscore);
            i += 1;
        } else if (text[i] == '\n') {
            try tokens.append(allocator, RawToken.newline);
            i += 1;
        } else {
            var ni = i + 1;

            while (ni < n) {
                switch (text[ni]) {
                    '*', '_', '\n' => break,
                    else => ni += 1,
                }
            }

            try tokens.append(allocator, RawToken{ .text = text[i..ni] });
        }
    }

    return tokens;
}

// pub fn parse() {
//
// }
