//
//  PalettePickerView.swift
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

struct PalettePickerView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    let selected: String
    let options: [ContentView.PaletteOption]
    let onSelect: (ContentView.PaletteOption) -> Void

    var body: some View {
        let cols: [GridItem] = (hSize == .compact)
            ? [GridItem(.adaptive(minimum: 120), spacing: 12)]
            : [GridItem(.adaptive(minimum: 160), spacing: 16)]
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(options) { opt in
                    PaletteSwatchButton(option: opt, selected: opt.name == selected) {
                        onSelect(opt)
                    }
                }
            }
            .padding()
        }
    }
}

// Extracted swatch view for simpler type-checking
struct PaletteSwatchButton: View {
    let option: ContentView.PaletteOption
    let selected: Bool
    let action: () -> Void

    private var gradientStops: [Gradient.Stop] {
        option.stops.map { stop in
            Gradient.Stop(color: Color(stop.1), location: stop.0)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(gradient: Gradient(stops: gradientStops), startPoint: .leading, endPoint: .trailing)
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.2), lineWidth: selected ? 2 : 1)
                        )
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                Text(option.name).font(.subheadline)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
