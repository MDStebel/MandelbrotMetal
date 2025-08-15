//
//  CaptureSheet.swift
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

// MARK: - Capture Sheet
struct CaptureSheet: View {
    @Binding var snapRes: SnapshotRes
    @Binding var customW: String
    @Binding var customH: String
    
    let onConfirm: () -> Void
    let onClose: () -> Void
    let onCustomTap: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Resolution")) {
                    ResolutionSelector(selection: $snapRes)
                    if snapRes == .custom {
                        HStack {
                            TextField("Width",  text: $customW).keyboardType(.numberPad)
                            Text("×")
                            TextField("Height", text: $customH).keyboardType(.numberPad)
                        }
                    } else {
                        Text(resolutionLabel).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        // Dismiss first to avoid presenting while a sheet is up
                        onClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onConfirm()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Image(systemName: "camera")
                            Text("Capture")
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Capture Image")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { onClose() } } }
        }
    }

    private var resolutionLabel: String {
        switch snapRes {
        case .canvas: return "\(customW) × \(customH)"
        case .r4k:    return "3840 × 2160"
        case .r6k:    return "5760 × 3240"
        case .r8k:    return "7680 × 4320"
        case .custom: return ""
        }
    }
}
