const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = std.unicode;

const MdParser = @import("MdParser.zig");
const Editor = @import("Editor.zig");
const core_text_font = @import("CoreTextFont.zig");

const EditorFont = core_text_font.EditorFont;
const FontCache = core_text_font.FontCache;
const heading_sizes = core_text_font.heading_sizes;

const Block = MdParser.Block;

const Self = @This();

pub const Cursor = struct {
    byte_offset: usize,
    active_block_id: usize,
    metrics: CursorMetrics,
};

pub const LineInfo = struct {
    line_start: usize,
    line_end: usize,
    y_start: f32,
    font_size: f32,
    block_id: usize,
    // TODO: get rid of this leaky abstraction
    ct_line: core_text_font.CTLineHandle,
};

pub const CursorMetrics = struct {
    line_index: usize,
    column_byte: usize,
    caret_x: f32,
    caret_y: f32,
    line_height: f32,
};

// ============================================================================
// Struct Fields
// ============================================================================

session_arena: *std.heap.ArenaAllocator,
ast_arena: *std.heap.ArenaAllocator,
editor: Editor,
file_path: []const u8,
line_info: []LineInfo,
font: EditorFont,
font_cache: FontCache,
root_block: ?*Block,
cursor: Cursor,

// ============================================================================
// Private Helpers
// ============================================================================

const BlockSearchResult = struct {
    block: *Block,
    id: usize,
};

// TODO: add information to the md parser so that this is easier, like a map from line -> block or something
/// Find block containing cursor position, returning both the block and its ID
fn findBlockAtCursor(block: *Block, cursor_ptr: [*]const u8, id_counter: *usize) ?BlockSearchResult {
    const current_id = id_counter.*;
    id_counter.* += 1;

    for (block.children.items) |child| {
        if (findBlockAtCursor(child, cursor_ptr, id_counter)) |found| {
            return found;
        }
    }

    const content = block.content orelse return null;
    if (content.len == 0) return null;

    const start = @intFromPtr(content.ptr);
    const end = start + content.len;
    const cursor_addr = @intFromPtr(cursor_ptr);
    if (cursor_addr >= start and cursor_addr <= end) {
        switch (std.meta.activeTag(block.blockType)) {
            .Document,
            .Paragraph,
            .Heading,
            .CodeBlock,
            .BlockQuote,
            .OrderedList,
            .OrderedListItem,
            .UnorderedList,
            .UnorderedListItem,
            => return .{ .block = block, .id = current_id },
            else => {},
        }
    }
    return null;
}

fn fontSizeForBlockType(block_type: ?MdParser.BlockType, base_size: f32) f32 {
    const bt = block_type orelse return base_size;
    const tag = std.meta.activeTag(bt);
    const value = bt.getValue();
    return switch (tag) {
        .Heading => blk: {
            if (value == 0) break :blk base_size;
            const idx = @min(value - 1, heading_sizes.len - 1);
            break :blk heading_sizes[idx];
        },
        else => base_size,
    };
}

fn computeLineInfo(
    allocator: Allocator,
    text_ptr: [*]const u8,
    text_len: usize,
    self: *Self,
) ![]LineInfo {
    if (text_len == 0) return &.{};

    var line_count: usize = 1;
    for (text_ptr[0..text_len]) |ch| {
        if (ch == '\n') line_count += 1;
    }

    const info = try allocator.alloc(LineInfo, line_count);
    var y: f32 = 0;
    var idx: usize = 0;
    var line_start: usize = 0;

    for (text_ptr[0..text_len], 0..) |ch, i| {
        const is_line_end = ch == '\n' or i + 1 == text_len;
        if (is_line_end) {
            const cursor_ptr = text_ptr + @min(line_start, text_len);

            var id_counter: usize = 1;
            const result = if (self.root_block) |root|
                findBlockAtCursor(root, cursor_ptr, &id_counter)
            else
                null;

            const block_type = if (result) |r| r.block.blockType else null;
            const block_id = if (result) |r| r.id else 0;
            const font_size = fontSizeForBlockType(block_type, self.font.size);
            const line_height = self.font_cache.getLineHeight(self.font, font_size);

            const line_text = text_ptr[line_start .. i + 1];
            const font_ref = self.font_cache.getFont(self.font, font_size);
            const ct_line = core_text_font.createCTLine(font_ref, line_text);

            info[idx] = .{
                .line_start = line_start,
                .line_end = i + 1,
                .y_start = y,
                .font_size = font_size,
                .block_id = block_id,
                .ct_line = ct_line,
            };
            y += line_height;
            idx += 1;
            line_start = i + 1;
        }
    }

    return info;
}

