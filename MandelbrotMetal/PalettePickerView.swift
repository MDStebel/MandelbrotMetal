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
    @State private var refreshID = UUID()
    let selected: String
    let options: [PaletteOption]
    let onSelect: (PaletteOption) -> Void

    var body: some View {
        let cols: [GridItem] = (hSize == .compact)
            ? [GridItem(.adaptive(minimum: 120), spacing: 12)]
            : [GridItem(.adaptive(minimum: 160), spacing: 16)]
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(PaletteFavorites.shared.sorted(options)) { opt in
                    PaletteSwatchButton(option: opt, selected: opt.name == selected, onFavoriteToggle: { refreshID = UUID() }) {
                        onSelect(opt)
                    }
                }
            }
            .id(refreshID)
            .padding()
        }
    }
}

// Extracted swatch view for simpler type-checking
struct PaletteSwatchButton: View {
    let option: PaletteOption
    let selected: Bool
    let action: () -> Void
    let onFavoriteToggle: () -> Void

    init(option: PaletteOption, selected: Bool, onFavoriteToggle: @escaping () -> Void = {}, action: @escaping () -> Void) {
        self.option = option
        self.selected = selected
        self.onFavoriteToggle = onFavoriteToggle
        self.action = action
    }

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
                HStack(alignment: .center, spacing: 8) {
                    Text(option.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: {
                        PaletteFavorites.shared.toggle(name: option.name)
                        onFavoriteToggle()
                    }) {
                        Image(systemName: PaletteFavorites.shared.isFavorite(name: option.name) ? "star.fill" : "star")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PaletteFavorites.shared.isFavorite(name: option.name) ? "Unfavorite" : "Favorite")
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
