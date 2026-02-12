//
//  FileView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI
import AppKit
import MetalKit

@Observable
class FileViewModel {
    /// Pointer to the CEditSession handle from the Zig editor
    /// nil if no file has been opened or opening failed
    private var editSession: UnsafeMutablePointer<CEditSession>?

    /// Metal renderer pointer and view reference for hit testing
    var rendererPtr: UnsafeMutableRawPointer?
    weak var metalView: MTKView?

    /// Error message if parsing failed
    var errorMessage: String?
    /// Increments on edits to trigger SwiftUI refresh
    var revision: Int = 0
    /// Current UTF-8 text from Zig
    var currentText: String = ""
    
    /// Get the root block from the document (if available)
    var documentBlock: UnsafeMutablePointer<CBlock>? {
        editSession?.pointee.root_block
    }

    /// Get the active block id for edit-line rendering
    var activeBlockId: Int {
        Int(editSession?.pointee.active_block_id ?? 0)
    }

    /// Current cursor metrics from Zig
    var cursorMetrics: CCursorMetrics? {
        editSession?.pointee.cursor_metrics
    }

    /// Editor font from Zig
    var editorFont: EditorFont? {
        guard let font = editSession?.pointee.font else { return nil }
        return EditorFont(from: font)
    }

    /// Current cursor byte offset from Zig
    var cursorByteOffset: Int = 0
    
    /// Open and parse a markdown file
    /// - Parameter filePath: Absolute path to the markdown file
    func openFile(_ filePath: String) {
        // Close any previously opened document first
        closeFile()
        
        // Reset error state
        errorMessage = nil
        
        // Standardize the path (resolve . and ..)
        let standardizedPath = (filePath as NSString).standardizingPath
        
        // Check if file exists first
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            errorMessage = "File not found: \(standardizedPath)"
            return
        }
        
        // Check if it's a readable file
        guard FileManager.default.isReadableFile(atPath: standardizedPath) else {
            errorMessage = "Cannot read file: \(standardizedPath)"
            return
        }
        
        // openDocument expects a null-terminated C string with absolute path
        editSession = standardizedPath.withCString { cString in
            createEditSession(cString)
        }
        
        if editSession == nil {
            errorMessage = "Failed to open editor session"
        } else {
            refreshText()
        }
    }
    
    /// Close the current document and free all associated resources
    func closeFile() {
        if editSession != nil {
            closeEditSession(editSession)
            editSession = nil
        }
        currentText = ""
        errorMessage = nil
    }
    
    /// Check if we have a valid parsed document
    var hasDocument: Bool {
        editSession != nil && documentBlock != nil
    }
    
    deinit {
        closeFile()
    }

    func sendKeyEvent(_ event: NSEvent) {
        guard let session = editSession else { return }
        handleKeyEvent(session, event.keyCode, UInt64(event.modifierFlags.rawValue))
        refreshText()
    }

    func sendInsertText(_ text: String) {
        guard let session = editSession else { return }
        text.withCString { cString in
            handleTextInput(session, cString)
        }
        refreshText()
    }

    func sendCursorByteOffset(_ offset: Int) {
        guard let session = editSession else { return }
        setCursorByteOffset(session, offset)
        cursorByteOffset = Int(session.pointee.cursor_byte_offset)
    }

    private func refreshText() {
        guard let session = editSession else { return }
        let length = session.pointee.text_len
        guard let ptr = session.pointee.text_ptr, length > 0 else {
            currentText = ""
            cursorByteOffset = 0
            return
        }
        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: Int(length))
        currentText = String(decoding: buffer, as: UTF8.self)
        cursorByteOffset = Int(session.pointee.cursor_byte_offset)
    }
}

// MARK: - CBlock Swift Helpers

extension UnsafeMutablePointer where Pointee == CBlock {
    /// Get the block type as a Swift-friendly enum value
    var blockType: BlockTypeTag {
        pointee.block_type
    }
    
