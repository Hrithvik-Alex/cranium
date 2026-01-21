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

/// Parse a markdown file and return a C-compatible Block tree.
///
/// Parameters:
///   filename: Null-terminated C string containing the absolute path to the markdown file.
///
/// Returns:
///   Pointer to the root CBlock (Document) on success, or null on error.
///   The returned CBlock tree is ready for C consumption.
///   All string data (content, URLs) point into the file buffer and remain valid
///   as long as the CBlock tree is not freed.
///
/// Note: The caller is responsible for managing the CBlock's lifetime.
/// Currently there is no free function; the memory is allocated from page_allocator.
export fn getMarkdownBlocks(filename: [*:0]const u8) callconv(.c) ?*CBlock {
    const allocator = std.heap.page_allocator;

    const filename_slice = std.mem.span(filename);

    const file = std.fs.openFileAbsolute(filename_slice, .{}) catch return null;
    defer file.close();

    const file_contents = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return null;

    const block = md_parser.parseBlocks(allocator, file_contents) catch return null;
    md_parser.parseInline(allocator, block) catch return null;

    const c_block = toCBlock(allocator, block) catch return null;

    block.deinit(allocator);

    return c_block;
}