fn utf16IndexFromUtf8ByteOffset(text: []const u8, byte_offset: usize) usize {
    var i: usize = 0;
    var utf16_count: usize = 0;
    while (i < text.len and i < byte_offset) {
        const first = text[i];
        const seq_len = unicode.utf8ByteSequenceLength(first) catch 1;
        const end = @min(i + seq_len, text.len);
        const codepoint = unicode.utf8Decode(text[i..end]) catch first;
        utf16_count += if (codepoint > 0xFFFF) 2 else 1;
        i = end;
    }
    return utf16_count;
}

fn lineIndexForCursor(line_info: []const LineInfo, cursor_byte: usize) usize {
    var line_index: usize = 0;
    for (line_info, 0..) |info, i| {
        if (info.line_start > cursor_byte) break;
        line_index = i;
    }
    return line_index;
}

fn updateActiveBlock(self: *Self) void {
    if (self.editor.size == 0) return;
    if (self.cursor.byte_offset > self.editor.size) {
        self.cursor.byte_offset = self.editor.size;
    }
    const cursor_ptr = self.editor.buffer.ptr + self.cursor.byte_offset;
    if (self.root_block) |root| {
        var id_counter: usize = 1;
        if (findBlockAtCursor(root, cursor_ptr, &id_counter)) |result| {
            self.cursor.active_block_id = result.id;
            return;
        }
    }
    self.cursor.active_block_id = 0;
}

fn updateCursorMetrics(self: *Self) void {
    const text = self.editor.buffer[0..self.editor.size];
    const line_info = self.line_info;
    if (line_info.len == 0) return;
    if (self.cursor.byte_offset > text.len) {
        self.cursor.byte_offset = text.len;
    }

    const line_index = lineIndexForCursor(line_info, self.cursor.byte_offset);
    const current_line = line_info[line_index];

    const line_text = text[current_line.line_start..current_line.line_end];
    const column_byte = self.cursor.byte_offset - current_line.line_start;

    const utf16_index = utf16IndexFromUtf8ByteOffset(line_text, column_byte);
    const caret_x = core_text_font.getCaretX(current_line.ct_line, utf16_index);

    const line_height = self.font_cache.getLineHeight(self.font, current_line.font_size);
    const caret_y: f32 = current_line.y_start;

    self.cursor.metrics = CursorMetrics{
        .line_index = line_index,
        .column_byte = column_byte,
        .caret_x = @floatCast(caret_x),
        .caret_y = caret_y,
        .line_height = @floatCast(line_height),
    };
}

fn releaseLineInfo(line_info: []LineInfo) void {
    for (line_info) |info| {
        core_text_font.releaseCTLine(info.ct_line);
    }
}

fn updateCursor(self: *Self, byte_pos: usize) void {
    self.cursor.byte_offset = byte_pos;
    self.updateActiveBlock();
    self.updateCursorMetrics();
}

// ============================================================================
// Public Methods
// ============================================================================

// TODO: this should be incremental
pub fn reparse(self: *Self) !void {
    releaseLineInfo(self.line_info);
    self.ast_arena.deinit();
    self.ast_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const allocator = self.ast_arena.allocator();
    const text = self.editor.buffer[0..self.editor.size];

    const block = try MdParser.parseBlocks(allocator, text);
    try MdParser.parseInline(allocator, block);

    self.root_block = block;
    self.line_info = try computeLineInfo(allocator, text.ptr, text.len, self);

    self.updateActiveBlock();
    self.updateCursorMetrics();
}

