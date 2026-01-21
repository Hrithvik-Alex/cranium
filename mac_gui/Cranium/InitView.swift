//
//  InitView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct InitView: View {
    @Binding var folderPath: String?
    @State private var showFolderImporter = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Please select a folder to begin")
            
            Button("Select") {
                showFolderImporter = true
            }
        }
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.directory], onCompletion: { result in
            switch result {
            case .success(let url):
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    print("Failed to access security-scoped resource")
                    return
                }
                
                // Store the bookmark data for persistent access
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    // Store bookmark in UserDefaults
                    UserDefaults.standard.set(bookmarkData, forKey: "folderBookmark")
                    folderPath = url.path
                } catch {
                    print("Failed to create bookmark: \(error)")
                }
                
            case .failure(let error):
                print("folder selector error \(error)")
            }
        })
        .padding()
    }
}

/// Helper to resolve the stored bookmark and get access to the folder
func resolveSecurityScopedBookmark() -> URL? {
    guard let bookmarkData = UserDefaults.standard.data(forKey: "folderBookmark") else {
        return nil
    }
    
    do {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        if isStale {
            print("Bookmark is stale, may need to re-select folder")
        }
        
        return url
    } catch {
        print("Failed to resolve bookmark: \(error)")
        return nil
    }
}
