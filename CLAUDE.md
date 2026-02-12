# Cranium - Agent Guidelines

Cranium is a native macOS markdown editor with a Zig backend and Swift/SwiftUI frontend. The Zig backend handles text editing, markdown parsing, font metrics, and GPU rendering via Metal. The Swift frontend provides the UI shell and bridges into the Zig library through a C ABI.

## Architecture

```
Swift/SwiftUI (mac_gui/Cranium/)
        │
        │  C ABI via Cranium-Bridging-Header.h → cranium.h
        ▼
Exports.zig ──── C-exported functions (export fn, callconv(.c))
        │
        ├── EditSession.zig ── editing state, cursor, reparse loop
        │       ├── Editor.zig ── text buffer (insert/delete)
        │       ├── MdParser.zig ── markdown → Block AST
        │       └── CoreTextFont.zig ── font metrics, CTLine
        │
        └── Metal.zig ── Metal GPU pipeline via ObjC runtime
                └── Renderer.zig ── pure layout/vertex math (no Metal)
                        └── CoreTextGlyphAtlas.zig ── glyph atlas rasterization
```

The data flow on each keystroke:
1. Swift calls a C-exported function (e.g. `handleTextInput`)
2. `EditSession` updates the text buffer via `Editor`
3. `EditSession.reparse()` re-parses the full text into a `Block` AST
4. The AST is converted to a `CBlock` tree and synced to the `CEditSession` struct
5. Swift reads the updated `CEditSession` fields and re-renders

For Metal rendering, Swift's `MTKViewDelegate.draw(in:)` calls `render_frame`, which runs layout → vertex generation → Metal draw calls entirely in Zig.

## Backend Files (backend/)

| File | Type | Purpose |
|---|---|---|
| `Exports.zig` | namespace | All `export fn` C ABI functions. Library root source file. |
| `EditSession.zig` | struct file | Editing session: owns arenas, editor, cursor, font cache, parsed AST. Methods: `create`, `close`, `insertText`, `deleteBackward`, `moveCursor*`, `reparse`, `saveFile`. |
| `Editor.zig` | struct file | Simple contiguous text buffer with `insert` and `delete_range`. |
| `MdParser.zig` | namespace | Markdown block + inline parser. Produces a tree of `Block` nodes. Contains `BlockType`, `BlockTypeTag`, `parseBlocks`, `parseInline`. |
| `Metal.zig` | struct file | Metal GPU layer. Owns device, command queue, pipelines, vertex buffers. Calls ObjC runtime directly via `objc_msgSend`. Methods: `init`, `render`, `hitTest`, `updateScroll`, `deinit`. |
| `Renderer.zig` | struct file | Pure rendering math (no Metal/ObjC). Text layout with word wrap, glyph vertex generation, cursor resolution, scroll clamping, hit testing. |
| `CoreTextFont.zig` | namespace | macOS CoreText font support. `EditorFont`, `FontCache`, heading font sizes, `createCTLine`, `getCaretX`. |
| `CoreTextGlyphAtlas.zig` | struct file | Rasterizes ASCII glyphs (32-126) into a texture atlas using CoreGraphics. Stores per-glyph metrics (advance, bearing, atlas coordinates). |
| `root.zig` | — | Module root for `zig build test`. Runs `refAllDecls`. |
| `main.zig` | — | CLI entry point (placeholder). |
| `shaders/glyph.metal` | MSL | Glyph rendering shader (textured quads with alpha blending). |
| `shaders/cursor.metal` | MSL | Cursor rendering shader (solid color quads with opacity). |
| `fonts/OpenSans-Regular.ttf` | asset | Embedded font for Metal text rendering. |

## Frontend Files (mac_gui/Cranium/)

| File | Purpose |
|---|---|
| `CraniumApp.swift` | App entry point, dark color scheme |
| `ContentView.swift` | Root view: shows InitView or BrainView |
| `InitView.swift` | Folder picker for vault selection |
| `BrainView.swift` | Main workspace: NavigationSplitView with sidebar + editor |
| `FileView.swift` | Editor view with `FileViewModel` managing `CEditSession` lifecycle |
| `MetalView.swift` | NSViewRepresentable wrapping MTKView, bridges to Zig Metal renderer |
| `FileTreeView.swift` | File browser sidebar with `FileNode` hierarchy |
| `NoFileOpenedView.swift` | Placeholder when no file is selected |
| `Cranium-Bridging-Header.h` | Imports `cranium.h` for Swift |

