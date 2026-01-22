//
//  FileTreeView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 1/22/26.
//

import SwiftUI

/// Represents a node in the file tree (either a folder or a file)
struct FileNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isFolder: Bool
    var children: [FileNode]
    
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.path == rhs.path
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

@Observable
class FileTreeModel {
    var rootNodes: [FileNode] = []
    var isLoading = false
    
    /// Build a tree structure from a flat list of file paths
    func buildTree(from files: [String]) {
        var nodeMap: [String: FileNode] = [:]
        var roots: [FileNode] = []
        
        // Sort files so folders are processed before their contents
        let sortedFiles = files.sorted()
        
        for filePath in sortedFiles {
            let components = filePath.split(separator: "/").map(String.init)
            var currentPath = ""
            var parentPath: String? = nil
            
            for (index, component) in components.enumerated() {
                let isLastComponent = (index == components.count - 1)
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                
                if nodeMap[currentPath] == nil {
                    let node = FileNode(
                        name: component,
                        path: currentPath,
                        isFolder: !isLastComponent,
                        children: []
                    )
                    nodeMap[currentPath] = node
                    
                    if let parent = parentPath, var parentNode = nodeMap[parent] {
                        parentNode.children.append(node)
                        nodeMap[parent] = parentNode
                    } else if parentPath == nil {
                        roots.append(node)
                    }
                }
                
                parentPath = currentPath
            }
        }
        
        // Sort children: folders first, then alphabetically
        func sortNode(_ node: inout FileNode) {
            node.children.sort { a, b in
                if a.isFolder != b.isFolder {
                    return a.isFolder
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            for i in node.children.indices {
                sortNode(&node.children[i])
            }
        }
        
        roots.sort { a, b in
            if a.isFolder != b.isFolder {
                return a.isFolder
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        
        for i in roots.indices {
            sortNode(&roots[i])
        }
        
        // Rebuild with sorted children
        rootNodes = roots
    }
    
    /// Load files from the vault directory
    func loadFiles(from directoryPath: String) {
        isLoading = true
        var files: [String] = []
        
        // Resolve the security-scoped bookmark to get access
        guard let directoryURL = resolveSecurityScopedBookmark() else {
            print("Failed to resolve bookmark, trying direct path")
            loadFilesFromPath(directoryPath, into: &files)
            buildTree(from: files)
            isLoading = false
            return
        }
        
        // Start accessing security-scoped resource
        guard directoryURL.startAccessingSecurityScopedResource() else {
            print("Failed to start accessing security-scoped resource")
            isLoading = false
            return
        }
        defer {
            directoryURL.stopAccessingSecurityScopedResource()
        }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("Failed to create enumerator for directory")
            isLoading = false
            return
        }
        
        let basePath = directoryURL.path
        for case let fileURL as URL in enumerator {
            let pathExtension = fileURL.pathExtension.lowercased()
            if pathExtension == "md" || pathExtension == "markdown" {
                let relativePath = fileURL.path.replacingOccurrences(of: basePath + "/", with: "")
                files.append(relativePath)
            }
        }
        
        buildTree(from: files)
        isLoading = false
    }
    
    private func loadFilesFromPath(_ path: String, into files: inout [String]) {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: path)
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for case let fileURL as URL in enumerator {
            let pathExtension = fileURL.pathExtension.lowercased()
            if pathExtension == "md" || pathExtension == "markdown" {
                let relativePath = fileURL.path.replacingOccurrences(of: path + "/", with: "")
                files.append(relativePath)
            }
        }
    }
}

struct FileTreeView: View {
    var directoryPath: String
    @Environment(VaultManager.self) var vaultManager
    @State private var model = FileTreeModel()
    @State private var showingNewFileSheet = false
    @State private var expandedFolders: Set<String> = []
    
    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rootNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No markdown files")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { vaultManager.currentFile },
                    set: { vaultManager.currentFile = $0 }
                )) {
                    ForEach(model.rootNodes) { node in
                        FileNodeView(
                            node: node,
                            expandedFolders: $expandedFolders,
                            selectedFile: Binding(
                                get: { vaultManager.currentFile },
                                set: { vaultManager.currentFile = $0 }
                            )
                        )
                    }
                }
                .listStyle(.sidebar)
            }
            
            Divider()
            
            // Bottom toolbar
            HStack {
                Button(action: { showingNewFileSheet = true }) {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New File")
                
                Spacer()
                
                Button(action: { model.loadFiles(from: directoryPath) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(8)
        }
        .onAppear {
            model.loadFiles(from: directoryPath)
        }
        .sheet(isPresented: $showingNewFileSheet) {
            NewFileCreationView(isPresented: $showingNewFileSheet) { fileName in
                showingNewFileSheet = false
                
                // Create the file using Zig backend
                let fullPath: String
                if let directoryURL = resolveSecurityScopedBookmark() {
                    guard directoryURL.startAccessingSecurityScopedResource() else { return }
                    defer { directoryURL.stopAccessingSecurityScopedResource() }
                    fullPath = directoryURL.appendingPathComponent(fileName).path
                } else {
                    fullPath = "\(directoryPath)/\(fileName)"
                }
                
                _ = fullPath.withCString { cString in
                    createFile(cString)
                }
                
                // Refresh and open the new file
                model.loadFiles(from: directoryPath)
                vaultManager.currentFile = fileName
            }
        }
    }
}

struct FileNodeView: View {
    let node: FileNode
    @Binding var expandedFolders: Set<String>
    @Binding var selectedFile: String?
    
    var isExpanded: Bool {
        expandedFolders.contains(node.path)
    }
    
    var body: some View {
        if node.isFolder {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedFolders.contains(node.path) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedFolders.insert(node.path)
                        } else {
                            expandedFolders.remove(node.path)
                        }
                    }
                )
            ) {
                ForEach(node.children) { child in
                    FileNodeView(
                        node: child,
                        expandedFolders: $expandedFolders,
                        selectedFile: $selectedFile
                    )
                }
            } label: {
                Label(node.name, systemImage: isExpanded ? "folder.fill" : "folder")
                    .foregroundColor(.primary)
            }
        } else {
            Button(action: {
                selectedFile = node.path
            }) {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
            .background(selectedFile == node.path ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(4)
        }
    }
}
