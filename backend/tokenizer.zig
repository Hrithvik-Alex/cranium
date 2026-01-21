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
    // block
    Document: void,
    Paragraph: void,
    Heading: u4,
    CodeBlock: void,
    BlockQuote: usize,
    OrderedList: usize,
    OrderedListItem: usize,
    UnorderedList: usize,
    UnorderedListItem: usize,
    // inline
    RawStr: void,
    Strong: void,
    Emphasis: void,
    StrongEmph: void,
    Link: []const u8,
    Image: []const u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{@tagName(self)});
        switch (self) {
            .Heading => |level| try writer.print(" - l{x}", .{level}),
            .OrderedList, .OrderedListItem, .UnorderedList, .UnorderedListItem => |depth| try writer.print(" - depth {x}", .{depth}),
            else => {},
        }
    }
};

fn getFirstWord(block_stack: *std.ArrayList(*Block), line: []const u8) struct { []const u8, usize, usize } {
    var words = std.mem.tokenizeAny(u8, line, " ");

    var block_quote_depth: u16 = 0;
    var depth: usize = 0;

    var first_word = words.next() orelse return .{ "", depth, block_quote_depth };
    depth = @intFromPtr(first_word.ptr) - @intFromPtr(line.ptr);

    for (block_stack.items) |b| {
        switch (b.blockType) {
            .BlockQuote => {
                if (std.mem.eql(u8, first_word, ">")) {
                    block_quote_depth += 1;
                    if (words.peek() != null) {
                        first_word = words.next().?;
                        depth = @intFromPtr(first_word.ptr) - @intFromPtr(line.ptr);
                    } else {
                        first_word = "";
                        break;
                    }
                } else {
                    break;
                }
            },
            else => {},
        }
    }

    return .{ first_word, depth, block_quote_depth };
}

fn isOrderedNumber(word: []const u8) bool {
    const maybeInt = (std.fmt.parseInt(u32, word[0 .. word.len - 1], 10)) catch 0 > 0;
    return maybeInt and (word[word.len - 1] == '.');
}

const Block = struct {
    blockType: BlockType,
    children: std.ArrayList(*Block),
    content: ?[]const u8,
    is_open: bool = true,

    fn can_continue(self: *Block, block_stack: *std.ArrayList(*Block), line: []const u8) bool {
        const first_word, const first_word_depth, const block_quote_depth = getFirstWord(block_stack, line);
        return switch (self.blockType) {
            .Document => true,
            .BlockQuote => |depth| depth <= block_quote_depth,
            .Paragraph => true,
            .Heading => false,
            .CodeBlock => true, // handled in handleBlockType
            .UnorderedList => |depth| depth < first_word_depth or (depth == first_word_depth and std.mem.eql(u8, first_word, "-")),
            .OrderedListItem => |depth| depth < first_word_depth,
            .OrderedList => |depth| {
                return depth <= first_word_depth and isOrderedNumber(first_word);
            },
            BlockType.UnorderedListItem => |depth| depth < first_word_depth,
            .RawStr, .Strong, .Emphasis, .Link, .StrongEmph, .Image => unreachable, // inline
        };
    }
};

