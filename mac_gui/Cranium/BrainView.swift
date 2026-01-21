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
    
    var body: some View {
        Text("HI")
        NavigationStack {
            if let file = vaultManager.currentFile {
                FileView(fileName: file, baseDirectory: selectedFolderPath)
            } else {
                NoFileOpenedView(fileDirectory: selectedFolderPath)
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
