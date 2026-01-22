const std = @import("std");
const Allocator = std.mem.Allocator;
const md_parser = @import("md_parser.zig");

pub const Block = md_parser.Block;
pub const BlockType = md_parser.BlockType;
pub const BlockTypeTag = md_parser.BlockTypeTag;

pub const CBlock = extern struct {
    block_type: BlockTypeTag,
    block_type_value: usize, // heading level, list depth, etc.
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

pub fn toCBlock(allocator: Allocator, blk: *Block) !*CBlock {
    const c_block = try allocator.create(CBlock);

    c_block.block_type = std.meta.activeTag(blk.blockType);
    c_block.block_type_value = blk.blockType.getValue();

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
            c_children[i] = try toCBlock(allocator, child);
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

    const c_block = try toCBlock(allocator, block);

    // Clean up the intermediate Zig Block tree (the CBlock tree now has copies of the data)
    block.deinit(allocator);

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
