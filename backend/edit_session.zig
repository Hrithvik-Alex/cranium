const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = std.unicode;

const md_parser = @import("md_parser.zig");
const Editor = @import("Editor.zig");
const core_text_font = @import("CoreTextFont.zig");

const EditorFont = core_text_font.EditorFont;
const FontCache = core_text_font.FontCache;
const heading_sizes = core_text_font.heading_sizes;

const Block = md_parser.Block;

pub const Cursor = struct {
    byte_offset: usize,
    active_block_id: usize,
    metrics: CursorMetrics,
};

pub const EditSession = struct {
    session_arena: *std.heap.ArenaAllocator,
    ast_arena: *std.heap.ArenaAllocator,
    editor: Editor,
    file_path: []const u8,
    line_info: []LineInfo,
    font: EditorFont,
    font_cache: FontCache,
    root_block: ?*Block,
    cursor: Cursor,
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

fn fontSizeForBlockType(block_type: ?md_parser.BlockType, base_size: f32) f32 {
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
    session: *EditSession,
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
            const result = if (session.root_block) |root|
                findBlockAtCursor(root, cursor_ptr, &id_counter)
            else
                null;

            const block_type = if (result) |r| r.block.blockType else null;
            const block_id = if (result) |r| r.id else 0;
            const font_size = fontSizeForBlockType(block_type, session.font.size);
            const line_height = session.font_cache.getLineHeight(session.font, font_size);

            const line_text = text_ptr[line_start .. i + 1];
            const font_ref = session.font_cache.getFont(session.font, font_size);
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

fn updateActiveBlock(session: *EditSession) void {
    if (session.editor.size == 0) return;
    if (session.cursor.byte_offset > session.editor.size) {
        session.cursor.byte_offset = session.editor.size;
    }
    const cursor_ptr = session.editor.buffer.ptr + session.cursor.byte_offset;
    if (session.root_block) |root| {
        var id_counter: usize = 1;
        if (findBlockAtCursor(root, cursor_ptr, &id_counter)) |result| {
            session.cursor.active_block_id = result.id;
            return;
        }
    }
    session.cursor.active_block_id = 0;
}

fn updateCursorMetrics(session: *EditSession) void {
    const text = session.editor.buffer[0..session.editor.size];
    const line_info = session.line_info;
    if (line_info.len == 0) return;
    if (session.cursor.byte_offset > text.len) {
        session.cursor.byte_offset = text.len;
    }

    const line_index = lineIndexForCursor(line_info, session.cursor.byte_offset);
    const current_line = line_info[line_index];

    const line_text = text[current_line.line_start..current_line.line_end];
    const column_byte = session.cursor.byte_offset - current_line.line_start;

    const utf16_index = utf16IndexFromUtf8ByteOffset(line_text, column_byte);
    const caret_x = core_text_font.getCaretX(current_line.ct_line, utf16_index);

    const line_height = session.font_cache.getLineHeight(session.font, current_line.font_size);
    const caret_y: f32 = current_line.y_start;

    session.cursor.metrics = CursorMetrics{
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

// TODO: this should be incremental
pub fn reparse(session: *EditSession) !void {
    releaseLineInfo(session.line_info);
    session.ast_arena.deinit();
    session.ast_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const allocator = session.ast_arena.allocator();
    const text = session.editor.buffer[0..session.editor.size];

    const block = try md_parser.parseBlocks(allocator, text);
    try md_parser.parseInline(allocator, block);

    session.root_block = block;
    session.line_info = try computeLineInfo(allocator, text.ptr, text.len, session);

    updateActiveBlock(session);
    updateCursorMetrics(session);
}

pub fn create(filename: []const u8) !*EditSession {
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

    const session = try allocator.create(EditSession);
    session.* = EditSession{
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

    try reparse(session);
    return session;
}

pub fn close(session: *EditSession) void {
    releaseLineInfo(session.line_info);
    session.font_cache.deinit(); // Release external CoreText resources

    const page_alloc = std.heap.page_allocator;

    session.ast_arena.deinit();
    const ast_arena = session.ast_arena;

    // session_arena owns `session` itself, so copy the pointer before deinit
    const session_arena = session.session_arena;
    session_arena.deinit();

    page_alloc.destroy(ast_arena);
    page_alloc.destroy(session_arena);
}

pub fn insertText(session: *EditSession, text: []const u8) !void {
    if (text.len == 0) return;
    try session.editor.insert(session.session_arena.allocator(), session.cursor.byte_offset, text);
    session.cursor.byte_offset += text.len;
    try reparse(session);
}

pub fn deleteBackward(session: *EditSession) !void {
    const prev = @max(0, session.cursor.byte_offset - 1);
    if (prev < session.cursor.byte_offset) {
        try session.editor.delete_range(prev, session.cursor.byte_offset);
        session.cursor.byte_offset = prev;
        try reparse(session);
    }
}

pub fn deleteForward(session: *EditSession) !void {
    const next = @min(session.editor.size, session.cursor.byte_offset + 1);
    if (next > session.cursor.byte_offset) {
        try session.editor.delete_range(session.cursor.byte_offset, next);
        try reparse(session);
    }
}

fn updateCursor(session: *EditSession, byte_pos: usize) void {
    session.cursor.byte_offset = byte_pos;
    updateActiveBlock(session);
    updateCursorMetrics(session);
}

pub fn moveCursorLeft(session: *EditSession) void {
    updateCursor(session, @max(0, session.cursor.byte_offset - 1));
}

pub fn moveCursorRight(session: *EditSession) void {
    updateCursor(session, @min(session.editor.size, session.cursor.byte_offset + 1));
}

pub fn moveCursorUp(session: *EditSession) void {
    if (session.line_info.len == 0) return;
    const line_index = lineIndexForCursor(session.line_info, session.cursor.byte_offset);
    if (line_index == 0) return;

    const current_line = session.line_info[line_index];
    const col = session.cursor.byte_offset - current_line.line_start;
    const target_line = session.line_info[line_index - 1];
    updateCursor(session, @min(target_line.line_start + col, target_line.line_end));
}

pub fn moveCursorDown(session: *EditSession) void {
    if (session.line_info.len == 0) return;
    const line_index = lineIndexForCursor(session.line_info, session.cursor.byte_offset);
    if (line_index + 1 >= session.line_info.len) return;

    const current_line = session.line_info[line_index];
    const col = session.cursor.byte_offset - current_line.line_start;
    const target_line = session.line_info[line_index + 1];
    updateCursor(session, @min(target_line.line_start + col, target_line.line_end));
}

pub fn setCursorOffset(session: *EditSession, offset: usize) void {
    updateCursor(session, @min(offset, session.editor.size));
}

pub fn saveFile(session: *EditSession) !void {
    const file = try std.fs.createFileAbsolute(session.file_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(session.editor.buffer[0..session.editor.size]);
}