fn determineBlockType(block_stack: *std.ArrayList(*Block), line: []const u8) ?BlockType {
    const first_word, const first_word_depth, const block_quote_depth = getFirstWord(block_stack, line);

    if (first_word.len == 0) {
        return null;
    }

    if (std.mem.eql(u8, first_word, ">")) {
        return BlockType{ .BlockQuote = block_quote_depth + 1 };
    } else if (std.mem.eql(u8, first_word, "```")) {
        return BlockType.CodeBlock;
    }

    const prev_depth = switch (block_stack.getLast().blockType) {
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

pub fn addToStack(allocator: Allocator, block_stack: *std.ArrayList(*Block), block_type: BlockType) !*Block {
    var current_block = block_stack.getLast();

    const next_top_block = try allocator.create(Block);
    next_top_block.* = Block{ .blockType = block_type, .children = std.ArrayList(*Block).empty, .content = null };
    try current_block.children.append(allocator, next_top_block);
    try block_stack.append(allocator, next_top_block);
    return next_top_block;
}

pub fn handleBlockType(allocator: Allocator, block_stack: *std.ArrayList(*Block), block_type: BlockType, line: []const u8, text: []const u8) !void {
    const current_top_block = block_stack.getLastOrNull();
    if (block_type != .Paragraph and current_top_block != null and current_top_block.?.blockType == .Paragraph) {
        const b = block_stack.pop() orelse unreachable;
        b.is_open = false;
    }

    switch (block_type) {
        inline .OrderedList, .UnorderedList => |depth, tag| {
            _ = try addToStack(allocator, block_stack, block_type);
            const tag_name = @tagName(tag);
            const item_tag_name = tag_name ++ "Item";

            comptime {
                if (!@hasField(BlockType, item_tag_name)) {
                    @compileError("Missing BlockType variant: " ++ item_tag_name);
                }
            }

            try handleBlockType(allocator, block_stack, @unionInit(BlockType, item_tag_name, depth), line, text);
        },
        .OrderedListItem, .UnorderedListItem => {
            _ = try addToStack(allocator, block_stack, block_type);
            try handleBlockType(allocator, block_stack, .Paragraph, line, text);
        },
        .BlockQuote => {
            _ = try addToStack(allocator, block_stack, block_type);
            const current_block_type = determineBlockType(block_stack, line) orelse return;
            try handleBlockType(allocator, block_stack, current_block_type, line, text);
        },
        .Heading => {
            const next_top_block = try addToStack(allocator, block_stack, block_type);
            next_top_block.content = line;
        },
        .Paragraph => {
            if (current_top_block) |curr_top_block| {
                if (curr_top_block.blockType == .Paragraph and curr_top_block.is_open) {
                    std.debug.assert(curr_top_block.content != null);
                    const old_content = curr_top_block.content orelse unreachable;
                    const start = @intFromPtr(old_content.ptr) - @intFromPtr(text.ptr);
                    const end = @intFromPtr(line.ptr) + line.len - @intFromPtr(text.ptr);
                    curr_top_block.content = text[start..end];
                    return;
                }
            }

            // else
            const next_top_block = try addToStack(allocator, block_stack, block_type);
            next_top_block.content = line;
        },
        .CodeBlock => {
            if (block_stack.items.len >= 1 and block_stack.items[block_stack.items.len - 1].blockType == .CodeBlock) {
                // const b = block_stack.pop() orelse unreachable;
                // b.is_open = false;

                const opening_code_block = block_stack.pop() orelse unreachable;
                opening_code_block.is_open = false;
                // _ = opening_code_block.children.pop();
            } else {
                _ = try addToStack(allocator, block_stack, block_type);
            }
        },
        .Document => {},
        .RawStr, .Strong, .Emphasis, .Link, .StrongEmph, .Image => unreachable, // inline
    }
}

pub fn parseBlocks(allocator: Allocator, text: []const u8) !*Block {
    var lines = std.mem.tokenizeAny(u8, text, "\n");

    const document_block = try allocator.create(Block);
    document_block.* = (Block{ .blockType = .Document, .children = std.ArrayList(*Block).empty, .content = null });

    var block_stack = std.ArrayList(*Block).empty;
    try block_stack.append(allocator, document_block);

    while (lines.next()) |line| {
        var i: usize = 0;

        // reset the stack
        for (block_stack.items) |b| {
            if (!b.can_continue(&block_stack, line)) {
                break;
            }
            i += 1;
        }

        while (i < block_stack.items.len) {
            const b = block_stack.pop() orelse unreachable;
            b.is_open = false;
        }

        const block_type = determineBlockType(&block_stack, line) orelse {
            block_stack.items[block_stack.items.len - 1].is_open = false; //TODO: this line feels a bit sus, can I do this if its not paragraph?
            continue;
        };
        std.debug.print("what that line do: \"{s}\", block_type: {f}\n", .{ line, block_type });
        try handleBlockType(allocator, &block_stack, block_type, line, text);
    }

    while (block_stack.items.len > 0) {
        const b = block_stack.pop() orelse unreachable;
        b.is_open = false;
    }

    return document_block;
}

const InlineDelimiterType = enum {
    SquareBracket,
    ExcSquareBracket,
    Star,
    Underscore,
};

const DelimiterStackItem = struct {
    delimiter_type: InlineDelimiterType,
    num_delimiters: usize,
    start_index: usize,
    is_active: bool,
    is_opener: bool,
    is_closer: bool,
};

fn processEmphasis(allocator: Allocator, delimiter_stack: *std.DoublyLinkedList(*DelimiterStackItem), paragraph: *Block, stack_bottom: ?usize) !*Block {
    var current_position = (stack_bottom orelse -1) + 1;

    var star_openers_bottom = stack_bottom;
    var underscore_openers_bottom = stack_bottom;

    var it = delimiter_stack.first;
    var i = 0;
    while (it) |node| : (i += 1) {
        const item = node.data;
        if (i < current_position or item.delimiter_type == .SquareBracket or item.delimiter_type == .ExcSquareBracket or !item.is_closer) continue;

        var cur_node = node.prev;
        const floor_node = if (item.delimiter_type == .Star) &star_openers_bottom else &underscore_openers_bottom;

        while (cur_node != floor_node) : (cur_node = cur_node.prev) {
            if (cur_node.delimiter_type == node.delimiter_type) {
                const block_type = if (cur_node.num_delimiters >= 2 and cur_node.num_delimiters >= 2) {
                    BlockType.StrongEmph;
                } else {
                    BlockType.Emph;
                };

                const section_text = paragraph.content[(cur_node.start_index + cur_node.num_delimiters)..(node.start_index - 1)];
                const str_block = try allocator.create(Block);
                // TODO: handle inlino
                str_block.* = Block{ .blockType = .block_type, .content = section_text, .children = std.ArrayList(Block).empty, .is_open = false };
                try paragraph.children.append(allocator, str_block);

                cur_node.num_delimiters -= if (block_type == .StrongEmph) 2 else 1;
                if (cur_node.num_delimiters == 0) delimiter_stack.remove(cur_node);
                node.num_delimiters -= if (block_type == .StrongEmph) 2 else 1;
                if (node.num_delimiters == 0) {
                    delimiter_stack.remove(node);
                    current_position = node.position;
                }
                break;
            }
        }

        if (cur_node != floor_node) {
            floor_node = cur_node.prev;
        } else {
            if (!cur_node.is_opener) {
                delimiter_stack.remove(cur_node);
            }
            current_position = node.next.position;
        }

        it = node.next;
    }
}

fn lookForLinkOrImage(allocator: Allocator, delimiter_stack: *std.DoublyLinkedList(*DelimiterStackItem), paragraph: *Block, content_position: usize) !*Block {
    const it_reverse = delimiter_stack.last;

    var still_processing = true;
    while (it_reverse) |node| {
        const item = node.data;
        if (!still_processing and (item.delimiter_type == .SquareBracket or item.delimiter_type == .ExcSquareBracket)) {
            item.is_active = false;
        }

        if (item.delimiter_type == .SquareBracket or item.delimiter_type == .ExcSquareBracket) {
            if (!item.is_active) {
                delimiter_stack.remove(item);
            } else {
                const section_text = paragraph.content[(item.start_index + 1)..(content_position - 1)];
                const str_block = try allocator.create(Block);
                // TODO: handle inlino
                str_block.* = Block{ .blockType = .RawStr, .content = section_text, .children = std.ArrayList(Block).empty, .is_open = false };
                try paragraph.children.append(allocator, str_block);

                delimiter_stack.remove(item);
                still_processing = false;
            }
        }

        it_reverse = node.prev;
    }
}

inline fn isAsciiPunctuation(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}
fn parseInline(allocator: Allocator, current_block: *Block) !void {
    if (current_block.blockType == .Paragraph) {
        //TODO: where all the complexity happens
        var stack = std.DoublyLinkedList(DelimiterStackItem).empty;
        const content = current_block.content orelse unreachable;
        const len = content.len;
        var i = 0;
        while (i < len) {
            switch (content[i]) {
                '[' => {
                    try stack.append(allocator, DelimiterStackItem{ .delimiter_type = .SquareBracket, .num_delimiters = 1, .start_index = i, .is_opener = true, .is_closer = false });
                },
                '!' => {
                    if (i + 1 < len and content[i + 1] == '[') {
                        try stack.append(allocator, DelimiterStackItem{ .delimiter_type = .ExcSquareBracket, .num_delimiters = 1, .start_index = i, .is_opener = true, .is_closer = false });
                    }
                },
                '_' => {
                    const orig_i = i;
                    var num_delimiters = 1;
                    while (i + 1 < len and content[i] == '_') {
                        num_delimiters += 1;
                        i += 1;
                    }

                    const precedes_punct = orig_i - 1 >= 0 and isAsciiPunctuation(content[orig_i - 1]);
                    const follows_punct = i + 1 < len and isAsciiPunctuation(content[i + 1]);
                    // left flanking - https://spec.commonmark.org/0.27/#left-flanking-delimiter-run
                    const is_left_flanking = (i + 1 < len and !std.ascii.isWhitespace(content[i + 1]) and (!isAsciiPunctuation(content[i + 1]) or precedes_punct or (orig_i - 1 >= 0 and std.ascii.isWhitespace(content[orig_i - 1]))));
                    // right flanking - https://spec.commonmark.org/0.27/#right-flanking-delimiter-run
                    const is_right_flanking = (orig_i - 1 >= 0 and !std.ascii.isWhitespace(content[orig_i - 1]) and (!isAsciiPunctuation(content[orig_i - 1]) or follows_punct or (i + 1 < len and std.ascii.isWhitespace(content[i + 1]))));

                    const is_opener = is_left_flanking and (!is_right_flanking or precedes_punct);
                    const is_closer = is_right_flanking and (!is_left_flanking or follows_punct);

                    if (is_opener or is_closer) {
                        try stack.append(allocator, DelimiterStackItem{ .delimiter_type = .Underscore, .num_delimiters = num_delimiters, .start_index = orig_i, .is_opener = is_opener, .is_closer = is_closer });
                    }
                },
                '*' => {
                    const orig_i = i;
                    var num_delimiters = 1;
                    while (i + 1 < len and content[i] == '*') {
                        num_delimiters += 1;
                        i += 1;
                    }

                    // left flanking - https://spec.commonmark.org/0.27/#left-flanking-delimiter-run
                    const is_opener = (i + 1 < len and !std.ascii.isWhitespace(content[i + 1]) and (!isAsciiPunctuation(content[i + 1]) or (orig_i - 1 >= 0 and (std.ascii.isWhitespace(content[orig_i - 1]) or isAsciiPunctuation(content[orig_i - 1])))));
                    // right flanking - https://spec.commonmark.org/0.27/#right-flanking-delimiter-run
                    const is_closer = (orig_i - 1 >= 0 and !std.ascii.isWhitespace(content[orig_i - 1]) and (!isAsciiPunctuation(content[orig_i - 1]) or (i + 1 < len and (std.ascii.isWhitespace(content[i + 1]) or isAsciiPunctuation(content[i + 1])))));

                    try stack.append(allocator, DelimiterStackItem{ .delimiter_type = .Star, .num_delimiters = num_delimiters, .start_index = orig_i, .is_opener = is_opener, .is_closer = is_closer });
                },
                ']' => {
                    try lookForLinkOrImage(&stack, content, i);
                },
                else => i += 1,
            }
        }
    } else {
        for (current_block.children.items) |child_block| {
            try parseInline(allocator, child_block);
        }
    }
}

fn printBlock(b: *Block, depth: usize) void {
    for (0..depth) |_| {
        std.debug.print("  ", .{});
    }
    std.debug.print("type: {f}, ", .{b.blockType});
    if (b.content != null) {
        std.debug.print("content: \"{s}\", ", .{b.content.?});
    }
    if (b.is_open) {
        std.debug.print("***OPEN***, ", .{});
    }
    if (b.children.items.len > 0) {
        std.debug.print("children: [\n", .{});
        for (b.children.items) |child| {
            printBlock(child, depth + 1);
        }
        for (0..depth) |_| {
            std.debug.print("  ", .{});
        }
        std.debug.print("],", .{});
    }
    std.debug.print("\n", .{});
}

fn block(
    a: std.mem.Allocator,
    bt: BlockType,
    children: []const *Block,
    content: ?[]const u8,
) !*Block {
    const b = try a.create(Block);
    b.* = .{ .blockType = bt, .children = std.ArrayList(*Block).empty, .content = content, .is_open = false };
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
        try block(allocator, .Paragraph, &.{}, "This is a sample paragraph. It is actually going to be\nsplit across two different lines."),
        try block(allocator, .{ .UnorderedList = 1 }, &.{
            try block(allocator, .{ .UnorderedListItem = 1 }, &.{
                try block(allocator, .Paragraph, &.{}, " - this is the first element in a list. It shall also be\n   split across two lines."),
            }, null),
            try block(allocator, .{ .UnorderedListItem = 1 }, &.{
                try block(allocator, .Paragraph, &.{}, " - this is the second element."),
                try block(allocator, .{ .UnorderedList = 3 }, &.{
                    try block(allocator, .{ .UnorderedListItem = 3 }, &.{
                        try block(allocator, .Paragraph, &.{}, "   - this is a nested list"),
                    }, null),
                    try block(allocator, .{ .UnorderedListItem = 3 }, &.{
                        try block(allocator, .Paragraph, &.{}, "   - anything else here?"),
                    }, null),
                }, null),
            }, null),
        }, null),
        try block(allocator, .{ .BlockQuote = 1 }, &.{ try block(allocator, .Paragraph, &.{}, "> block quote time."), try block(allocator, .CodeBlock, &.{
            try block(allocator, .Paragraph, &.{}, "> fn this_is_code {\n> }"),
        }, null), try block(allocator, .{ .OrderedList = 2 }, &.{ try block(allocator, .{ .OrderedListItem = 2 }, &.{try block(allocator, .Paragraph, &.{}, "> 1. there are ordered lists too.")}, null), try block(allocator, .{ .OrderedListItem = 2 }, &.{try block(allocator, .Paragraph, &.{}, "> 2. is this surprising?")}, null) }, null) }, null),
        try block(allocator, .Paragraph, &.{}, "okay we done block quoting now. bye!"),
    }, null);

    const markdown_blocks = try parseBlocks(allocator, markdown_text);

    printBlock(markdown_blocks, 0);

    try std.testing.expectEqualDeep(markdown_blocks_expected, markdown_blocks);
}
