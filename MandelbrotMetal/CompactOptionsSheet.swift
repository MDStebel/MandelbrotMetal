//
//  CompactOptionsSheet.swift
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

// MARK: - Compact Options Sheet (iPhone)
struct CompactOptionsSheet: View {
    @Binding var currentPaletteName: String
    @Binding var showPalettePicker: Bool
    @Binding var autoIterations: Bool
    @Binding var iterations: Int
    @Binding var highQualityIdle: Bool
    @Binding var snapRes: ContentView.SnapshotRes
    
    let paletteOptions: [ContentView.PaletteOption]
    let applyPalette: (ContentView.PaletteOption) -> Void
    let onImportGradient: (PhotosPickerItem?) -> Void
    let onSave: () -> Void
    let onAbout: () -> Void
    let onHelp: () -> Void
    let onClose: () -> Void
    let onCustom: () -> Void

    @State private var localGradientItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: $iterations, in: 100...5000, step: 50) {
                        Text(autoIterations ? "Iterations: \(iterations) (auto)" : "Iterations: \(iterations)")
                    }
                    HStack {
                        Toggle("", isOn: $autoIterations)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                        Text("Auto Increase with Zoom")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Iterations")
                }

                Section {
                    HStack {
                        Label("High‑Quality while idle", systemImage: "sparkles")
                        Spacer()
                        Toggle("", isOn: $highQualityIdle)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("High‑Quality while idle")
                } header: {
                    Text("Quality")
                } footer: {
                    Text("When on, the app renders at higher quality whenever you’re not touching the screen.")
                }

                Section {
                    Button {
                        showPalettePicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "paintpalette")
                            Text("Choose Palette")
                            Spacer()
                            Text(currentPaletteName).foregroundStyle(.secondary)
                        }
                    }
                    PhotosPicker(selection: $localGradientItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                            Text("Import Gradient")
                        }
                    }
                    .onChange(of: localGradientItem) { _, item in
                        onImportGradient(item)
                    }
                } header: {
                    Text("Color")
                }

                Section {
                    Button {
                        onSave() // opens Capture sheet
                    } label: {
                        Label("Capture Image", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("Capture")
                }

                Section {
                    Button { onAbout() } label: { Label("About", systemImage: "info.circle") }
                    Button { onHelp() } label: { Label("Help", systemImage: "questionmark.circle") }
                } header: {
                    Text("Info")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }
}
