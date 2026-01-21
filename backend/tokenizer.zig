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
    node: std.DoublyLinkedList.Node = .{},

    fn fromNode(n: *std.DoublyLinkedList.Node) *DelimiterStackItem {
        return @fieldParentPtr("node", n);
    }
};

/// Represents a parsed inline segment with its position in the source
const InlineSegment = struct {
    block: *Block,
    start_pos: usize, 
    end_pos: usize, 
};

/// Process emphasis according to CommonMark spec Appendix A
/// Returns a list of inline segments that were created
fn processEmphasis(allocator: Allocator, delimiter_stack: *std.DoublyLinkedList, stack_bottom: ?*std.DoublyLinkedList.Node, segments: *std.ArrayList(InlineSegment)) !void {
    // Track the bottom of opener stacks for each delimiter type and length combination
    var star_openers_bottom: [2]?*std.DoublyLinkedList.Node = .{ stack_bottom, stack_bottom };
    var underscore_openers_bottom: [2]?*std.DoublyLinkedList.Node = .{ stack_bottom, stack_bottom };

    // Start from the first node after stack_bottom, or from the beginning
    var current_node: ?*std.DoublyLinkedList.Node = if (stack_bottom) |sb| sb.next else delimiter_stack.first;

    while (current_node) |closer_node| {
        const closer = DelimiterStackItem.fromNode(closer_node);

        // Skip non-emphasis delimiters and non-closers
        if (closer.delimiter_type == .SquareBracket or closer.delimiter_type == .ExcSquareBracket or !closer.is_closer) {
            current_node = closer_node.next;
            continue;
        }

        // Find a matching opener
        const openers_bottom = if (closer.delimiter_type == .Star)
            &star_openers_bottom
        else
            &underscore_openers_bottom;

        const odd_even_index: usize = if ((closer.is_opener and closer.is_closer) and (closer.num_delimiters % 3 != 0)) 1 else 0;
        var opener_found = false;

        // Search backwards for a matching opener
        var search_node: ?*std.DoublyLinkedList.Node = closer_node.prev;
        while (search_node) |opener_node| {
            // Stop at the bottom
            if (stack_bottom) |sb| {
                if (opener_node == sb) break;
            }
            // Check openers_bottom
            if (openers_bottom[odd_even_index]) |bottom| {
                if (opener_node == bottom) break;
            }

            const opener = DelimiterStackItem.fromNode(opener_node);

            // Check if this is a valid opener of the same type
            if (opener.delimiter_type == closer.delimiter_type and opener.is_opener) {
                // Check "multiple of 3" rule for mixed opener-closer
                if ((opener.is_opener and opener.is_closer) or (closer.is_opener and closer.is_closer)) {
                    if ((opener.num_delimiters + closer.num_delimiters) % 3 == 0) {
                        if (opener.num_delimiters % 3 != 0 or closer.num_delimiters % 3 != 0) {
                            search_node = opener_node.prev;
                            continue;
                        }
                    }
                }

                opener_found = true;

                // Determine strong vs regular emphasis
                const use_strong = opener.num_delimiters >= 2 and closer.num_delimiters >= 2;
                const delim_count: usize = if (use_strong) 2 else 1;
                const block_type: BlockType = if (use_strong) .Strong else .Emphasis;

                // Calculate positions - the content is between the delimiters we're consuming
                const content_start = opener.start_index + opener.num_delimiters;
                const content_end = closer.start_index;

                // The full span includes the delimiters we're consuming
                const span_start = opener.start_index + opener.num_delimiters - delim_count;
                const span_end = closer.start_index + delim_count;

                const emph_block = try allocator.create(Block);
                emph_block.* = Block{
                    .blockType = block_type,
                    .content = null, // Will be filled later with nested content
                    .children = std.ArrayList(*Block).empty,
                    .is_open = false,
                };

                try segments.append(allocator, InlineSegment{
                    .block = emph_block,
                    .start_pos = span_start,
                    .end_pos = span_end,
                });

                // Store content range in the block temporarily
                emph_block.content = @as([*]const u8, @ptrFromInt(content_start))[0..content_end];

                // Remove nodes between opener and closer
                var remove_node = opener_node.next;
                while (remove_node) |rn| {
                    if (rn == closer_node) break;
                    const next = rn.next;
                    delimiter_stack.remove(rn);
                    remove_node = next;
                }

                // Update or remove opener
                const opener_mut = DelimiterStackItem.fromNode(opener_node);
                opener_mut.num_delimiters -= delim_count;
                if (opener_mut.num_delimiters == 0) {
                    delimiter_stack.remove(opener_node);
                }

                // Update or remove closer
                closer.num_delimiters -= delim_count;
                if (closer.num_delimiters == 0) {
                    current_node = closer_node.next;
                    delimiter_stack.remove(closer_node);
                } else {
                    // Stay on closer to process remaining delimiters
                }
                break;
            }

            search_node = opener_node.prev;
        }

        if (!opener_found) {
            // No opener found, update openers_bottom
            openers_bottom[odd_even_index] = closer_node.prev;

            // If not an opener, remove it
            if (!closer.is_opener) {
                const next = closer_node.next;
                delimiter_stack.remove(closer_node);
                current_node = next;
            } else {
                current_node = closer_node.next;
            }
        }
    }

    // Remove remaining delimiters above stack_bottom
    var remove_it: ?*std.DoublyLinkedList.Node = if (stack_bottom) |sb| sb.next else delimiter_stack.first;
    while (remove_it) |node| {
        const next = node.next;
        delimiter_stack.remove(node);
        remove_it = next;
    }
}

