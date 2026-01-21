//
//  FileView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI

@Observable
class FileViewModel {
    /// Pointer to the root CBlock (Document) from the Zig parser
    /// nil if no file has been parsed or parsing failed
    var documentBlock: UnsafeMutablePointer<CBlock>?
    
    /// Error message if parsing failed
    var errorMessage: String?
    
    /// Parse a markdown file and store the resulting document block
    /// - Parameter filePath: Absolute path to the markdown file
    func parseFile(_ filePath: String) {
        // Reset state
        documentBlock = nil
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
        
        // getMarkdownBlocks expects a null-terminated C string with absolute path
        documentBlock = standardizedPath.withCString { cString in
            getMarkdownBlocks(cString)
        }
        
        if documentBlock == nil {
            errorMessage = "Failed to parse markdown file"
        }
    }
    
    /// Check if we have a valid parsed document
    var hasDocument: Bool {
        documentBlock != nil
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
            
            if let doc = viewModel.documentBlock {
                ScrollView {
                    BlockTreeView(block: doc, depth: 0)
                        .padding()
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
            // Resolve the security-scoped bookmark to get access
            if let directoryURL = resolveSecurityScopedBookmark() {
                // Start accessing security-scoped resource
                guard directoryURL.startAccessingSecurityScopedResource() else {
                    viewModel.errorMessage = "Failed to access folder (sandbox permission denied)"
                    return
                }
                
                // Combine base directory with filename to get full path
                let fullPath = directoryURL.appendingPathComponent(fileName).path
                viewModel.parseFile(fullPath)
                
                // Note: We don't stop accessing here because the Zig code needs ongoing access
                // to read the file. In a production app, you'd want better lifecycle management.
            } else {
                // Fallback to direct path
                let fullPath = (baseDirectory as NSString).appendingPathComponent(fileName)
                viewModel.parseFile(fullPath)
            }
        }
    }
}

/// Recursively renders the CBlock tree
struct BlockTreeView: View {
    let block: UnsafeMutablePointer<CBlock>
    let depth: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Render this block's content based on type
            blockContent
            
            // Render children
            ForEach(0..<block.children.count, id: \.self) { index in
                BlockTreeView(block: block.children[index], depth: depth + 1)
                    .padding(.leading, 16)
            }
        }
    }
    
    @ViewBuilder
    var blockContent: some View {
        switch block.blockType {
        case BlockType_Document:
            EmptyView()
            
        case BlockType_Heading:
            if let text = block.content {
                // Strip the leading #'s from the heading
                let cleanText = text.trimmingCharacters(in: .whitespaces)
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                Text(cleanText)
                    .font(headingFont(level: block.blockTypeValue))
                    .fontWeight(.bold)
            }
            
        case BlockType_Paragraph:
            if let text = block.content {
                Text(text)
            }
            
        case BlockType_CodeBlock:
            if let text = block.content {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
            
        case BlockType_BlockQuote:
            HStack {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 3)
                VStack(alignment: .leading) {
                    ForEach(0..<block.children.count, id: \.self) { index in
                        BlockTreeView(block: block.children[index], depth: depth + 1)
                    }
                }
            }
            .padding(.leading, 8)
            
        case BlockType_OrderedList, BlockType_UnorderedList:
            EmptyView() // Children will render the list items
            
        case BlockType_OrderedListItem:
            HStack(alignment: .top) {
                Text("•")
                if let text = block.content {
                    Text(text)
                }
            }
            
        case BlockType_UnorderedListItem:
            HStack(alignment: .top) {
                Text("•")
                if let text = block.content {
                    Text(text)
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
    
    func headingFont(level: Int) -> Font {
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


