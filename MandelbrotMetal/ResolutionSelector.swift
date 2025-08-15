//
//  ResolutionSelector.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//

import MetalKit
import PhotosUI
import Photos
import SwiftUI
import UIKit
import simd

// MARK: - Resolution Selector (Segmented)
struct ResolutionSelector: View {
    @Binding var selection: SnapshotRes

    var body: some View {
        Picker("Resolution", selection: $selection) {
            Text("Canvas").tag(SnapshotRes.canvas)
            Text("4K").tag(SnapshotRes.r4k)
            Text("6K").tag(SnapshotRes.r6k)
            Text("8K").tag(SnapshotRes.r8k)
            Text("Custom").tag(SnapshotRes.custom)
        }
        .pickerStyle(.segmented)
        .lineLimit(1)
        .minimumScaleFactor(0.95)
    }
}
