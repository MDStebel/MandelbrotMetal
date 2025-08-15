//
//  CompactOptionsSheet.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//

import SwiftUI

/// NOTE:
/// Bookmark and ContentView are defined elsewhere.
/// This file should ONLY declare the compact options sheet UI to avoid
/// type redeclaration and ambiguous symbol errors.

struct CompactOptionsSheet: View {
    // Hook up whatever bindings you need from the parent view.
    // Keeping it simple so the file compiles cleanly.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Options") {
                    Text("Add controls here…")
                }
            }
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    CompactOptionsSheet()
}
