//
//  NoFileOpenedView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI
import Foundation

struct NoFileOpenedView : View {
    @State private var showingFileCreationSheet = false
    @State private var navigateToFile = false
    @State private var files: [String] = []
    var fileDirectory: String
    @Environment(VaultManager.self) var vaultManager
    
    
    var body: some View {
        VStack {
            Text("Please open a file to begin.")
                .font(.headline)
                .padding()
            
            // List of existing files
            if files.isEmpty {
                Text("No markdown files found in this folder")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(files, id: \.self) { file in
                    Button(action: {
                        vaultManager.currentFile = file
                    }) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.blue)
                            Text(file)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Create new File") {
                    showingFileCreationSheet = true
                }
                .sheet(isPresented: $showingFileCreationSheet) {
                    NewFileCreationView(isPresented: $showingFileCreationSheet) { fileName in
                        navigateToFile = true
                        showingFileCreationSheet = false
                        vaultManager.currentFile = fileName
                        //TODO: replace with zig?
                        FileManager.default.createFile(atPath: "\(fileDirectory)/\(fileName)", contents: Data())
                    }
                }
                
                Button("Refresh") {
                    loadFiles()
                }
            }
            .padding()
        }
        .onAppear {
            loadFiles()
        }
    }
    
    /// Load markdown files from the directory
    private func loadFiles() {
        files = []
        let fileManager = FileManager.default
        
        // Resolve the security-scoped bookmark to get access
        guard let directoryURL = resolveSecurityScopedBookmark() else {
            print("Failed to resolve bookmark, trying direct path")
            // Fallback to direct path (may not work in sandbox)
            loadFilesFromPath(fileDirectory)
            return
        }
        
        // Start accessing security-scoped resource
        guard directoryURL.startAccessingSecurityScopedResource() else {
            print("Failed to start accessing security-scoped resource")
            return
        }
        defer {
            directoryURL.stopAccessingSecurityScopedResource()
        }
        
        print("Looking for files in: \(directoryURL.path)")
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("Failed to create enumerator for directory")
            return
        }
        
        let basePath = directoryURL.path
        for case let fileURL as URL in enumerator {
            // Only include markdown files
            let pathExtension = fileURL.pathExtension.lowercased()
            if pathExtension == "md" || pathExtension == "markdown" {
                // Get relative path from the base directory
                let relativePath = fileURL.path.replacingOccurrences(of: basePath + "/", with: "")
                files.append(relativePath)
                print("Found file: \(relativePath)")
            }
        }
        
        files.sort()
        print("Total files found: \(files.count)")
    }
    
    /// Fallback: load files from path without security scope
    private func loadFilesFromPath(_ path: String) {
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
        files.sort()
    }
}

struct NewFileCreationView: View {
    @Binding var isPresented: Bool
    @State private var fileName: String = ""
    
    var onSubmit: (String) -> Void
    
    var body: some View {
            
            Form {
                TextField("filename", text: $fileName)
            }
            .onSubmit {
                onSubmit(fileName)
            }
            
    }
}