    /// Get the block type's associated value (heading level, list depth, etc.)
    var blockTypeValue: Int {
        Int(pointee.block_type_value)
    }
    
    /// Get the content as a Swift String (if present)
    var content: String? {
        guard let ptr = pointee.content_ptr, pointee.content_len > 0 else {
            return nil
        }
        // Rebind from CChar (Int8) to UInt8 for String decoding
        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: pointee.content_len)
        return String(decoding: buffer, as: UTF8.self)
    }
    
    /// Get the URL string for Link/Image blocks
    var urlString: String? {
        guard let ptr = pointee.block_type_str_ptr, pointee.block_type_str_len > 0 else {
            return nil
        }
        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: pointee.block_type_str_len)
        return String(decoding: buffer, as: UTF8.self)
    }
    
    /// Get child blocks as a Swift array
    var children: [UnsafeMutablePointer<CBlock>] {
        guard let ptr = pointee.children_ptr, pointee.children_len > 0 else {
            return []
        }
        // ptr[$0] returns an optional pointer, so we compactMap to unwrap
        return (0..<Int(pointee.children_len)).compactMap { ptr[$0] }
    }

    /// Get the unique block id
    var blockId: Int {
        Int(pointee.block_id)
    }
}

struct EditorFont {
    let family: String
    let size: CGFloat
    let weight: Font.Weight
    let isMonospaced: Bool

    init?(from cFont: CEditorFont) {
        guard let ptr = cFont.family_ptr, cFont.family_len > 0 else {
            return nil
        }
        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: uint8Ptr, count: Int(cFont.family_len))
        self.family = String(decoding: buffer, as: UTF8.self)
        self.size = CGFloat(cFont.size)
        self.weight = EditorFont.weightFromValue(cFont.weight)
        self.isMonospaced = cFont.is_monospaced != 0
    }

    func bodyFont() -> Font {
        Font.custom(family, size: size).weight(weight)
    }

    func headingFont(level: Int) -> Font {
        let sizes: [CGFloat] = [28, 24, 20, 18, 16, 14]
        let idx = max(0, min(level - 1, sizes.count - 1))
        return Font.custom(family, size: sizes[idx]).weight(.bold)
    }

    func codeFont() -> Font {
        if isMonospaced {
            return Font.custom(family, size: size)
        }
        return .system(.body, design: .monospaced)
    }

    private static func weightFromValue(_ value: Float) -> Font.Weight {
        switch value {
        case 0..<300: return .light
        case 300..<500: return .regular
        case 500..<700: return .semibold
        default: return .bold
        }
    }
}

final class EditorTextView: NSTextView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onInsertText: ((String) -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
        if event.modifierFlags.contains(.command) {
            return
        }
        interpretKeyEvents([event])
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let string = insertString as? String {
            onInsertText?(string)
        }
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            onInsertText?("\n")
            return
        }
        // Swallow other default text system commands; Zig handles them.
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseDown?(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel = onScrollWheel {
            onScrollWheel(event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

struct EditorInputView: NSViewRepresentable {
    var font: EditorFont?
    var text: String
    var onKeyEvent: (NSEvent) -> Void
    var onInsertText: (String) -> Void
    var onMouseDown: (NSPoint, NSView) -> Void
    var onScrollWheel: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let textView = EditorTextView(frame: .zero)

        textView.isEditable = true
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .clear
        textView.textColor = .clear
        textView.focusRingType = .none
        textView.allowsUndo = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true

        textView.onKeyEvent = onKeyEvent
        textView.onInsertText = onInsertText
        textView.onMouseDown = { point in
            onMouseDown(point, textView)
        }
        textView.onScrollWheel = onScrollWheel

        textView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.textView = textView
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if let font = font, let nsFont = NSFont(name: font.family, size: font.size) {
            textView.font = nsFont
        }
        if textView.string != text {
            textView.string = text
        }
        if let container = textView.textContainer {
            container.size = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        }
        if textView.window?.firstResponder != textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var textView: EditorTextView?
    }
}

struct CursorView: View {
    var cursor: CCursorMetrics
    var color: Color = .primary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let isVisible = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 1.5, height: CGFloat(cursor.line_height))
                .opacity(isVisible ? 1 : 0)
                .offset(x: CGFloat(cursor.caret_x), y: CGFloat(cursor.caret_y))
        }
    }
}

