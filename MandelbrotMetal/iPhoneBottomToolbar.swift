//
//  iPhoneBottomToolbar.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/16/25.
//

import SwiftUI

/// Compact iPhone bottom toolbar with Bookmarks (left), Iteration slider (center), Palette (right),
/// and an overflow menu for Contrast/Reset/toggles.
struct iPhoneBottomToolbar: View {
    // Core bindings/state
    @Binding var iterations: Int
    let iterationRange: (min: Int, max: Int, def: Int)
    @Binding var contrast: Double
    @Binding var autoIterations: Bool
    @Binding var highQualityIdle: Bool

    // Actions
    var onAddBookmark: () -> Void
    var onSelectBookmark: (Bookmark) -> Void
    var onClearBookmarks: () -> Void
    var onOpenPalettePicker: () -> Void
    var onReset: () -> Void
    var onIterChanged: (Int) -> Void     // push to renderer immediately
    var onContrastChanged: (Double) -> Void // push to renderer immediately

    // Data
    var bookmarks: [Bookmark]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let showShortSlider = w > 320 // hide slider on ultra-narrow widths

            HStack(spacing: 12) {
                // Left: Bookmarks
                Menu("Bookmarks") {
                    Button("Add Current…", action: onAddBookmark)
                    if !bookmarks.isEmpty {
                        Divider()
                        ForEach(bookmarks) { bm in
                            Button(bm.name) { onSelectBookmark(bm) }
                        }
                        Divider()
                        Button("Clear All", role: .destructive, action: onClearBookmarks)
                    }
                }
                .font(.subheadline)

                // Center: Iteration slider (compact)
                if showShortSlider {
                    HStack(spacing: 6) {
                        Button {
                            stepIterations(-50)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)

                        Slider(
                            value: Binding(
                                get: { Double(iterations) },
                                set: { newVal in
                                    let clamped = clamp(Int(newVal.rounded()), iterationRange.min, iterationRange.max)
                                    iterations = clamped
                                    onIterChanged(clamped)
                                }
                            ),
                            in: Double(iterationRange.min)...Double(iterationRange.max),
                            step: 50
                        )
                        .frame(width: sliderWidth(for: w))
                        .accessibilityLabel("Iterations")

                        Button {
                            stepIterations(50)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.subheadline)
                }

                Spacer(minLength: 4)

                // Right: Palette + Overflow
                Button {
                    onOpenPalettePicker()
                } label: {
                    Label("Palette", systemImage: "paintpalette")
                        .labelStyle(.iconOnly)
                        .imageScale(.large)
                }
                .accessibilityLabel("Palette Picker")

                Menu {
                    // Contrast
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Contrast")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { contrast },
                                set: { newVal in
                                    contrast = newVal
                                    onContrastChanged(newVal)
                                }
                            ),
                            in: 0.5...1.5,
                            step: 0.01
                        )
                    }
                    .padding(.vertical, 4)

                    Divider()

                    Toggle("Auto Iterations", isOn: $autoIterations)
                    Toggle("High-Quality Idle", isOn: $highQualityIdle)

                    Divider()

                    Button("Reset View", role: .none, action: onReset)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
                .accessibilityLabel("More Options")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 44) // toolbar height
    }

    private func stepIterations(_ delta: Int) {
        let v = clamp(iterations + delta, iterationRange.min, iterationRange.max)
        iterations = v
        onIterChanged(v)
    }

    private func sliderWidth(for w: CGFloat) -> CGFloat {
        // Keeps things readable but compact
        min(max(w * 0.36, 160), 260)
    }

    private func clamp<T: Comparable>(_ x: T, _ a: T, _ b: T) -> T { min(max(x, a), b) }
}