pub fn create(filename: []const u8) !*Self {
    const page_alloc = std.heap.page_allocator;

    const session_arena = try page_alloc.create(std.heap.ArenaAllocator);
    session_arena.* = std.heap.ArenaAllocator.init(page_alloc);
    errdefer {
        session_arena.deinit();
        page_alloc.destroy(session_arena);
    }

    const ast_arena = try page_alloc.create(std.heap.ArenaAllocator);
    ast_arena.* = std.heap.ArenaAllocator.init(page_alloc);
    errdefer {
        ast_arena.deinit();
        page_alloc.destroy(ast_arena);
    }

    const allocator = session_arena.allocator();
    const file_path = try allocator.dupe(u8, filename);

    const file = try std.fs.openFileAbsolute(filename, .{});
    defer file.close();
    const file_contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    const editor = try Editor.create(allocator, file_contents);

    const session = try allocator.create(Self);
    session.* = Self{
        .session_arena = session_arena,
        .ast_arena = ast_arena,
        .editor = editor,
        .file_path = file_path,
        .line_info = &[_]LineInfo{},
        .font = core_text_font.default_editor_font,
        .font_cache = FontCache.init(core_text_font.default_editor_font.size),
        .root_block = null,
        .cursor = .{
            .byte_offset = 0,
            .active_block_id = 0,
            .metrics = .{
                .line_index = 0,
                .column_byte = 0,
                .caret_x = 0,
                .caret_y = 0,
                .line_height = 0,
            },
        },
    };

    try session.reparse();
    return session;
}

pub fn close(self: *Self) void {
    releaseLineInfo(self.line_info);
    self.font_cache.deinit(); // Release external CoreText resources

    const page_alloc = std.heap.page_allocator;

    self.ast_arena.deinit();
    const ast_arena = self.ast_arena;

    // session_arena owns `self` itself, so copy the pointer before deinit
    const session_arena = self.session_arena;
    session_arena.deinit();

    page_alloc.destroy(ast_arena);
    page_alloc.destroy(session_arena);
}

pub fn insertText(self: *Self, text: []const u8) !void {
    if (text.len == 0) return;
    try self.editor.insert(self.session_arena.allocator(), self.cursor.byte_offset, text);
    self.cursor.byte_offset += text.len;
    try self.reparse();
}

pub fn deleteBackward(self: *Self) !void {
    const prev = @max(0, self.cursor.byte_offset - 1);
    if (prev < self.cursor.byte_offset) {
        try self.editor.delete_range(prev, self.cursor.byte_offset);
        self.cursor.byte_offset = prev;
        try self.reparse();
    }
}

pub fn deleteForward(self: *Self) !void {
    const next = @min(self.editor.size, self.cursor.byte_offset + 1);
    if (next > self.cursor.byte_offset) {
        try self.editor.delete_range(self.cursor.byte_offset, next);
        try self.reparse();
    }
}

pub fn moveCursorLeft(self: *Self) void {
    self.updateCursor(@max(0, self.cursor.byte_offset - 1));
}

pub fn moveCursorRight(self: *Self) void {
    self.updateCursor(@min(self.editor.size, self.cursor.byte_offset + 1));
}

pub fn moveCursorUp(self: *Self) void {
    if (self.line_info.len == 0) return;
    const line_index = lineIndexForCursor(self.line_info, self.cursor.byte_offset);
    if (line_index == 0) return;

    const current_line = self.line_info[line_index];
    const col = self.cursor.byte_offset - current_line.line_start;
    const target_line = self.line_info[line_index - 1];
    self.updateCursor(@min(target_line.line_start + col, target_line.line_end));
}

pub fn moveCursorDown(self: *Self) void {
    if (self.line_info.len == 0) return;
    const line_index = lineIndexForCursor(self.line_info, self.cursor.byte_offset);
    if (line_index + 1 >= self.line_info.len) return;

    const current_line = self.line_info[line_index];
    const col = self.cursor.byte_offset - current_line.line_start;
    const target_line = self.line_info[line_index + 1];
    self.updateCursor(@min(target_line.line_start + col, target_line.line_end));
}

pub fn setCursorOffset(self: *Self, offset: usize) void {
    self.updateCursor(@min(offset, self.editor.size));
}

pub fn deleteTextRange(self: *Self, start_offset: usize, end_offset: usize) !void {
    const start = @min(start_offset, self.editor.size);
    const end = @min(end_offset, self.editor.size);

    if (end <= start) {
        self.updateCursor(start);
        return;
    }

    try self.editor.delete_range(start, end);
    self.cursor.byte_offset = start;
    try self.reparse();
}

pub fn saveFile(self: *Self) !void {
    const file = try std.fs.createFileAbsolute(self.file_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(self.editor.buffer[0..self.editor.size]);
}
