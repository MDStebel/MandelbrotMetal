//
//  PaletteOption.swift
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

// MARK: - Palette Models
struct PaletteOption: Identifiable {
    let id = UUID()
    let name: String
    let builtInIndex: Int?
    let stops: [(CGFloat, UIColor)]
}

// MARK: - Palette Catalog (data + helpers)
private struct PaletteItem {
    let name: String
    let builtInIndex: Int?
    let stopsHex: [(CGFloat, String)]
}

private func makeStopsFromHex(_ stopsHex: [(CGFloat, String)]) -> [(CGFloat, UIColor)] {
    stopsHex.map { (loc, hex) in (loc, UIColor(hex: hex)) }
}

/// Singleton catalog exposing curated palettes as `[PaletteOption]`.
final class PaletteCatalog {
    static let shared = PaletteCatalog()
    let all: [PaletteOption]

    private init() {
        let paletteData: [PaletteItem] = [
            // ——— Vivid / Artistic ———
            .init(
                name: "Neon",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#000000"
                    ),
                    (
                        0.08,
                        "#00FFC0"
                    ),
                    (
                        0.20,
                        "#00CCFF"
                    ),
                    (
                        0.35,
                        "#6733FF"
                    ),
                    (
                        0.55,
                        "#FF19E6"
                    ),
                    (
                        0.75,
                        "#FFD133"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Vibrant",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0D0526"
                    ),
                    (
                        0.15,
                        "#3300B3"
                    ),
                    (
                        0.35,
                        "#00A8FF"
                    ),
                    (
                        0.55,
                        "#00E665"
                    ),
                    (
                        0.75,
                        "#FFD000"
                    ),
                    (
                        1.00,
                        "#FF271A"
                    )
                ]
            ),
            .init(
                name: "Sunset Glow",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#140026"
                    ),
                    (
                        0.18,
                        "#660066"
                    ),
                    (
                        0.38,
                        "#D93666"
                    ),
                    (
                        0.60,
                        "#FF8A1A"
                    ),
                    (
                        0.82,
                        "#FFE066"
                    ),
                    (
                        1.00,
                        "#FFF7D9"
                    )
                ]
            ),
            .init(
                name: "Candy",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#1A0033"
                    ),
                    (
                        0.20,
                        "#E636BF"
                    ),
                    (
                        0.40,
                        "#FF6680"
                    ),
                    (
                        0.60,
                        "#FFB84D"
                    ),
                    (
                        0.80,
                        "#E6F26A"
                    ),
                    (
                        1.00,
                        "#CCFFF2"
                    )
                ]
            ),
            .init(
                name: "Aurora Borealis",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#000613"
                    ),
                    (
                        0.18,
                        "#00665A"
                    ),
                    (
                        0.36,
                        "#00CBB0"
                    ),
                    (
                        0.58,
                        "#59F2E6"
                    ),
                    (
                        0.78,
                        "#99D6FF"
                    ),
                    (
                        1.00,
                        "#EBF7FF"
                    )
                ]
            ),
            .init(
                name: "Cyberpunk",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0A0015"
                    ),
                    (
                        0.20,
                        "#1F008C"
                    ),
                    (
                        0.40,
                        "#8C00D9"
                    ),
                    (
                        0.60,
                        "#00E5EB"
                    ),
                    (
                        0.80,
                        "#FF3399"
                    ),
                    (
                        1.00,
                        "#FFF2E6"
                    )
                ]
            ),
            .init(
                name: "Lava",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#000000"
                    ),
                    (
                        0.18,
                        "#400000"
                    ),
                    (
                        0.38,
                        "#A50000"
                    ),
                    (
                        0.58,
                        "#FF4D00"
                    ),
                    (
                        0.78,
                        "#FFB800"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Peacock",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#061018"
                    ),
                    (
                        0.18,
                        "#004D40"
                    ),
                    (
                        0.38,
                        "#009688"
                    ),
                    (
                        0.58,
                        "#26C6DA"
                    ),
                    (
                        0.78,
                        "#7E57C2"
                    ),
                    (
                        1.00,
                        "#EDE7F6"
                    )
                ]
            ),
            .init(
                name: "Twilight",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00020A"
                    ),
                    (
                        0.25,
                        "#061A40"
                    ),
                    (
                        0.50,
                        "#0B4F6C"
                    ),
                    (
                        0.75,
                        "#145C9E"
                    ),
                    (
                        1.00,
                        "#E0F2FF"
                    )
                ]
            ),
            .init(
                name: "Cosmic Fire",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#060000"
                    ),
                    (
                        0.22,
                        "#3D0711"
                    ),
                    (
                        0.44,
                        "#920E1B"
                    ),
                    (
                        0.66,
                        "#FF6A00"
                    ),
                    (
                        0.88,
                        "#FFD166"
                    ),
                    (
                        1.00,
                        "#FFF4D6"
                    )
                ]
            ),
            .init(
                name: "Electric Blue",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00030A"
                    ),
                    (
                        0.20,
                        "#001B44"
                    ),
                    (
                        0.45,
                        "#0066FF"
                    ),
                    (
                        0.75,
                        "#33B3FF"
                    ),
                    (
                        1.00,
                        "#E6F3FF"
                    )
                ]
            ),
            
            // ——— Metallic / Shiny ———
            .init(
                name: "Metallic Silver",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0D0D0D"
                    ),
                    (
                        0.10,
                        "#4D4D4D"
                    ),
                    (
                        0.22,
                        "#D9D9D9"
                    ),
                    (
                        0.35,
                        "#595959"
                    ),
                    (
                        0.50,
                        "#EBEBEB"
                    ),
                    (
                        0.65,
                        "#666666"
                    ),
                    (
                        0.78,
                        "#E0E0E0"
                    ),
                    (
                        1.00,
                        "#262626"
                    )
                ]
            ),
            .init(
                name: "Chrome",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#050505"
                    ),
                    (
                        0.08,
                        "#404040"
                    ),
                    (
                        0.16,
                        "#F2F2F2"
                    ),
                    (
                        0.24,
                        "#333333"
                    ),
                    (
                        0.32,
                        "#FAFAFA"
                    ),
                    (
                        0.46,
                        "#2E2E2E"
                    ),
                    (
                        0.64,
                        "#F0F0F0"
                    ),
                    (
                        1.00,
                        "#1A1A1A"
                    )
                ]
            ),
            .init(
                name: "Gold",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#1A1100"
                    ),
                    (
                        0.15,
                        "#8C5F00"
                    ),
                    (
                        0.35,
                        "#F2C200"
                    ),
                    (
                        0.55,
                        "#FFE44D"
                    ),
                    (
                        0.75,
                        "#CC990D"
                    ),
                    (
                        1.00,
                        "#332200"
                    )
                ]
            ),
            .init(
                name: "Copper",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#120400"
                    ),
                    (
                        0.20,
                        "#8C330D"
                    ),
                    (
                        0.45,
                        "#E67326"
                    ),
                    (
                        0.65,
                        "#B3471A"
                    ),
                    (
                        0.85,
                        "#FFC299"
                    ),
                    (
                        1.00,
                        "#331400"
                    )
                ]
            ),
            .init(
                name: "Iridescent",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#190033"
                    ),
                    (
                        0.15,
                        "#00A5CC"
                    ),
                    (
                        0.30,
                        "#9933FF"
                    ),
                    (
                        0.50,
                        "#FF66E6"
                    ),
                    (
                        0.70,
                        "#19E6A8"
                    ),
                    (
                        1.00,
                        "#F2F2F2"
                    )
                ]
            ),
            
            // ——— Scientific / Utility ———
            .init(
                name: "Magma",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#010004"
                    ),
                    (
                        0.25,
                        "#17063C"
                    ),
                    (
                        0.50,
                        "#5A1C50"
                    ),
                    (
                        0.75,
                        "#B93C32"
                    ),
                    (
                        1.00,
                        "#FCEFAF"
                    )
                ]
            ),
            .init(
                name: "Inferno",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#010003"
                    ),
                    (
                        0.25,
                        "#1A0533"
                    ),
                    (
                        0.50,
                        "#971F35"
                    ),
                    (
                        0.75,
                        "#F28721"
                    ),
                    (
                        1.00,
                        "#FCFFA5"
                    )
                ]
            ),
            .init(
                name: "Plasma",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0D0887"
                    ),
                    (
                        0.25,
                        "#7E03A8"
                    ),
                    (
                        0.50,
                        "#CC4778"
                    ),
                    (
                        0.75,
                        "#F89540"
                    ),
                    (
                        1.00,
                        "#F0F921"
                    )
                ]
            ),
            .init(
                name: "Viridis",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#440154"
                    ),
                    (
                        0.25,
                        "#414487"
                    ),
                    (
                        0.50,
                        "#2A788E"
                    ),
                    (
                        0.75,
                        "#22A884"
                    ),
                    (
                        1.00,
                        "#FDE725"
                    )
                ]
            ),
            .init(
                name: "Turbo",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#23171B"
                    ),
                    (
                        0.25,
                        "#37A2FF"
                    ),
                    (
                        0.50,
                        "#7FE029"
                    ),
                    (
                        0.75,
                        "#F3C200"
                    ),
                    (
                        1.00,
                        "#7F0E00"
                    )
                ]
            ),
            .init(
                name: "Grayscale",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#000000"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            
            // ——— Natural / Classic ———
            .init(
                name: "Sunset",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#241A05"
                    ),
                    (
                        0.20,
                        "#5A0835"
                    ),
                    (
                        0.40,
                        "#B31A4D"
                    ),
                    (
                        0.65,
                        "#FA6633"
                    ),
                    (
                        0.85,
                        "#FFD280"
                    ),
                    (
                        1.00,
                        "#FFF2B3"
                    )
                ]
            ),
            .init(
                name: "Aurora",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#05081A"
                    ),
                    (
                        0.25,
                        "#00664D"
                    ),
                    (
                        0.50,
                        "#19BF8C"
                    ),
                    (
                        0.75,
                        "#66D9F2"
                    ),
                    (
                        1.00,
                        "#DAF5FF"
                    )
                ]
            ),
            .init(
                name: "Rainbow Smooth",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#FF0000"
                    ),
                    (
                        0.17,
                        "#FF7F00"
                    ),
                    (
                        0.33,
                        "#FFFF00"
                    ),
                    (
                        0.50,
                        "#00FF00"
                    ),
                    (
                        0.67,
                        "#0000FF"
                    ),
                    (
                        0.83,
                        "#7F00FF"
                    ),
                    (
                        1.00,
                        "#FF0000"
                    )
                ]
            ),
            
            // ——— Gem / Extra Vivid ———
            .init(
                name: "Sapphire",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00061A"
                    ),
                    (
                        0.20,
                        "#003399"
                    ),
                    (
                        0.45,
                        "#1A73FF"
                    ),
                    (
                        0.75,
                        "#99C2FF"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Emerald",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00140A"
                    ),
                    (
                        0.20,
                        "#005C30"
                    ),
                    (
                        0.45,
                        "#00BF66"
                    ),
                    (
                        0.75,
                        "#80FFBF"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Ruby",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#140003"
                    ),
                    (
                        0.22,
                        "#800033"
                    ),
                    (
                        0.46,
                        "#E60040"
                    ),
                    (
                        0.72,
                        "#FF8099"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Amethyst",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0B0015"
                    ),
                    (
                        0.25,
                        "#4D0099"
                    ),
                    (
                        0.50,
                        "#B366FF"
                    ),
                    (
                        0.80,
                        "#E6CCFF"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Citrine",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#1A1000"
                    ),
                    (
                        0.22,
                        "#B37300"
                    ),
                    (
                        0.46,
                        "#FFD11A"
                    ),
                    (
                        0.72,
                        "#FFF099"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Jade",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00130F"
                    ),
                    (
                        0.26,
                        "#00594D"
                    ),
                    (
                        0.52,
                        "#00D4A6"
                    ),
                    (
                        0.78,
                        "#80FFE6"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Coral",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#1A0505"
                    ),
                    (
                        0.20,
                        "#D94D40"
                    ),
                    (
                        0.45,
                        "#FF8C73"
                    ),
                    (
                        0.75,
                        "#FFE0B3"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Midnight",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#000005"
                    ),
                    (
                        0.25,
                        "#000826"
                    ),
                    (
                        0.50,
                        "#003373"
                    ),
                    (
                        0.75,
                        "#3373D9"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Solar Flare",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#0D0500"
                    ),
                    (
                        0.22,
                        "#BF4D00"
                    ),
                    (
                        0.44,
                        "#FFB300"
                    ),
                    (
                        0.70,
                        "#FFE680"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Glacier",
                builtInIndex: nil,
                stopsHex: [
                    (
                        0.00,
                        "#00050D"
                    ),
                    (
                        0.20,
                        "#004D99"
                    ),
                    (
                        0.45,
                        "#73CCFF"
                    ),
                    (
                        0.75,
                        "#D9F2FF"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            
            // ——— GPU Built‑ins (shader indices) ———
            .init(
                name: "HSV",
                builtInIndex: 0,
                stopsHex: [
                    (
                        0.00,
                        "#FF0000"
                    ),
                    (
                        0.17,
                        "#FFFF00"
                    ),
                    (
                        0.33,
                        "#00FF00"
                    ),
                    (
                        0.50,
                        "#00FFFF"
                    ),
                    (
                        0.67,
                        "#0000FF"
                    ),
                    (
                        0.83,
                        "#FF00FF"
                    ),
                    (
                        1.00,
                        "#FF0000"
                    )
                ]
            ),
            .init(
                name: "Fire",
                builtInIndex: 1,
                stopsHex: [
                    (
                        0.00,
                        "#000000"
                    ),
                    (
                        0.15,
                        "#FF0000"
                    ),
                    (
                        0.50,
                        "#FF7F00"
                    ),
                    (
                        0.85,
                        "#FFFF00"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            .init(
                name: "Ocean",
                builtInIndex: 2,
                stopsHex: [
                    (
                        0.00,
                        "#000000"
                    ),
                    (
                        0.15,
                        "#0033FF"
                    ),
                    (
                        0.45,
                        "#1AB3B3"
                    ),
                    (
                        0.75,
                        "#00FFFF"
                    ),
                    (
                        1.00,
                        "#FFFFFF"
                    )
                ]
            ),
            
            PaletteItem(
              name: "Vivid Neon",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#000000"),
                (0.12, "#0FF1CE"),
                (0.25, "#00E5FF"),
                (0.38, "#00FF85"),
                (0.52, "#F9FF00"),
                (0.66, "#FF9100"),
                (0.80, "#FF006E"),
                (0.94, "#8A2EFF"),
                (1.00, "#000000")
              ]
            ),
            
            // ——— aVivid punchy (high contrast, clean ramps) ———

            PaletteItem(
              name: "Electric Sunset",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#130019"),
                (0.15, "#3B005B"),
                (0.35, "#A5007A"),
                (0.55, "#FF3D3D"),
                (0.72, "#FFA600"),
                (0.88, "#FFE600"),
                (1.00, "#FFF8E1")
              ]
            ),

            PaletteItem(
              name: "Tropical Punch",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#031A1A"),
                (0.18, "#006C67"),
                (0.36, "#00BFB2"),
                (0.54, "#F4D35E"),
                (0.72, "#EE964B"),
                (0.90, "#F95738"),
                (1.00, "#2B061E")
              ]
            ),
            
            // ——— Scientific refined (smooth, perceptual) ———
            PaletteItem(
              name: "Viridis+ (Boosted)",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#440154"),
                (0.20, "#404387"),
                (0.40, "#2A788E"),
                (0.60, "#21A585"),
                (0.80, "#7AD151"),
                (1.00, "#FDE725")
              ]
            ),

            PaletteItem(
              name: "Magma+ (Warm)",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#0B0724"),
                (0.15, "#2B0B3F"),
                (0.35, "#7B1E5A"),
                (0.55, "#B63655"),
                (0.75, "#F06B40"),
                (1.00, "#FCFDBF")
              ]
            ),

            PaletteItem(
              name: "Inferno+ (Gold)",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#0B0A0C"),
                (0.18, "#320A5E"),
                (0.36, "#871A3B"),
                (0.58, "#D24F12"),
                (0.78, "#F8B601"),
                (1.00, "#FCFFA4")
              ]
            ),
            
            // ——— Metallic glossy ———
            PaletteItem(
              name: "Chrome",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#0B0B0B"),
                (0.08, "#1E1E1E"),
                (0.18, "#A0A0A0"),
                (0.28, "#EAEAEA"),
                (0.40, "#6B6B6B"),
                (0.55, "#FFFFFF"),
                (0.72, "#8D8D8D"),
                (0.86, "#D9D9D9"),
                (1.00, "#0F0F0F")
              ]
            ),

            PaletteItem(
              name: "Polished Gold",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#2B2100"),
                (0.12, "#5A4300"),
                (0.25, "#B38B00"),
                (0.40, "#FFD34D"),
                (0.55, "#FFF5C2"),
                (0.70, "#E0BD48"),
                (0.85, "#6A4E00"),
                (1.00, "#2B2100")
              ]
            ),

            PaletteItem(
              name: "Copper Glow",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#1C0C07"),
                (0.15, "#3A160C"),
                (0.30, "#7A2D15"),
                (0.47, "#C3632F"),
                (0.65, "#E79B66"),
                (0.82, "#FFD6B8"),
                (1.00, "#2B130B")
              ]
            ),

            PaletteItem(
              name: "Oil Slick",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#0B0F14"),
                (0.12, "#13233E"),
                (0.25, "#163E7A"),
                (0.38, "#215FA1"),
                (0.52, "#35A08D"),
                (0.66, "#7ED36A"),
                (0.80, "#E8E86F"),
                (0.92, "#F59AC5"),
                (1.00, "#0B0F14")
              ]
            ),
            
            // ——— Soft pastel (for gentle textures) ———
            PaletteItem(
              name: "Pastel Breeze",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#F7FBFF"),
                (0.18, "#CCE5FF"),
                (0.36, "#D6FFF6"),
                (0.54, "#FFF7D6"),
                (0.72, "#FFE0E9"),
                (0.90, "#E7D6FF"),
                (1.00, "#F7FBFF")
              ]
            ),
            
            // ——— Soft pastel (for gentle textures) ———
            PaletteItem(
              name: "Smooth Rainbow (Cyclic)",
              builtInIndex: nil,
              stopsHex: [
                (0.00, "#FF0000"),
                (0.17, "#FFFF00"),
                (0.33, "#00FF00"),
                (0.50, "#00FFFF"),
                (0.67, "#0000FF"),
                (0.83, "#FF00FF"),
                (1.00, "#FF0000") // loop
              ]
            ),
        ]

        self.all = paletteData.map { item in
            PaletteOption(name: item.name, builtInIndex: item.builtInIndex, stops: makeStopsFromHex(item.stopsHex))
        }
    }

    /// Return palettes with favorites floated to the top.
    func optionsSortedByFavorites() -> [PaletteOption] {
        PaletteFavorites.shared.sorted(all)
    }
}

// MARK: - Favorites (persisted in UserDefaults)
final class PaletteFavorites {
    static let shared = PaletteFavorites()
    private let key = "favoritePalettes"
    private var favorites: Set<String>

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            favorites = Set(arr)
        } else {
            favorites = []
        }
    }

    func isFavorite(name: String) -> Bool { favorites.contains(name) }

    func toggle(name: String) {
        if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
        UserDefaults.standard.set(Array(favorites), forKey: key)
    }

    func sorted(_ options: [PaletteOption]) -> [PaletteOption] {
        options.sorted { a, b in
            let fa = favorites.contains(a.name)
            let fb = favorites.contains(b.name)
            if fa != fb { return fa && !fb } // favorites first
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Tiny Preview Cache (UIImage LUTs per palette name)
final class PalettePreviewCache {
    static let shared = PalettePreviewCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for option: PaletteOption, builder: () -> UIImage) -> UIImage {
        let key = option.name as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = builder()
        cache.setObject(img, forKey: key)
        return img
    }

    func removeAll() { cache.removeAllObjects() }
}