struct FileView: View {
    var fileName: String
    var baseDirectory: String
    @State private var viewModel = FileViewModel()

    var body: some View {
        VStack {
            Text("\(fileName)")
                .font(.headline)
                .padding()

            Spacer()
            
            if viewModel.hasDocument {
                ZStack(alignment: .topLeading) {
                    MetalSurfaceView(
                        text: viewModel.currentText,
                        cursorByteOffset: viewModel.cursorByteOffset,
                        onRendererReady: { renderer, metalView in
                            viewModel.rendererPtr = renderer
                            viewModel.metalView = metalView
                        }
                    )

                    EditorInputView(
                        font: viewModel.editorFont,
                        text: viewModel.currentText,
                        onKeyEvent: { event in
                            handleKeyEvent(viewModel: viewModel, event: event)
                        },
                        onInsertText: { text in
                            handleInsertText(viewModel: viewModel, text: text)
                        },
                        onMouseDown: { point, sourceView in
                            handleMouseClick(viewModel: viewModel, point: point, in: sourceView)
                        },
                        onScrollWheel: { event in
                            handleScrollWheel(viewModel: viewModel, event: event)
                        }
                    )
                    .background(Color.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Error")
                        .font(.headline)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView("Loading...")
            }
            
            Spacer()
        }
        .onAppear {
            loadFile()
        }
        .onChange(of: fileName) { _, _ in
            loadFile()
        }
    }
    
    private func loadFile() {
        let fullPath: String
        
        if let directoryURL = resolveSecurityScopedBookmark() {
            guard directoryURL.startAccessingSecurityScopedResource() else {
                viewModel.errorMessage = "Failed to access folder (sandbox permission denied)"
                return
            }
            fullPath = directoryURL.appendingPathComponent(fileName).path
        } else {
            fullPath = (baseDirectory as NSString).appendingPathComponent(fileName)
        }
        
        viewModel.openFile(fullPath)
    }

    private func handleKeyEvent(viewModel: FileViewModel, event: NSEvent) {
        viewModel.sendKeyEvent(event)
    }

    private func handleInsertText(viewModel: FileViewModel, text: String) {
        viewModel.sendInsertText(text)
    }

    private func handleScrollWheel(viewModel: FileViewModel, event: NSEvent) {
        guard let renderer = viewModel.rendererPtr,
              let metalView = viewModel.metalView else { return }

        let scale = metalView.window?.backingScaleFactor ?? 2.0
        // Positive scrollingDeltaY = scroll up = decrease scroll offset, so negate
        let scaledDelta = Float(-event.scrollingDeltaY * scale)
        update_scroll(renderer, scaledDelta)
    }

    private func handleMouseClick(viewModel: FileViewModel, point: NSPoint, in sourceView: NSView) {
        guard let renderer = viewModel.rendererPtr,
              let metalView = viewModel.metalView else { return }

        // Convert click point from the source NSView to the MTKView's coordinate system
        let metalPoint = sourceView.convert(point, to: metalView)

        // Scale from NSView points to drawable pixels and flip Y (NSView is bottom-left, Metal layout is top-left)
        let scale = metalView.window?.backingScaleFactor ?? 2.0
        let clickX = Float(metalPoint.x * scale)
        let clickY = Float((metalView.bounds.height - metalPoint.y) * scale)
        let viewWidth = Float(metalView.drawableSize.width)

        let byteOffset = viewModel.currentText.withCString { cstr in
            hit_test(
                renderer,
                cstr,
                Int32(viewModel.currentText.utf8.count),
                viewWidth,
                clickX,
                clickY
            )
        }

        viewModel.sendCursorByteOffset(Int(byteOffset))
    }
}

/// Recursively renders the CBlock tree
struct BlockTreeView: View {
    let block: UnsafeMutablePointer<CBlock>
    let depth: Int
    let activeBlockId: Int
    let editorFont: EditorFont?
    
    /// Block types that handle their own children rendering
    var handlesOwnChildren: Bool {
        switch block.blockType {
        case BlockType_BlockQuote,
             BlockType_OrderedList,
             BlockType_UnorderedList,
             BlockType_OrderedListItem,
             BlockType_UnorderedListItem,
             BlockType_CodeBlock,
             BlockType_Paragraph,  // Paragraphs with inline children
             BlockType_Heading:    // Headings with inline children
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Render this block's content based on type
            blockContent
            
            // Only render children here if the block doesn't handle its own children
            if !handlesOwnChildren {
                ForEach(0..<block.children.count, id: \.self) { index in
                    BlockTreeView(
                        block: block.children[index],
                        depth: depth + 1,
                        activeBlockId: activeBlockId,
                        editorFont: editorFont
                    )
                }
            }
        }
        .font(editorFont?.bodyFont())
    }
    
    @ViewBuilder
    var blockContent: some View {
        switch block.blockType {
        case BlockType_Document:
            EmptyView()
            
        case BlockType_Heading:
            // After inline parsing, heading content is in children (RawStr, Strong, etc.)
            // We need to strip the ## marker from the first child
            let isEditing = block.blockId == activeBlockId
            if isEditing, let text = block.content {
                Text(text)
                    .font(headingFont(level: block.blockTypeValue))
                    .fontWeight(.bold)
            } else if isEditing, !block.children.isEmpty {
                InlineTextView(block: block, preserveMarkers: true)
                    .font(headingFont(level: block.blockTypeValue))
                    .fontWeight(.bold)
            } else if !block.children.isEmpty {
                InlineTextView(block: block, stripMarker: stripHeadingMarker)
                    .font(headingFont(level: block.blockTypeValue))
                    .fontWeight(.bold)
            } else if let text = block.content {
                // Fallback if no children
                let cleanText = stripHeadingMarker(text)
                Text(cleanText)
                    .font(headingFont(level: block.blockTypeValue))
                    .fontWeight(.bold)
            }
            
        case BlockType_Paragraph:
            // After inline parsing, paragraph content is in children
            let isEditing = block.blockId == activeBlockId
            if isEditing, let text = block.content {
                Text(text)
            } else if isEditing, !block.children.isEmpty {
                InlineTextView(block: block, preserveMarkers: true)
            } else if !block.children.isEmpty {
                // Render inline children, stripping list markers from first child
                InlineTextView(block: block, stripMarker: stripListMarker)
            } else if let text = block.content {
                // Fallback if no children
                Text(stripListMarker(text))
            }
            
        case BlockType_CodeBlock:
            // Code blocks have children that contain the actual code
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<block.children.count, id: \.self) { index in
                    if let text = block.children[index].content {
                        // Strip block quote markers from each line (for code inside blockquotes)
                        let cleanText = stripBlockQuoteMarkers(text)
                        Text(cleanText)
                    }
                }
            }
            .font(editorFont?.codeFont() ?? .system(.body, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(4)
            
        case BlockType_BlockQuote:
            HStack(alignment: .top) {
                Rectangle()
                    .fill(Color.blue.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<block.children.count, id: \.self) { index in
                        BlockTreeView(
                            block: block.children[index],
                            depth: depth + 1,
                            activeBlockId: activeBlockId,
                            editorFont: editorFont
                        )
                    }
                }
            }
            .padding(.leading, 8)
            
        case BlockType_OrderedList:
            // Render children (list items) with numbers
            let orderedChildren = block.children
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(orderedChildren.enumerated()), id: \.offset) { index, child in
                    OrderedListItemView(
                        block: child,
                        number: index + 1,
                        depth: depth + 1,
                        activeBlockId: activeBlockId,
                        editorFont: editorFont
                    )
                }
            }
            
        case BlockType_UnorderedList:
            // Render children (list items) with bullets
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<block.children.count, id: \.self) { index in
                    BlockTreeView(
                        block: block.children[index],
                        depth: depth + 1,
                        activeBlockId: activeBlockId,
                        editorFont: editorFont
                    )
                }
            }
            
        case BlockType_OrderedListItem:
            // This case is handled by OrderedListItemView when rendered from OrderedList
            // Fallback for direct rendering (shouldn't happen normally)
            HStack(alignment: .top, spacing: 4) {
                Text("?.")
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<block.children.count, id: \.self) { index in
                        BlockTreeView(
                            block: block.children[index],
                            depth: depth + 1,
                            activeBlockId: activeBlockId,
                            editorFont: editorFont
                        )
                    }
                }
            }
            
        case BlockType_UnorderedListItem:
            // List items contain children (usually paragraphs)
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<block.children.count, id: \.self) { index in
                        BlockTreeView(
                            block: block.children[index],
                            depth: depth + 1,
                            activeBlockId: activeBlockId,
                            editorFont: editorFont
                        )
                    }
                }
            }
            
        case BlockType_RawStr:
            if let text = block.content {
                Text(text)
            }
            
        case BlockType_Strong:
            if let text = block.content {
                Text(text).fontWeight(.bold)
            }
            
        case BlockType_Emphasis:
            if let text = block.content {
                Text(text).italic()
            }
            
        case BlockType_StrongEmph:
            if let text = block.content {
                Text(text).fontWeight(.bold).italic()
            }
            
        case BlockType_Link:
            if let text = block.content, let url = block.urlString {
                Link(text, destination: URL(string: url) ?? URL(string: "about:blank")!)
            }
            
        case BlockType_Image:
            if let url = block.urlString {
                AsyncImage(url: URL(string: url)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                }
                .frame(maxHeight: 200)
            }
            
        default:
            if let text = block.content {
                Text(text)
            }
        }
    }
    
    /// Strip heading markers (## ) from the beginning of a heading line
    func stripHeadingMarker(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        // Remove leading # characters
        while result.hasPrefix("#") {
            result = String(result.dropFirst())
        }
        // Remove the space after the #s
        return result.trimmingCharacters(in: .whitespaces)
    }
    
    /// Strip list markers (- , * , 1. ) from the beginning of a list item line
    /// Also strips block quote markers (>) from all lines in multi-line content
    /// Note: Only strips leading markers, preserves trailing whitespace for inline content
    func stripListMarker(_ text: String) -> String {
        // Handle multi-line content - strip block quote markers from each line
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let processedLines = lines.enumerated().map { (index, line) -> String in
            var result = String(line)
            
            // Strip block quote markers from all lines
            while result.hasPrefix("> ") || result.hasPrefix(">") {
                if result.hasPrefix("> ") {
                    result = String(result.dropFirst(2))
                } else {
                    result = String(result.dropFirst())
                }
            }
            
            // Only strip list markers from the first line
            if index == 0 {
                // Remove leading whitespace only (not trailing!)
                while result.hasPrefix(" ") || result.hasPrefix("\t") {
                    result = String(result.dropFirst())
                }
                
                // Check for unordered list markers: -, *, +
                if result.hasPrefix("- ") || result.hasPrefix("* ") || result.hasPrefix("+ ") {
                    result = String(result.dropFirst(2))
                    // Strip leading whitespace from after the marker
                    while result.hasPrefix(" ") || result.hasPrefix("\t") {
                        result = String(result.dropFirst())
                    }
                    return result
                }
                
                // Check for ordered list markers: 1. 2. etc.
                if let dotIndex = result.firstIndex(of: ".") {
                    let prefix = result[..<dotIndex]
                    if prefix.allSatisfy({ $0.isNumber }) {
                        let afterDot = result.index(after: dotIndex)
                        if afterDot < result.endIndex {
                            result = String(result[afterDot...])
                            // Strip leading whitespace from after the marker
                            while result.hasPrefix(" ") || result.hasPrefix("\t") {
                                result = String(result.dropFirst())
                            }
                            return result
                        }
                    }
                }
            }
            
            return result
        }
        
        return processedLines.joined(separator: "\n")
    }
    
    /// Strip block quote markers (>) from each line in the text
    /// Handles multi-line content like code inside block quotes
    func stripBlockQuoteMarkers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var result = String(line)
                // Strip all leading '>' and whitespace
                while result.hasPrefix("> ") || result.hasPrefix(">") {
                    if result.hasPrefix("> ") {
                        result = String(result.dropFirst(2))
                    } else {
                        result = String(result.dropFirst())
                    }
                }
                return result
            }
            .joined(separator: "\n")
    }
    
    func headingFont(level: Int) -> Font {
        if let font = editorFont {
            return font.headingFont(level: level)
        }
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        case 5: return .headline
        default: return .subheadline
        }
    }
}

