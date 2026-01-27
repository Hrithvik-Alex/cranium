# Cranium - Agent Guidelines

Cranium is a native macOS markdown editor with a Zig backend and Swift/SwiftUI frontend.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              macOS Application                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                        Swift / SwiftUI Frontend                       │  │
│  │                           (mac_gui/Cranium/)                          │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │ ContentView │  │  FileView   │  │ BrainView   │  │FileTreeView │  │  │
│  │  │   .swift    │  │   .swift    │  │  .swift     │  │   .swift    │  │  │
│  │  └─────────────┘  └──────┬──────┘  └─────────────┘  └─────────────┘  │  │
│  │                          │                                           │  │
│  │                          │ Calls C functions via                     │  │
│  │                          │ Bridging Header                           │  │
│  │                          ▼                                           │  │
│  │              ┌───────────────────────┐                               │  │
│  │              │ Cranium-Bridging-     │                               │  │
│  │              │ Header.h              │                               │  │
│  │              │ (imports cranium.h)   │                               │  │
│  │              └───────────┬───────────┘                               │  │
│  └──────────────────────────┼───────────────────────────────────────────┘  │
│                             │                                               │
│                             │ C ABI                                         │
│                             ▼                                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                      Zig Static Library (libcranium.a)                │  │
│  │                             (backend/)                                │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    md_file_interop.zig                          │  │  │
│  │  │               (C ABI exports: openDocument, etc.)               │  │  │
│  │  └────────────────────────┬────────────────────────────────────────┘  │  │
│  │                           │                                           │  │
│  │           ┌───────────────┼───────────────┐                           │  │
│  │           ▼               ▼               ▼                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                   │  │
│  │  │ md_parser   │  │ gap_buffer  │  │   (future   │                   │  │
│  │  │    .zig     │  │    .zig     │  │   modules)  │                   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                   │  │
│  │                                                                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Swift ↔ Zig Interop

The Swift frontend communicates with the Zig backend through a C ABI interface:

```
┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐
│   Swift Code     │         │   C Header       │         │    Zig Code      │
│                  │         │                  │         │                  │
│ openDocument()  ─┼────────▶│  cranium.h      ─┼────────▶│ export fn        │
│ closeDocument() ─┼────────▶│  - CBlock        │         │ openDocument()   │
│ createEditSession│         │  - CDocument     │         │ callconv(.c)     │
│ insertText()     │         │  - CEditState    │         │                  │
│ etc.             │         │  - CEditSession  │         │                  │
└──────────────────┘         └──────────────────┘         └──────────────────┘
```

### Key Interop Patterns

1. **Function Export**: Zig functions use `export fn` with `callconv(.c)` to be callable from C/Swift
2. **Memory Management**: Zig allocates memory via arena allocators; Swift calls `closeDocument()` / `closeEditSession()` to free
3. **String Handling**: C strings (null-terminated `[*:0]const u8`) are used at the boundary
4. **Opaque Pointers**: Internal Zig state is passed as `?*anyopaque` to hide implementation details

### C Structures

Defined in `include/cranium.h` and mirrored in `md_file_interop.zig`:

- **CBlock**: AST node representing markdown elements (paragraphs, headings, etc.)
- **CDocument**: Document handle with parsed AST root and arena pointer
- **CEditState**: Current editing state (cursor position, line info, parsed document)
- **CEditSession**: Edit session handle managing gap buffer and document state

## Backend Modules

| Module | Purpose |
|--------|---------|
| `md_parser.zig` | Markdown parser that produces an AST of Block nodes |
| `gap_buffer.zig` | Gap buffer data structure for efficient text editing |
| `md_file_interop.zig` | C ABI layer exporting functions for Swift consumption |
| `root.zig` | Module re-exports and test runner |

## Data Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  .md File   │────▶│  Gap Buffer │────▶│  MD Parser  │────▶│  CBlock AST │
│             │     │  (editing)  │     │             │     │  (for UI)   │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                          │                                       │
                          │         On each edit:                 │
                          │         1. Update gap buffer          │
                          │         2. Re-parse to AST            │
                          │         3. Convert to CBlock tree     │
                          │         4. Swift UI re-renders        │
                          ▼                                       ▼
                    ┌─────────────┐                         ┌─────────────┐
                    │   saveFile  │                         │  SwiftUI    │
                    │   (writes)  │                         │  Rendering  │
                    └─────────────┘                         └─────────────┘
```

## Build Instructions

### Prerequisites

- Zig compiler (0.13+)
- Xcode (for macOS GUI)

### Step 1: Build the Zig Static Library

```bash
# From the repo root
zig build lib
```

This produces:
- `zig-out/lib/libcranium.a` (ARM64 for Apple Silicon)
- `zig-out/lib/libcranium_x86_64.a` (Intel)
- `zig-out/include/cranium.h`

### Step 2: Build the macOS App

```bash
# Using Xcode GUI:
# Open mac_gui/Cranium.xcodeproj and build (Cmd+B)

# Or via command line:
xcodebuild -project mac_gui/Cranium.xcodeproj -scheme Cranium -configuration Debug build
```

### Running Tests

```bash
# Run all Zig tests
zig build test
```

### Full Build (Library + App)

```bash
zig build lib && xcodebuild -project mac_gui/Cranium.xcodeproj -scheme Cranium build
```

## Project Structure

```
cranium/
├── backend/                    # Zig source code
│   ├── main.zig               # CLI entry point (for testing)
│   ├── root.zig               # Module re-exports
│   ├── md_parser.zig          # Markdown parser
│   ├── md_file_interop.zig    # C ABI interop layer
│   └── gap_buffer.zig         # Gap buffer for editing
├── include/
│   └── cranium.h              # C header for Swift bridging
├── mac_gui/
│   └── Cranium/               # Swift/SwiftUI app
│       ├── CraniumApp.swift   # App entry point
│       ├── ContentView.swift  # Root view
│       ├── FileView.swift     # Editor view + ViewModels
│       ├── BrainView.swift    # Main workspace view
│       ├── FileTreeView.swift # File browser sidebar
│       └── Cranium-Bridging-Header.h
├── build.zig                  # Zig build configuration
└── build.zig.zon              # Zig package manifest
```

## Code Style Guidelines

### Zig

- Use `snake_case` for functions and variables
- Use `PascalCase` for types
- Prefer arena allocators for grouped allocations
- Export functions use `export fn` with `callconv(.c)`
- Error handling: return null from exported functions on error

### Swift

- Use `@Observable` for view models
- ViewModels manage Zig pointer lifecycle (call close functions in `deinit`)
- Use extensions on `UnsafeMutablePointer<CBlock>` for ergonomic Swift access
- Handle security-scoped bookmarks for sandboxed file access

## Adding New Features

### Adding a new C-exported function:

1. Add the Zig implementation in `md_file_interop.zig` with `export fn` and `callconv(.c)`
2. Add the function declaration to `include/cranium.h`
3. Call the function from Swift (it's automatically available via the bridging header)

### Adding a new block type:

1. Add the variant to `BlockTypeTag` enum in `md_parser.zig`
2. Add matching case to `BlockTypeTag` enum in `cranium.h`
3. Update the parser logic in `md_parser.zig`
4. Add rendering case in `FileView.swift` (`BlockTreeView` and `EditableBlockTreeView`)
