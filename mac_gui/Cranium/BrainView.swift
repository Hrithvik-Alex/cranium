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
    @State private var fileManager: FileManager = FileManager()
    
    var body: some View {
        Text("HI")
        NavigationStack {
            if let file = fileManager.currentFile {
                FileView(fileName: file)
            } else {
                NoFileOpenedView()
            }
        }
        .environment(fileManager)
    }
}

@Observable
class FileManager {
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
