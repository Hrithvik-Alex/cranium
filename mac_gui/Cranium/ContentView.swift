//
//  ContentView.swift
//  Cranium
//
//  Created by Hrithvik  Alex on 11/6/25.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("folderPath") private var folderPath: String?
    var body: some View {
        switch folderPath {
        case .none:
            InitView(folderPath: $folderPath)
        case .some(let value):
            BrainView(selectedFolderPath: value)
        }
    }
}

#Preview {
    ContentView()
}
