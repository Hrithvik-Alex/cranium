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

const BlockType = union(enum) {
    Document: void,
    Paragraph: void,
    Heading: u4,
    CodeBlock: void,
    BlockQuote: void,
    OrderedList: u16,
    OrderedListItem: u16,
    UnorderedList: u16,
    UnorderedListItem: u16,
};

fn getFirstWord(block_stack: *std.ArrayList(*Block), line: []const u8) struct { []u8, usize } {
    const words = std.mem.tokenizeAny(u8, line, " ");

    var block_quote_depth = 0;

    var first_word = words.next();

    for (block_stack) |block| {
        if (block.blockType == BlockType.BlockQuote) {
            block_quote_depth += 1;
            first_word = first_word.next();
        }
    }

    return .{ first_word, @intFromPtr(first_word.ptr) - @intFromPtr(line.ptr) };
}

fn isOrderedNumber(word: []const u8) bool {
    const maybeInt = (std.fmt.parseInt(u32, word[0 .. word.len - 1], 10) > 0) catch false;
    return maybeInt and (word[word.len - 1] == '.');
}

const Block = struct {
    blockType: BlockType,
    children: [*]Block,
    content: ?[]const u8,

    fn can_continue(self: *Block, block_stack: *std.ArrayList(*Block), line: []const u8) bool {
        // const words = std.mem.tokenizeAny(u8, line, " ").next();
        //
        // var block_quote_depth = 0;
        //
        // for (block_stack) |block| {
        //     if (block.blockType == BlockType.BlockQuote) {
        //         block_quote_depth += 1;
        //     }
        // }
        //if (line.len == 0 and self.blockType != BlockType.Document) return false;
        const first_word, const first_word_depth = getFirstWord(block_stack, line);
        //if (line.len == 0 and self.blockType != BlockType.Document) return false;
        return switch (self.blockType) {
            BlockType.Document => true,
            BlockType.Paragraph => false,
            BlockType.Heading => false,
            BlockType.CodeBlock => !std.mem.eql(line, "```"),
            BlockType.UnorderedList => |depth| depth <= first_word_depth and (first_word.len == 1) and (first_word[0] == '-'),
            BlockType.OrderedListItem => |depth| depth < first_word_depth, // TODO: fix, needs to account for depth below? maybe this is enough?
            BlockType.OrderedList => |depth| {
                return depth <= first_word_depth and isOrderedNumber(first_word);
            },
            BlockType.UnorderedListItem => |depth| depth < first_word_depth, // TODO: same as OLT fix
        };
    }
};

fn determineBlockType(block_stack: *std.ArrayList(*Block), line: []const u8) BlockType {
    // const words = std.mem.tokenizeAny(u8, line, " ").next();
    //
    // var block_quote_depth = 0;
    //
    // for (block_stack) |block| {
    //     if (block.blockType == BlockType.BlockQuote) {
    //         block_quote_depth += 1;
    //     }
    // }
    //
    // const first_word = words[block_quote_depth];

    const first_word, const first_word_depth = getFirstWord(block_stack, line);

    if (std.mem.eql(first_word, ">")) {
        return BlockType.BlockQuote;
    } else if (std.mem.eql(first_word, "```")) {
        return BlockType.CodeBlock;
    }

    const prev_depth = switch (block_stack[block_stack.items.len - 1].blockType) {
        .OrderedList, .OrderedListItem, .UnorderedList, .UnorderedListItem => |depth| depth,
        else => -1,
    };

    if (std.mem.eql(first_word, "-")) {
        //TODO: figure out depth
        if (first_word_depth > prev_depth) {
            return BlockType{ .UnorderedList = first_word_depth };
        } else if (first_word_depth == prev_depth) {
            return BlockType{ .UnorderedListItem = first_word_depth };
        } else {
            std.debug.panic("first_word_depth < prev_depth", .{});
        }
        // if cur_depth_start
    }

    if (isOrderedNumber(first_word)) {
        if (first_word_depth > prev_depth) {
            return BlockType{ .OrderedList = first_word_depth };
        } else if (first_word_depth == prev_depth) {
            return BlockType{ .OrderedListItem = first_word_depth };
        } else {
            std.debug.panic("first_word_depth < prev_depth", .{});
        }
    }

    var is_header = true;
    for (first_word, 0..) |char, level| {
        if (char != '#' or level == 6) {
            is_header = false;
            break;
        }
    }
    return if (is_header) BlockType.Heading else BlockType.Paragraph;
}

fn parseBlocks(allocator: Allocator, text: []const u8) !std.ArrayList(Block) {
    const lines = std.mem.tokenizeAny(u8, text, "\n");

    const document_block = allocator.create(Block{ .blockType = .Document, .children = .{}, .content = .{} });

    var block_stack = std.ArrayList(*Block).empty;
    block_stack.append(allocator, document_block);

    while (lines.next()) |line| {
        var i = 0;
        for (block_stack) |block| {
            if (!block.can_continue(line)) {
                break;
            }

            i += 1;
        }

        while (i + 1 < block_stack.len) {
            block_stack.pop();
        }

        var current_block = block_stack[i];

        if (block_stack.items.len == 0) {
            var block = Block{ .blockType = BlockType.Paragraph, .children = .{} };
            // TODO: fix block creation logic

            current_block.children.append(allocator, block);
            block_stack.append(allocator, &block);
        }
    }

    return document_block;
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
            i = ni;
        }
    }

    return tokens;
}

// pub fn parse() {
//
// }
