//
//  BrainView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI
import Observation

struct BrainView: View {
    var selectedFolderPath: String
    @State private var vaultManager: VaultManager = VaultManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var displayText: String = "Hello, World!"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FileTreeView(directoryPath: selectedFolderPath)
                .navigationTitle("Files")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack {
                MetalSurfaceView(text: displayText)
                TextField("Type here...", text: $displayText)
                    .textFieldStyle(.roundedBorder)
                    .padding()
            }
        }
        .environment(vaultManager)
    }
}

@Observable
class VaultManager {
    class Storage {
        @AppStorage("currentFile")  public var currentFile: String?
    }
    
    private let storage = Storage()
    
    public var currentFile: String? {
        didSet {
            storage.currentFile = currentFile
        }
    }
    
     init() {
        currentFile = storage.currentFile
    }

}
