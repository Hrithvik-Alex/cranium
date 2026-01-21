/**
 * cranium.h - C interface for Zig markdown parser
 *
 * This header defines the C ABI bridge between the Zig backend and Swift frontend.
 * Include this file in your Swift bridging header for Xcode type completion.
 */

#ifndef CRANIUM_H
#define CRANIUM_H

#include <stddef.h>
#include <stdint.h>

/**
 * Block type tags - must match BlockTypeTag enum in md_parser.zig
 *
 * Block types (0-8): Document structure elements
 * Inline types (9-14): Text formatting elements
 */
typedef enum
{
    // Block types
    BlockType_Document = 0,
    BlockType_Paragraph = 1,
    BlockType_Heading = 2,
    BlockType_CodeBlock = 3,
    BlockType_BlockQuote = 4,
    BlockType_OrderedList = 5,
    BlockType_OrderedListItem = 6,
    BlockType_UnorderedList = 7,
    BlockType_UnorderedListItem = 8,
    // Inline types
    BlockType_RawStr = 9,
    BlockType_Strong = 10,
    BlockType_Emphasis = 11,
    BlockType_StrongEmph = 12,
    BlockType_Link = 13,
    BlockType_Image = 14,
} BlockTypeTag;

/**
 * C-compatible block structure - must match CBlock in md_file_interop.zig
 *
 * This structure represents a node in the markdown AST.
 * All string pointers point into the original file buffer and remain valid
 * as long as the CBlock tree is not freed.
 */
typedef struct CBlock
{
    /** The type of this block (see BlockTypeTag enum) */
    BlockTypeTag block_type;

    /**
     * Numeric value associated with the block type:
     * - For Heading: the heading level (1-6)
     * - For BlockQuote, OrderedList, OrderedListItem, UnorderedList, UnorderedListItem: the nesting depth
     * - For other types: 0
     */
    size_t block_type_value;

    /**
     * String value associated with the block type (for Link/Image: the URL)
     * NULL for other block types
     */
    const char *block_type_str_ptr;

    /** Length of block_type_str_ptr (0 if NULL) */
    size_t block_type_str_len;

    /** Pointer to array of child blocks (NULL if no children) */
    struct CBlock **children_ptr;

    /** Number of child blocks */
    size_t children_len;

    /** Pointer to the text content of this block (NULL if no content) */
    const char *content_ptr;

    /** Length of content_ptr (0 if NULL) */
    size_t content_len;
} CBlock;

/**
 * Parse a markdown file and return a C-compatible Block tree.
 *
 * @param filename Null-terminated C string containing the absolute path to the markdown file.
 * @return Pointer to the root CBlock (Document) on success, or NULL on error.
 *         The returned CBlock tree is ready for C consumption.
 *         All string data (content, URLs) point into the file buffer and remain valid
 *         as long as the CBlock tree is not freed.
 *
 * @note The caller is responsible for managing the CBlock's lifetime.
 *       Currently there is no free function; the memory is allocated from page_allocator.
 */
CBlock *getMarkdownBlocks(const char *filename);

#endif /* CRANIUM_H */