/// Look for a link or image when we encounter a closing bracket ']'
/// Returns the end position of the link/image (after the closing paren) if found, null otherwise
fn lookForLinkOrImage(
    allocator: Allocator,
    delimiter_stack: *std.DoublyLinkedList,
    content: []const u8,
    close_bracket_pos: usize,
    segments: *std.ArrayList(InlineSegment),
) !?usize {
    // Search backwards for an opener [ or ![
    var search_node: ?*std.DoublyLinkedList.Node = delimiter_stack.last;

    while (search_node) |node| {
        const item = DelimiterStackItem.fromNode(node);

        if (item.delimiter_type == .SquareBracket or item.delimiter_type == .ExcSquareBracket) {
            if (!item.is_active) {
                // Inactive opener, remove it and continue
                const prev = node.prev;
                delimiter_stack.remove(node);
                search_node = prev;
                continue;
            }

            // Found an active opener - check what follows the ]
            const after_close = close_bracket_pos + 1;
            if (after_close < content.len and content[after_close] == '(') {
                // Inline link: [text](url)
                // Find the closing )
                var paren_depth: usize = 1;
                var url_end: ?usize = null;
                var i = after_close + 1;
                while (i < content.len) : (i += 1) {
                    if (content[i] == '(') {
                        paren_depth += 1;
                    } else if (content[i] == ')') {
                        paren_depth -= 1;
                        if (paren_depth == 0) {
                            url_end = i;
                            break;
                        }
                    }
                }

                if (url_end) |end| {
                    // Extract the link text and URL
                    const opener_pos = if (item.delimiter_type == .ExcSquareBracket)
                        item.start_index + 2 // skip ![
                    else
                        item.start_index + 1; // skip [

                    const link_text = content[opener_pos..close_bracket_pos];
                    const url = content[after_close + 1 .. end];

                    const block_type: BlockType = if (item.delimiter_type == .ExcSquareBracket)
                        BlockType{ .Image = url }
                    else
                        BlockType{ .Link = url };

                    const link_block = try allocator.create(Block);
                    link_block.* = Block{
                        .blockType = block_type,
                        .content = link_text,
                        .children = std.ArrayList(*Block).empty,
                        .is_open = false,
                    };

                    try segments.append(allocator, InlineSegment{
                        .block = link_block,
                        .start_pos = item.start_index,
                        .end_pos = end + 1, // include the closing )
                    });

                    // Process emphasis within the link text (between opener and this node)
                    try processEmphasis(allocator, delimiter_stack, node, segments);

                    // Remove the opener
                    delimiter_stack.remove(node);

                    // Deactivate earlier [ openers (links can't be nested)
                    if (item.delimiter_type == .SquareBracket) {
                        var deactivate_node: ?*std.DoublyLinkedList.Node = delimiter_stack.last;
                        while (deactivate_node) |dn| {
                            const d_item = DelimiterStackItem.fromNode(dn);
                            if (d_item.delimiter_type == .SquareBracket) {
                                d_item.is_active = false;
                            }
                            deactivate_node = dn.prev;
                        }
                    }

                    return end + 1;
                }
            }

            // No valid link found, remove opener and continue
            const prev = node.prev;
            delimiter_stack.remove(node);
            search_node = prev;
            continue;
        }

        search_node = node.prev;
    }

    return null;
}