/// Renders inline content (RawStr, Strong, Emphasis, etc.) as concatenated text
struct InlineTextView: View {
    let block: UnsafeMutablePointer<CBlock>
    /// Optional function to strip markers from the first text element
    var stripMarker: ((String) -> String)?
    /// Preserve raw markdown markers in content
    var preserveMarkers: Bool = false
    
    var body: some View {
        let children = block.children
        if children.isEmpty {
            Text("")
        } else {
            children.enumerated().reduce(Text("")) { result, item in
                let (index, child) = item
                // Apply marker stripping only to the first child
                let shouldStrip = (index == 0 && stripMarker != nil && !preserveMarkers)
                return result + textForInlineBlock(child, stripFirst: shouldStrip, preserveMarkers: preserveMarkers)
            }
        }
    }
    
    func textForInlineBlock(_ child: UnsafeMutablePointer<CBlock>, stripFirst: Bool, preserveMarkers: Bool) -> Text {
        var content = child.content ?? ""
        
        // Strip marker from first RawStr if needed (includes list markers and block quotes)
        if stripFirst && child.blockType == BlockType_RawStr, let strip = stripMarker {
            content = strip(content)
        } else if child.blockType == BlockType_RawStr && !preserveMarkers {
            // For non-first RawStr, still strip block quote markers from each line
            content = stripBlockQuoteMarkersFromContent(content)
        }
        
        switch child.blockType {
        case BlockType_RawStr:
            return Text(content)
        case BlockType_Strong:
            return Text(content).bold()
        case BlockType_Emphasis:
            return Text(content).italic()
        case BlockType_StrongEmph:
            return Text(content).bold().italic()
        case BlockType_Link:
            // Links in Text need special handling - just show as underlined for now
            return Text(content).underline().foregroundColor(.blue)
        default:
            return Text(content)
        }
    }
    
    /// Strip block quote markers (>) from each line in multi-line content
    private func stripBlockQuoteMarkersFromContent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var result = String(line)
                while result.hasPrefix("> ") || result.hasPrefix(">") {
                    if result.hasPrefix("> ") {
                        result = String(result.dropFirst(2))
                    } else {
                        result = String(result.dropFirst())
                    }
                }
                return result
            }
            .joined(separator: "\n")
    }
}

/// Renders an ordered list item with its number
struct OrderedListItemView: View {
    let block: UnsafeMutablePointer<CBlock>
    let number: Int
    let depth: Int
    let activeBlockId: Int
    let editorFont: EditorFont?
    
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(number).")
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<block.children.count, id: \.self) { index in
                    BlockTreeView(
                        block: block.children[index],
                        depth: depth + 1,
                        activeBlockId: activeBlockId,
                        editorFont: editorFont
                    )
                }
            }
        }
    }
}
