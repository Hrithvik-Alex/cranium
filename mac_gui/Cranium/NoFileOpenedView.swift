//
//  NoFileOpenedView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI

struct NoFileOpenedView : View {
    @State private var showingFileCreationSheet = false
    @State private var navigateToFile = false
    @Environment(FileManager.self) var fileManager
    
    var body: some View {
            VStack {
                Text("Please open a file to begin.")
                
                Spacer()
                
                HStack {
                    
                    Button("Create new File") {
                        showingFileCreationSheet = true
                    }
                    .sheet(isPresented: $showingFileCreationSheet) {
                        NewFileCreationView(isPresented: $showingFileCreationSheet) { fileName in
                            navigateToFile = true
                            showingFileCreationSheet = false
                            fileManager.currentFile = fileName
                        }
                    }
                    
                    //FileSearchView()
                }
            }
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