inline fn isAsciiPunctuation(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn appendDelimiter(allocator: Allocator, stack: *std.DoublyLinkedList, delimiter_type: InlineDelimiterType, num_delimiters: usize, start_index: usize, is_opener: bool, is_closer: bool) !void {
    const item = try allocator.create(DelimiterStackItem);
    item.* = DelimiterStackItem{
        .delimiter_type = delimiter_type,
        .num_delimiters = num_delimiters,
        .start_index = start_index,
        .is_active = true,
        .is_opener = is_opener,
        .is_closer = is_closer,
        .node = .{},
    };
    stack.append(&item.node);
}

fn compareSegments(_: void, a: InlineSegment, b: InlineSegment) bool {
    return a.start_pos < b.start_pos;
}

/// Build the final inline children from segments, filling in RawStr for gaps
fn buildInlineChildren(allocator: Allocator, content: []const u8, segments: *std.ArrayList(InlineSegment), parent: *Block) !void {
    // Sort segments by start position
    std.mem.sort(InlineSegment, segments.items, {}, compareSegments);

    var last_pos: usize = 0;

    for (segments.items) |segment| {
        // Add RawStr for any text before this segment
        if (segment.start_pos > last_pos) {
            const text = content[last_pos..segment.start_pos];
            const raw_block = try allocator.create(Block);
            raw_block.* = Block{
                .blockType = .RawStr,
                .content = text,
                .children = std.ArrayList(*Block).empty,
                .is_open = false,
            };
            try parent.children.append(allocator, raw_block);
        }

        // Fix the content pointer for emphasis blocks (was storing indices, not actual content)
        if (segment.block.blockType == .Emphasis or segment.block.blockType == .Strong) {
            // The content was temporarily stored as fake pointer with indices
            // Extract the range and set actual content
            const fake_slice = segment.block.content orelse "";
            const content_start = @intFromPtr(fake_slice.ptr);
            const content_end = fake_slice.len;
            if (content_end > content_start and content_end <= content.len) {
                segment.block.content = content[content_start..content_end];
            } else {
                segment.block.content = null;
            }
        }

        try parent.children.append(allocator, segment.block);
        last_pos = segment.end_pos;
    }

    // Add RawStr for any remaining text after the last segment
    if (last_pos < content.len) {
        const text = content[last_pos..];
        const raw_block = try allocator.create(Block);
        raw_block.* = Block{
            .blockType = .RawStr,
            .content = text,
            .children = std.ArrayList(*Block).empty,
            .is_open = false,
        };
        try parent.children.append(allocator, raw_block);
    }
}

pub fn parseInline(allocator: Allocator, current_block: *Block) !void {
    if (current_block.blockType == .Paragraph or current_block.blockType == .Heading) {
        var stack: std.DoublyLinkedList = .{};
        var segments = std.ArrayList(InlineSegment).empty;
        const content = current_block.content orelse return;
        const len = content.len;
        var i: usize = 0;

        while (i < len) {
            switch (content[i]) {
                '[' => {
                    try appendDelimiter(allocator, &stack, .SquareBracket, 1, i, true, false);
                    i += 1;
                },
                '!' => {
                    if (i + 1 < len and content[i + 1] == '[') {
                        try appendDelimiter(allocator, &stack, .ExcSquareBracket, 1, i, true, false);
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                '_' => {
                    const orig_i = i;
                    var num_delimiters: usize = 0;
                    while (i < len and content[i] == '_') {
                        num_delimiters += 1;
                        i += 1;
                    }

                    const char_before: ?u8 = if (orig_i > 0) content[orig_i - 1] else null;
                    const char_after: ?u8 = if (i < len) content[i] else null;

                    const precedes_whitespace = char_before == null or std.ascii.isWhitespace(char_before.?);
                    const precedes_punct = char_before != null and isAsciiPunctuation(char_before.?);
                    const follows_whitespace = char_after == null or std.ascii.isWhitespace(char_after.?);
                    const follows_punct = char_after != null and isAsciiPunctuation(char_after.?);

                    // Left-flanking: not followed by whitespace, and either not followed by punctuation
                    // or preceded by whitespace or punctuation
                    const is_left_flanking = !follows_whitespace and (!follows_punct or precedes_whitespace or precedes_punct);
                    // Right-flanking: not preceded by whitespace, and either not preceded by punctuation
                    // or followed by whitespace or punctuation
                    const is_right_flanking = !precedes_whitespace and (!precedes_punct or follows_whitespace or follows_punct);

                    // For underscore: opener if left-flanking and (not right-flanking or preceded by punct)
                    const is_opener = is_left_flanking and (!is_right_flanking or precedes_punct);
                    // For underscore: closer if right-flanking and (not left-flanking or followed by punct)
                    const is_closer = is_right_flanking and (!is_left_flanking or follows_punct);

                    if (is_opener or is_closer) {
                        try appendDelimiter(allocator, &stack, .Underscore, num_delimiters, orig_i, is_opener, is_closer);
                    }
                },
                '*' => {
                    const orig_i = i;
                    var num_delimiters: usize = 0;
                    while (i < len and content[i] == '*') {
                        num_delimiters += 1;
                        i += 1;
                    }

                    const char_before: ?u8 = if (orig_i > 0) content[orig_i - 1] else null;
                    const char_after: ?u8 = if (i < len) content[i] else null;

                    const precedes_whitespace = char_before == null or std.ascii.isWhitespace(char_before.?);
                    const precedes_punct = char_before != null and isAsciiPunctuation(char_before.?);
                    const follows_whitespace = char_after == null or std.ascii.isWhitespace(char_after.?);
                    const follows_punct = char_after != null and isAsciiPunctuation(char_after.?);

                    // Left-flanking delimiter run
                    const is_left_flanking = !follows_whitespace and (!follows_punct or precedes_whitespace or precedes_punct);
                    // Right-flanking delimiter run
                    const is_right_flanking = !precedes_whitespace and (!precedes_punct or follows_whitespace or follows_punct);

                    // For asterisk: opener if left-flanking
                    const is_opener = is_left_flanking;
                    // For asterisk: closer if right-flanking
                    const is_closer = is_right_flanking;

                    if (is_opener or is_closer) {
                        try appendDelimiter(allocator, &stack, .Star, num_delimiters, orig_i, is_opener, is_closer);
                    }
                },
                ']' => {
                    if (try lookForLinkOrImage(allocator, &stack, content, i, &segments)) |end_pos| {
                        i = end_pos;
                    } else {
                        i += 1;
                    }
                },
                else => i += 1,
            }
        }

        // Process remaining emphasis delimiters
        try processEmphasis(allocator, &stack, null, &segments);

        // Build the final inline children with RawStr for gaps
        try buildInlineChildren(allocator, content, &segments, current_block);
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

test "inline parser" {
    // Test document with various inline elements:
    // - Heading with *emphasis*
    // - Paragraph with *emphasis*, **strong**, _underscore emphasis_
    // - Links [text](url) and images ![alt](url)
    // - Multiple emphasis in one line
    const markdown_text =
        \\## A *formatted* heading
        \\This has *emphasis* and **strong** and _underscore emphasis_.
        \\Here is a [link](https://ziglang.org) and an ![image](https://example.com/img.png).
        \\Multiple *first* and *second* emphasis in one line.
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Expected structure after block + inline parsing
    // Note: block parser joins consecutive lines into one paragraph
    const paragraph_content = "This has *emphasis* and **strong** and _underscore emphasis_.\n" ++
        "Here is a [link](https://ziglang.org) and an ![image](https://example.com/img.png).\n" ++
        "Multiple *first* and *second* emphasis in one line.";

    const expected = try block(allocator, .Document, &.{
        // Heading with emphasis and RawStr for plain text
        try block(allocator, .{ .Heading = 2 }, &.{
            try block(allocator, .RawStr, &.{}, "## A "),
            try block(allocator, .Emphasis, &.{}, "formatted"),
            try block(allocator, .RawStr, &.{}, " heading"),
        }, "## A *formatted* heading"),
        // Single paragraph containing all inline elements with RawStr for plain text
        try block(allocator, .Paragraph, &.{
            try block(allocator, .RawStr, &.{}, "This has "),
            try block(allocator, .Emphasis, &.{}, "emphasis"),
            try block(allocator, .RawStr, &.{}, " and "),
            try block(allocator, .Strong, &.{}, "strong"),
            try block(allocator, .RawStr, &.{}, " and "),
            try block(allocator, .Emphasis, &.{}, "underscore emphasis"),
            try block(allocator, .RawStr, &.{}, ".\nHere is a "),
            try block(allocator, .{ .Link = "https://ziglang.org" }, &.{}, "link"),
            try block(allocator, .RawStr, &.{}, " and an "),
            try block(allocator, .{ .Image = "https://example.com/img.png" }, &.{}, "image"),
            try block(allocator, .RawStr, &.{}, ".\nMultiple "),
            try block(allocator, .Emphasis, &.{}, "first"),
            try block(allocator, .RawStr, &.{}, " and "),
            try block(allocator, .Emphasis, &.{}, "second"),
            try block(allocator, .RawStr, &.{}, " emphasis in one line."),
        }, paragraph_content),
    }, null);

    // Parse blocks first
    const document = try parseBlocks(allocator, markdown_text);

    // Then parse inline content
    try parseInline(allocator, document);

    printBlock(document, 0);

    try std.testing.expectEqualDeep(expected, document);
}
