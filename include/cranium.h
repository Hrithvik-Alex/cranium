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
 * as long as the CDocument is not closed.
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

    /** Unique block id within a document */
    size_t block_id;

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
 * Document handle that owns its own arena allocator.
 * When the document is closed, the entire arena is freed at once.
 */
typedef struct CDocument
{
    /** Pointer to the root CBlock (Document node) */
    CBlock *root_block;

    /** Opaque pointer to the document's arena allocator (internal use) */
    void *arena_ptr;
} CDocument;

typedef struct CEditorFont
{
    const char *family_ptr;
    size_t family_len;
    float size;
    float weight;
    uint8_t is_monospaced;
} CEditorFont;

typedef struct CCursorMetrics
{
    size_t line_index;
    size_t column_byte;
    float caret_x;
    float caret_y;
    float line_height;
} CCursorMetrics;

typedef struct CEditSession
{
    CBlock *root_block;
    size_t active_block_id;
    CCursorMetrics cursor_metrics;
    CEditorFont font;
    const char *text_ptr;
    size_t text_len;
    void *session_ptr;
    size_t cursor_byte_offset;
} CEditSession;

/**
 * Open and parse a markdown file, returning a document handle.
 *
 * @param filename Null-terminated C string containing the absolute path to the markdown file.
 * @return Pointer to a CDocument handle on success, or NULL on error.
 *         The caller is responsible for calling closeDocument() to free resources.
 */
CDocument *openDocument(const char *filename);

/**
 * Close a document and free all associated resources.
 *
 * @param doc Pointer to the CDocument to close. May be NULL (no-op).
 *
 * After calling this function, the document pointer and all CBlock pointers
 * derived from it are invalid and must not be used.
 */
void closeDocument(CDocument *doc);

/**
 * Create a new empty file at the specified path.
 *
 * @param filename Null-terminated C string containing the absolute path for the new file.
 * @return 0 on success, -1 on error.
 */
int createFile(const char *filename);

/**
 * Create an edit session with a gap buffer for a file.
 *
 * @param filename Null-terminated C string containing the absolute path to the markdown file.
 * @return Pointer to a CEditSession handle on success, or NULL on error.
 */
CEditSession *createEditSession(const char *filename);

/**
 * Close an edit session and free all associated resources.
 *
 * @param session Pointer to the CEditSession to close. May be NULL (no-op).
 */
void closeEditSession(CEditSession *session);

/**
 * Handle text input (UTF-8).
 *
 * @param session Pointer to the CEditSession.
 * @param text Null-terminated UTF-8 string to insert at cursor.
 */
void handleTextInput(CEditSession *session, const char *text);

/**
 * Handle non-text key events (arrows, delete, shortcuts).
 *
 * @param session Pointer to the CEditSession.
 * @param key_code macOS virtual key code.
 * @param modifiers NSEvent modifier flags bitmask.
 */
void handleKeyEvent(CEditSession *session, uint16_t key_code, uint64_t modifiers);

/**
 * Set the cursor position by byte offset in the UTF-8 text buffer.
 *
 * @param session Pointer to the CEditSession.
 * @param byte_offset Byte offset in the document text.
 */
void setCursorByteOffset(CEditSession *session, size_t byte_offset);

// ============================================================================
// Metal Renderer
// ============================================================================

/**
 * Initialize the Metal renderer.
 *
 * @param mtk_view Pointer to an MTKView instance (passed as void* from Swift).
 *                 The renderer creates the MTLDevice and configures the view.
 * @return Opaque renderer handle on success, or NULL on failure.
 *         The caller must call surface_deinit() to free resources.
 */
void *surface_init(void *mtk_view);

/**
 * Render a frame with the given text string.
 *
 * @param renderer Opaque renderer handle from surface_init().
 * @param text UTF-8 text to render.
 * @param text_len Length of the text in bytes.
 * @param view_width Drawable width in pixels.
 * @param view_height Drawable height in pixels.
 */
void render_frame(void *renderer, const char *text, int text_len, float view_width, float view_height, int cursor_byte_offset);

/**
 * Hit-test a click point against the renderer's text layout.
 *
 * @param renderer Opaque renderer handle from surface_init().
 * @param text UTF-8 text currently displayed.
 * @param text_len Length of the text in bytes.
 * @param view_width Drawable width in pixels.
 * @param click_x Click X in pixels (drawable coordinate space).
 * @param click_y Click Y in pixels (drawable coordinate space).
 * @return Byte offset of the nearest character boundary, or 0 on error.
 */
int hit_test(void *renderer, const char *text, int text_len, float view_width, float click_x, float click_y);

/**
 * Destroy the Metal renderer and release all Metal resources.
 *
 * @param renderer Opaque renderer handle from surface_init(). May be NULL (no-op).
 */
void surface_deinit(void *renderer);

#endif /* CRANIUM_H */
