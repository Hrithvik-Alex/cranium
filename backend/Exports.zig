// Exports.zig - All C ABI exports for Swift consumption
//
// This is the root source file for the static library. All export functions
// that are declared in cranium.h live here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const MdParser = @import("MdParser.zig");
const core_text_font = @import("CoreTextFont.zig");
const EditSession = @import("EditSession.zig");
const Metal = @import("Metal.zig");

const EditorFont = core_text_font.EditorFont;

pub const Block = MdParser.Block;
pub const BlockType = MdParser.BlockType;
pub const BlockTypeTag = MdParser.BlockTypeTag;

/// C-compatible font struct for the Swift bridge
pub const CEditorFont = extern struct {
    family_ptr: ?[*]const u8,
    family_len: usize,
    size: f32,
    weight: f32,
    is_monospaced: u8,
};

fn editorFontToC(font: EditorFont) CEditorFont {
    return CEditorFont{
        .family_ptr = font.family.ptr,
        .family_len = font.family.len,
        .size = font.size,
        .weight = font.weight,
        .is_monospaced = if (font.is_monospaced) 1 else 0,
    };
}

pub const CBlock = extern struct {
    block_type: BlockTypeTag,
    block_type_value: usize, // heading level, list depth, etc.
    block_id: usize,
    block_type_str_ptr: ?[*]const u8, // for Link/Image URL
    block_type_str_len: usize,
    children_ptr: ?[*]*CBlock,
    children_len: usize,
    content_ptr: ?[*]const u8,
    content_len: usize,
};

/// Document handle that owns its own arena allocator.
/// When the document is closed, the entire arena is freed at once.
pub const CDocument = extern struct {
    /// Pointer to the root CBlock (Document node)
    root_block: ?*CBlock,
    /// Opaque pointer to the document's arena allocator (allocated from page_allocator)
    /// This is *std.heap.ArenaAllocator but stored as opaque for C compatibility
    arena_ptr: ?*anyopaque,
};

pub const CCursorMetrics = extern struct {
    line_index: usize,
    column_byte: usize,
    caret_x: f32,
    caret_y: f32,
    line_height: f32,
};

pub const CEditSession = extern struct {
    root_block: ?*CBlock,
    active_block_id: usize,
    cursor_metrics: CCursorMetrics,
    font: CEditorFont,
    text_ptr: ?[*]const u8,
    text_len: usize,
    session_ptr: ?*anyopaque,
    cursor_byte_offset: usize,

    /// Sync state from the internal EditSession to this CEditSession
    pub fn sync(self: *CEditSession) void {
        const session: *EditSession = @ptrCast(@alignCast(self.session_ptr orelse return));

        // Convert Block -> CBlock if we have a root block
        if (session.root_block) |root| {
            var id_counter: usize = 1;
            self.root_block = toCBlock(session.ast_arena.allocator(), root, &id_counter) catch null;
        } else {
            self.root_block = null;
        }

        self.active_block_id = session.cursor.active_block_id;
        self.text_ptr = session.editor.buffer.ptr;
        self.text_len = session.editor.size;
        self.cursor_byte_offset = session.cursor.byte_offset;

        self.cursor_metrics = CCursorMetrics{
            .line_index = session.cursor.metrics.line_index,
            .column_byte = session.cursor.metrics.column_byte,
            .caret_x = session.cursor.metrics.caret_x,
            .caret_y = session.cursor.metrics.caret_y,
            .line_height = session.cursor.metrics.line_height,
        };
    }
};

pub fn toCBlock(allocator: Allocator, blk: *Block, id_counter: *usize) !*CBlock {
    const c_block = try allocator.create(CBlock);

    c_block.block_type = std.meta.activeTag(blk.blockType);
    c_block.block_type_value = blk.blockType.getValue();
    c_block.block_id = id_counter.*;
    id_counter.* += 1;

    if (blk.blockType.getStr()) |url| {
        c_block.block_type_str_ptr = url.ptr;
        c_block.block_type_str_len = url.len;
    } else {
        c_block.block_type_str_ptr = null;
        c_block.block_type_str_len = 0;
    }

    if (blk.content) |content| {
        c_block.content_ptr = content.ptr;
        c_block.content_len = content.len;
    } else {
        c_block.content_ptr = null;
        c_block.content_len = 0;
    }

    if (blk.children.items.len > 0) {
        const c_children = try allocator.alloc(*CBlock, blk.children.items.len);
        for (blk.children.items, 0..) |child, i| {
            c_children[i] = try toCBlock(allocator, child, id_counter);
        }
        c_block.children_ptr = c_children.ptr;
        c_block.children_len = c_children.len;
    } else {
        c_block.children_ptr = null;
        c_block.children_len = 0;
    }

    return c_block;
}

// ============================================================================
// Document Exports
// ============================================================================

/// Internal implementation that uses Zig error handling
fn openDocumentImpl(filename_slice: []const u8) !*CDocument {
    const page_alloc = std.heap.page_allocator;

    // Create a new arena for this document (the arena struct itself is on page_allocator)
    const arena = try page_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(page_alloc);
    errdefer {
        arena.deinit();
        page_alloc.destroy(arena);
    }

    const allocator = arena.allocator();

    const file = try std.fs.openFileAbsolute(filename_slice, .{});
    defer file.close();

    const file_contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    const block = try MdParser.parseBlocks(allocator, file_contents);
    try MdParser.parseInline(allocator, block);

    var id_counter: usize = 1;
    const c_block = try toCBlock(allocator, block, &id_counter);

    // Create and return the document handle
    const doc = try allocator.create(CDocument);
    doc.* = CDocument{
        .root_block = c_block,
        .arena_ptr = arena,
    };

    return doc;
}

