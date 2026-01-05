//
//  FileView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 12/7/25.
//

import SwiftUI

struct FileView: View {
    var fileName : String
    @State private var fileText: String = ""

    var body: some View {
        VStack {
            Text("\(fileName)")

            Spacer()
            
            Text(fileText).padding()
        }
        .onAppear {
            do {
                fileText = try String(contentsOfFile: fileName, encoding: .utf8)
            } catch {
                fileText = "Error reading file: \(error.localizedDescription)"
            }
        }
    }
}


