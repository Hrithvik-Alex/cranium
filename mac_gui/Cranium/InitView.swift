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
                folderPath = url.path()
                
            case .failure(let error):
                print("folder selector error \(error)")
            }
        })
        .padding()
    }
}