export fn openDocument(filename: [*:0]const u8) callconv(.c) ?*CDocument {
    return openDocumentImpl(std.mem.span(filename)) catch null;
}

export fn closeDocument(doc: ?*CDocument) callconv(.c) void {
    const d = doc orelse return;
    const page_alloc = std.heap.page_allocator;

    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(d.arena_ptr orelse return));
    arena.deinit();
    page_alloc.destroy(arena);
}

export fn createFile(filename: [*:0]const u8) callconv(.c) c_int {
    const filename_slice = std.mem.span(filename);
    const file = std.fs.createFileAbsolute(filename_slice, .{}) catch return -1;
    file.close();
    return 0;
}

// ============================================================================
// Edit Session Exports
// ============================================================================

export fn createEditSession(filename: [*:0]const u8) callconv(.c) ?*CEditSession {
    const session = EditSession.create(std.mem.span(filename)) catch return null;

    // Allocate CEditSession from the session's arena
    const c_session = session.session_arena.allocator().create(CEditSession) catch return null;
    c_session.* = CEditSession{
        .root_block = null,
        .active_block_id = 0,
        .cursor_metrics = .{
            .line_index = 0,
            .column_byte = 0,
            .caret_x = 0,
            .caret_y = 0,
            .line_height = 0,
        },
        .font = editorFontToC(core_text_font.default_editor_font),
        .text_ptr = null,
        .text_len = 0,
        .session_ptr = session,
        .cursor_byte_offset = 0,
    };

    c_session.sync();
    return c_session;
}

export fn closeEditSession(session_ptr: ?*CEditSession) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));
    session.close();
}

export fn handleTextInput(session_ptr: ?*CEditSession, text: [*:0]const u8) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));

    session.insertText(std.mem.span(text)) catch return;
    c_session.sync();
}

export fn handleKeyEvent(session_ptr: ?*CEditSession, key_code: u16, modifiers: u64) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));

    const cmd_mask: u64 = 1 << 20;
    const shift_mask: u64 = 1 << 17;
    if ((modifiers & cmd_mask) != 0 and key_code == 1) {
        session.saveFile() catch {};
        return;
    }
    if ((modifiers & cmd_mask) != 0 and (modifiers & shift_mask) != 0 and key_code == 6) {
        _ = session.redo() catch return;
        c_session.sync();
        return;
    }
    if ((modifiers & cmd_mask) != 0 and key_code == 6) {
        _ = session.undo() catch return;
        c_session.sync();
        return;
    }
    if ((modifiers & cmd_mask) != 0 and key_code == 16) {
        _ = session.redo() catch return;
        c_session.sync();
        return;
    }

    switch (key_code) {
        36 => session.insertText("\n") catch return,
        48 => session.insertText("    ") catch return,
        51 => session.deleteBackward() catch return,
        117 => session.deleteForward() catch return,
        123 => session.moveCursorLeft(),
        124 => session.moveCursorRight(),
        126 => session.moveCursorUp(),
        125 => session.moveCursorDown(),
        else => {},
    }
    c_session.sync();
}

export fn setCursorByteOffset(session_ptr: ?*CEditSession, byte_offset: usize) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));
    session.setCursorOffset(byte_offset);
    c_session.sync();
}

export fn deleteTextRange(session_ptr: ?*CEditSession, start_offset: usize, end_offset: usize) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));
    session.deleteTextRange(start_offset, end_offset) catch return;
    c_session.sync();
}

// ============================================================================
// Metal Surface Exports
// ============================================================================

export fn surface_init(view: ?*anyopaque) callconv(.c) ?*anyopaque {
    const v = view orelse return null;
    const r = Metal.init(v) catch return null;
    return @ptrCast(r);
}

export fn render_frame(
    renderer_ptr: ?*anyopaque,
    text_ptr: ?[*]const u8,
    text_len: c_int,
    view_width: f32,
    view_height: f32,
    cursor_byte_offset: c_int,
    selection_start_byte_offset: c_int,
    selection_end_byte_offset: c_int,
) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const r: *Metal = @ptrCast(@alignCast(ptr));
    const text: []const u8 = if (text_ptr) |t| (if (text_len > 0) t[0..@intCast(text_len)] else "") else "";
    r.render(
        text,
        view_width,
        view_height,
        cursor_byte_offset,
        selection_start_byte_offset,
        selection_end_byte_offset,
    );
}

export fn hit_test(
    renderer_ptr: ?*anyopaque,
    text_ptr: ?[*]const u8,
    text_len: c_int,
    view_width: f32,
    click_x: f32,
    click_y: f32,
) callconv(.c) c_int {
    const ptr = renderer_ptr orelse return 0;
    const r: *Metal = @ptrCast(@alignCast(ptr));
    const text: []const u8 = if (text_ptr) |t| (if (text_len > 0) t[0..@intCast(text_len)] else "") else "";
    return r.hitTest(text, view_width, click_x, click_y);
}

export fn update_scroll(renderer_ptr: ?*anyopaque, delta_y: f32) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const r: *Metal = @ptrCast(@alignCast(ptr));
    r.updateScroll(delta_y);
}

export fn surface_deinit(renderer_ptr: ?*anyopaque) callconv(.c) void {
    const ptr = renderer_ptr orelse return;
    const r: *Metal = @ptrCast(@alignCast(ptr));
    r.deinit();
}