## Swift ↔ Zig Interop

The boundary uses a C ABI defined in `include/cranium.h` and implemented in `Exports.zig`.

Key patterns:
- **Function export**: Zig uses `export fn` with `callconv(.c)`
- **Memory management**: Zig allocates via arena allocators. Swift calls `closeDocument()` / `closeEditSession()` to free entire arenas at once.
- **String handling**: C strings (`[*:0]const u8`) at the boundary, Zig slices internally
- **Opaque pointers**: Internal Zig state is passed as `?*anyopaque` and cast back inside exported functions
- **Struct mirroring**: C-compatible structs (`CBlock`, `CEditSession`, `CCursorMetrics`) are defined in both `cranium.h` and `Exports.zig` with matching layouts

### ObjC Runtime from Zig

Metal.zig calls Metal/AppKit APIs directly via ObjC runtime functions:
- Declare `objc_msgSend`, `objc_getClass`, `sel_registerName` as `extern fn`
- Cast `objc_msgSend` via `@ptrFromInt(@intFromPtr(&objc_msgSend))` to get typed function pointers
- Do NOT use `linkSystemLibrary("objc")` — it breaks cross-compilation. ObjC symbols are resolved by Xcode's linker.
- `MTLCreateSystemDefaultDevice` can be declared directly as `extern fn`

## Build Instructions

### Prerequisites

- Zig 0.15+
- Xcode (for macOS app + CoreText/Metal frameworks)

### Build the Zig static library

```bash
zig build lib
```

Produces:
- `zig-out/lib/libcranium.a` (ARM64)
- `zig-out/lib/libcranium_x86_64.a` (Intel)
- `zig-out/include/cranium.h`

### Build the macOS app

```bash
# Via Xcode GUI: open mac_gui/Cranium.xcodeproj, Cmd+B

# Or command line:
xcodebuild -project mac_gui/Cranium.xcodeproj -scheme Cranium build
```

### Full build (library + app)

```bash
zig build lib && xcodebuild -project mac_gui/Cranium.xcodeproj -scheme Cranium build
```

### Run tests

```bash
zig build test
```

## Code Style

### Zig struct-file pattern

Every backend `.zig` file that revolves around a single struct should use the **struct-file pattern**:

- **PascalCase filenames** for all module files (e.g. `EditSession.zig`, `Renderer.zig`)
- Exceptions: `main.zig` and `root.zig` (Zig conventions)
- The file IS the struct: fields are declared at the top level, not inside a `pub const Foo = struct { ... }`
- Use `const Self = @This();` for self-references
- Methods take `self: *Self` or `self: *const Self` as the first parameter
- Associated types, constants, and helper functions live as `pub const` / `pub fn` / `fn` declarations on the file struct
- Files that are namespaces (like `Exports.zig`, `MdParser.zig`) don't need struct promotion — just PascalCase the filename

Example:
```zig
// Foo.zig
const std = @import("std");
const Self = @This();

pub const SomeAssociatedType = struct { ... };

// struct fields at top level
count: usize,
buffer: []u8,

// methods
pub fn init(buf: []u8) Self { ... }
pub fn process(self: *Self) void { ... }
```

### General

- **Modularize**: if a chunk of logic is standalone enough, put it in its own file rather than growing an existing file
- **DRY**: if logic is repeated line-by-line, extract a function
- **No over-engineering**: only build what's needed now. Don't add abstractions for hypothetical future use.
- Use `snake_case` for functions and variables, `PascalCase` for types
- Prefer arena allocators for grouped allocations that share a lifetime
- Export functions use `export fn` with `callconv(.c)` and return null on error

### Swift

- Use `@Observable` for view models
- ViewModels manage Zig pointer lifecycle (call close functions in `deinit`)
- Use extensions on `UnsafeMutablePointer<CBlock>` for ergonomic Swift access
- Handle security-scoped bookmarks for sandboxed file access

## Adding New Features

### Adding a new C-exported function

1. Implement the Zig function in the appropriate module (e.g. `EditSession.zig`)
2. Add the `export fn` wrapper in `Exports.zig` with `callconv(.c)`
3. Add the function declaration to `include/cranium.h`
4. Call from Swift (automatically available via bridging header)

### Adding a new markdown block type

1. Add the variant to `BlockTypeTag` enum in `MdParser.zig`
2. Add matching case to `BlockTypeTag` enum in `cranium.h`
3. Update parser logic in `MdParser.zig`
4. Add rendering case in `FileView.swift`
