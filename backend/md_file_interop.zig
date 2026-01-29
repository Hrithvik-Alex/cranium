const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const md_parser = @import("md_parser.zig");
const font = @import("font.zig");
const edit_session = @import("edit_session.zig");

const EditSession = edit_session.EditSession;

pub const Block = md_parser.Block;
pub const BlockType = md_parser.BlockType;
pub const BlockTypeTag = md_parser.BlockTypeTag;

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

pub const CEditorFont = font.CEditorFont;

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
        self.text_ptr = session.text.ptr;
        self.text_len = session.text.len;

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

    const block = try md_parser.parseBlocks(allocator, file_contents);
    try md_parser.parseInline(allocator, block);

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

/// Open and parse a markdown file, returning a document handle.
///
/// Each document owns its own arena allocator. All memory for the document
/// (CBlocks, file buffer, etc.) is allocated from this arena. When closeDocument()
/// is called, the entire arena is freed at once - no need for individual frees.
///
/// Parameters:
///   filename: Null-terminated C string containing the absolute path to the markdown file.
///
/// Returns:
///   Pointer to a CDocument handle on success, or null on error.
///   The caller is responsible for calling closeDocument() to free resources.
export fn openDocument(filename: [*:0]const u8) callconv(.c) ?*CDocument {
    return openDocumentImpl(std.mem.span(filename)) catch null;
}

/// Close a document and free all associated resources.
///
/// This deinits the document's arena allocator, which frees all memory
/// (CBlocks, file buffer, the document handle itself) in one operation.
///
/// Parameters:
///   doc: Pointer to the CDocument to close. May be null (no-op).
///
/// After calling this function, the document pointer and all CBlock pointers
/// derived from it are invalid and must not be used.
export fn closeDocument(doc: ?*CDocument) callconv(.c) void {
    const d = doc orelse return;
    const page_alloc = std.heap.page_allocator;

    // Get the arena from the opaque pointer
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(d.arena_ptr orelse return));

    // Deinit the arena - this frees ALL memory allocated for this document
    // (CBlocks, file buffer, the CDocument struct itself, everything)
    arena.deinit();

    // Free the arena struct itself (which was allocated from page_allocator)
    page_alloc.destroy(arena);
}

/// Create a new empty file at the specified path.
///
/// Parameters:
///   filename: Null-terminated C string containing the absolute path for the new file.
///
/// Returns:
///   0 on success, -1 on error.
export fn createFile(filename: [*:0]const u8) callconv(.c) c_int {
    const filename_slice = std.mem.span(filename);

    const file = std.fs.createFileAbsolute(filename_slice, .{}) catch return -1;
    file.close();

    return 0;
}

// ============================================================================
// Edit Session C Interop
// ============================================================================

export fn createEditSession(filename: [*:0]const u8) callconv(.c) ?*CEditSession {
    const session = edit_session.create(std.mem.span(filename)) catch return null;

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
        .font = edit_session.default_editor_font.toC(),
        .text_ptr = null,
        .text_len = 0,
        .session_ptr = session,
    };

    c_session.sync();
    return c_session;
}

export fn closeEditSession(session_ptr: ?*CEditSession) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));
    edit_session.close(session);
}

export fn handleTextInput(session_ptr: ?*CEditSession, text: [*:0]const u8) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));

    edit_session.insertText(session, std.mem.span(text)) catch return;
    c_session.sync();
}

export fn handleKeyEvent(session_ptr: ?*CEditSession, key_code: u16, modifiers: u64) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));

    const cmd_mask: u64 = 1 << 20;
    if ((modifiers & cmd_mask) != 0 and key_code == 1) {
        edit_session.saveFile(session) catch {};
        return;
    }

    switch (key_code) {
        51 => edit_session.deleteBackward(session) catch return,
        117 => edit_session.deleteForward(session) catch return,
        123 => edit_session.moveCursorLeft(session),
        124 => edit_session.moveCursorRight(session),
        126 => edit_session.moveCursorUp(session),
        125 => edit_session.moveCursorDown(session),
        else => {},
    }
    c_session.sync();
}

export fn setCursorByteOffset(session_ptr: ?*CEditSession, byte_offset: usize) callconv(.c) void {
    const c_session = session_ptr orelse return;
    const session: *EditSession = @ptrCast(@alignCast(c_session.session_ptr orelse return));
    edit_session.setCursorOffset(session, byte_offset);
    c_session.sync();
}
