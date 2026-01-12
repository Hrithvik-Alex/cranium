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
    OrderedList: usize,
    OrderedListItem: usize,
    UnorderedList: usize,
    UnorderedListItem: usize,
};

fn getFirstWord(block_stack: *std.ArrayList(*Block), line: []const u8) struct { []const u8, usize } {
    var words = std.mem.tokenizeAny(u8, line, " ");

    var block_quote_depth: u16 = 0;

    var first_word = words.next().?;

    for (block_stack.items) |b| {
        if (b.blockType == BlockType.BlockQuote) {
            block_quote_depth += 1;
            first_word = words.next().?;
        }
    }

    return .{ first_word, @intFromPtr(first_word.ptr) - @intFromPtr(line.ptr) };
}

fn isOrderedNumber(word: []const u8) bool {
    const maybeInt = (std.fmt.parseInt(u32, word[0 .. word.len - 1], 10)) catch 0 > 0;
    return maybeInt and (word[word.len - 1] == '.');
}

const Block = struct {
    blockType: BlockType,
    children: std.ArrayList(*Block),
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
            .Document => true,
            .BlockQuote => std.mem.eql(u8, first_word, ">"),
            .Paragraph => false,
            .Heading => false,
            .CodeBlock => !std.mem.eql(u8, line, "```"),
            .UnorderedList => |depth| depth <= first_word_depth and (first_word.len == 1) and (first_word[0] == '-'),
            .OrderedListItem => |depth| depth < first_word_depth, // TODO: fix, needs to account for depth below? maybe this is enough?
            .OrderedList => |depth| {
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

    if (std.mem.eql(u8, first_word, ">")) {
        return BlockType.BlockQuote;
    } else if (std.mem.eql(u8, first_word, "```")) {
        return BlockType.CodeBlock;
    }

    const prev_depth = switch (block_stack.items[block_stack.items.len - 1].blockType) {
        .OrderedList, .OrderedListItem, .UnorderedList, .UnorderedListItem => |depth| depth,
        else => 0,
    };

    if (std.mem.eql(u8, first_word, "-")) {
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
    return if (is_header) BlockType{ .Heading = @intCast(first_word.len) } else BlockType.Paragraph;
}

pub fn parseBlocks(allocator: Allocator, text: []const u8) !*Block {
    var lines = std.mem.tokenizeAny(u8, text, "\n");

    const document_block = try allocator.create(Block);
    document_block.* = (Block{ .blockType = .Document, .children = std.ArrayList(*Block).empty, .content = "" });

    var block_stack = std.ArrayList(*Block).empty;
    try block_stack.append(allocator, document_block);

    while (lines.next()) |line| {
        var i: usize = 0;

        std.debug.print("what that line do: {s}\n", .{line});
        // reset the stack
        for (block_stack.items) |b| {
            i += 1;

            if (!b.can_continue(&block_stack, line)) {
                break;
            }
        }

        while (i < block_stack.items.len) {
            _ = block_stack.pop();
        }

        var current_block = block_stack.items[i - 1];

        const block_type = determineBlockType(&block_stack, line);

        const next_top_block = try allocator.create(Block);
        next_top_block.* = Block{ .blockType = block_type, .children = std.ArrayList(*Block).empty, .content = "" };
        try current_block.children.append(allocator, next_top_block);
        try block_stack.append(allocator, next_top_block);

        switch (block_type) {
            inline .OrderedList, .UnorderedList => |depth, tag| {
                const tag_name = @tagName(tag);
                const item_tag_name = tag_name ++ "Item";

                comptime {
                    if (!@hasField(BlockType, item_tag_name)) {
                        @compileError("Missing BlockType variant: " ++ item_tag_name);
                    }
                }

                const li = try allocator.create(Block);
                li.* = Block{ .blockType = @unionInit(BlockType, item_tag_name, depth), .children = std.ArrayList(*Block).empty, .content = "" };
                const para = try allocator.create(Block);
                para.* = Block{ .blockType = .Paragraph, .children = std.ArrayList(*Block).empty, .content = "" };

                try next_top_block.children.append(allocator, li);
                try li.children.append(allocator, para);

                try block_stack.append(allocator, li);
                try block_stack.append(allocator, para);

                para.content = line;
            },
            .Heading => next_top_block.content = line,
            .Paragraph => next_top_block.content = line,
            else => {}, // CodeBlock, BlockQuote, Document, OrderedListItem, UnorderedListItem
        }
    }

    return document_block;
}
//
// pub fn tokenize(allocator: Allocator, text: []const u8) !std.ArrayList(RawToken) {
//     var tokens = std.ArrayList(RawToken).empty;
//
//     const n = text.len;
//     var i: usize = 0;
//
//     while (i < n) {
//         if (text[i] == '*') {
//             try tokens.append(allocator, RawToken.star);
//             i += 1;
//         } else if (text[i] == '_') {
//             try tokens.append(allocator, RawToken.underscore);
//             i += 1;
//         } else if (text[i] == '\n') {
//             try tokens.append(allocator, RawToken.newline);
//             i += 1;
//         } else {
//             var ni = i + 1;
//
//             while (ni < n) {
//                 switch (text[ni]) {
//                     '*', '_', '\n' => break,
//                     else => ni += 1,
//                 }
//             }
//
//             try tokens.append(allocator, RawToken{ .text = text[i..ni] });
//             i = ni;
//         }
//     }
//
//     return tokens;
// }

// pub fn parse() {
//
// }
//
//
//

fn block(
    a: std.mem.Allocator,
    bt: BlockType,
    children: []const *Block,
    content: []const u8,
) !*Block {
    const b = try a.create(Block);
    b.* = .{
        .blockType = bt,
        .children = std.ArrayList(*Block).empty,
        .content = content,
    };
    try b.children.appendSlice(a, children);
    return b;
}

test "block parser" {
    const markdown_text =
        \\## sample heading
        \\
        \\This is a sample paragraph. It is actually going to be
        \\split across two different lines.
        \\
        \\ - this is the first element in a list. It shall also be
        \\   split across two lines.
        \\ - this is the second element.
        \\   - this is a nested list 
        \\   - anything else here? 
        \\> block quote time. 
        \\> ```
        \\> fn this_is_code {
        \\> }
        \\> ```
        \\> 
        \\> 1. there are ordered lists too. 
        \\> 2. is this surprising?
        \\ 
        \\okay we done block quoting now. bye!
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const markdown_blocks_expected = block(allocator, .Document, &.{
        try block(allocator, .{ .Heading = 2 }, &.{}, "## sample heading"),
        try block(allocator, .Paragraph, &.{}, "This is a sample paragraph. It is actually going to be"),
        try block(allocator, .Paragraph, &.{}, "split across two different lines."),
        try block(allocator, .{ .UnorderedList = 2 }, &.{
            try block(allocator, .{ .UnorderedListItem = 2 }, &.{
                try block(allocator, .Paragraph, &.{}, " - this is the first element in a list. It shall also be"),
                try block(allocator, .Paragraph, &.{}, "   split across two lines."),
            }, ""),
            try block(allocator, .{ .UnorderedListItem = 2 }, &.{
                try block(allocator, .Paragraph, &.{}, " - this is the second element."),
                try block(allocator, .{ .UnorderedList = 4 }, &.{
                    try block(allocator, .{ .UnorderedListItem = 4 }, &.{
                        try block(allocator, .Paragraph, &.{}, "   - this is a nested list "),
                    }, ""),
                    try block(allocator, .{ .UnorderedListItem = 4 }, &.{
                        try block(allocator, .Paragraph, &.{}, "   - anything else here? "),
                    }, ""),
                }, ""),
            }, ""),
        }, ""),
        try block(allocator, .BlockQuote, &.{ try block(allocator, .Paragraph, &.{}, "> block quote time."), try block(allocator, .CodeBlock, &.{
            try block(allocator, .Paragraph, &.{}, "> fn this_is_code {"),
            try block(allocator, .Paragraph, &.{}, "> }"),
        }, ""), try block(allocator, .{ .OrderedList = 2 }, &.{ try block(allocator, .{ .OrderedListItem = 2 }, &.{try block(allocator, .Paragraph, &.{}, "> 1. there are ordered lists too.")}, ""), try block(allocator, .{ .OrderedListItem = 2 }, &.{try block(allocator, .Paragraph, &.{}, "> 2. is this surprising?")}, "") }, "") }, ""),
        try block(allocator, .Paragraph, &.{}, "okay we done block quoting now. bye!"),
    }, "");

    const markdown_blocks = try parseBlocks(allocator, markdown_text);

    try std.testing.expectEqualDeep(markdown_blocks_expected, markdown_blocks);
}
