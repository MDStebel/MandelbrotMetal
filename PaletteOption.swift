//
//  PaletteOption.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//


// MARK: - Palette system
    struct PaletteOption: Identifiable { let id = UUID(); let name: String; let builtInIndex: Int?; let stops: [(CGFloat, UIColor)] }

    // Centralized, data-driven palette definitions
    var paletteData: [(name: String, builtInIndex: Int?, stops: [(CGFloat, UIColor)])] {
        [
            // ——— Vivid / Artistic LUTs ———
            (name: "Neon",            builtInIndex: nil, stops: neonStops()),
            (name: "Vibrant",         builtInIndex: nil, stops: vibrantStops()),
            (name: "Sunset Glow",     builtInIndex: nil, stops: sunsetGlowStops()),
            (name: "Candy",           builtInIndex: nil, stops: candyStops()),
            (name: "Aurora Borealis", builtInIndex: nil, stops: auroraBorealisStops()),
            (name: "Tropical",        builtInIndex: nil, stops: tropicalStopsNew()),
            (name: "Flamingo",        builtInIndex: nil, stops: flamingoStopsNew()),
            (name: "Lagoon",          builtInIndex: nil, stops: lagoonStopsNew()),
            (name: "Cyberpunk",       builtInIndex: nil, stops: cyberpunkStops()),
            (name: "Lava",            builtInIndex: nil, stops: lavaStops()),

            // ——— Metallic / Shiny LUTs ———
            (name: "Metallic Silver", builtInIndex: nil, stops: metallicSilverStops()),
            (name: "Chrome",          builtInIndex: nil, stops: chromeStops()),
            (name: "Gold",            builtInIndex: nil, stops: goldStops()),
            (name: "Rose Gold",       builtInIndex: nil, stops: roseGoldStops()),
            (name: "Steel",           builtInIndex: nil, stops: steelStops()),
            (name: "Bronze",          builtInIndex: nil, stops: bronzeStops()),
            (name: "Copper",          builtInIndex: nil, stops: copperStops()),
            (name: "Titanium",        builtInIndex: nil, stops: titaniumStops()),
            (name: "Mercury",         builtInIndex: nil, stops: mercuryStops()),
            (name: "Pewter",          builtInIndex: nil, stops: pewterStops()),
            (name: "Iridescent",      builtInIndex: nil, stops: iridescentStops()),

            // ——— Scientific / Utility LUTs ———
            (name: "Magma",           builtInIndex: nil, stops: magmaStops()),
            (name: "Inferno",         builtInIndex: nil, stops: infernoStops()),
            (name: "Plasma",          builtInIndex: nil, stops: plasmaStops()),
            (name: "Viridis",         builtInIndex: nil, stops: viridisStops()),
            (name: "Turbo",           builtInIndex: nil, stops: turboStops()),
            (name: "Cubehelix",       builtInIndex: nil, stops: cubehelixStops()),
            (name: "Grayscale",       builtInIndex: nil, stops: grayscaleStops()),

            // ——— Natural / Classic LUTs ———
            (name: "Sunset",          builtInIndex: nil, stops: sunsetStops()),
            (name: "Pastel",          builtInIndex: nil, stops: pastelStops()),
            (name: "Aurora",          builtInIndex: nil, stops: auroraStops()),
            (name: "Rainbow Smooth",  builtInIndex: nil, stops: rainbowSmoothStops()),
            (name: "Earth",           builtInIndex: nil, stops: earthStops()),
            (name: "Forest",          builtInIndex: nil, stops: forestStops()),
            (name: "Ice",             builtInIndex: nil, stops: iceStops()),
            (name: "Topo",            builtInIndex: nil, stops: topoStops()),

            // ——— Gem / Extra Vivid LUTs ———
            (name: "Sapphire",        builtInIndex: nil, stops: sapphireStops()),
            (name: "Emerald",         builtInIndex: nil, stops: emeraldStops()),
            (name: "Ruby",            builtInIndex: nil, stops: rubyStops()),
            (name: "Amethyst",        builtInIndex: nil, stops: amethystStops()),
            (name: "Citrine",         builtInIndex: nil, stops: citrineStops()),
            (name: "Jade",            builtInIndex: nil, stops: jadeStops()),
            (name: "Coral",           builtInIndex: nil, stops: coralStops()),
            (name: "Midnight",        builtInIndex: nil, stops: midnightStops()),
            (name: "Solar Flare",     builtInIndex: nil, stops: solarFlareStops()),
            (name: "Glacier",         builtInIndex: nil, stops: glacierStops()),

            // ——— GPU Built‑ins (match shader indices) ———
            (name: "HSV",   builtInIndex: 0, stops: hsvStops()),
            (name: "Fire",  builtInIndex: 1, stops: fireStops()),
            (name: "Ocean", builtInIndex: 2, stops: oceanStops())
        ]
    }

    var paletteOptions: [PaletteOption] {
        paletteData.map { PaletteOption(name: $0.name, builtInIndex: $0.builtInIndex, stops: $0.stops) }
    }

    func palettePreview(for name: String) -> some View {
        let opt = paletteOptions.first { $0.name == name } ?? paletteOptions[0]
        return LinearGradient(gradient: Gradient(stops: opt.stops.map { .init(color: Color($0.1), location: $0.0) }), startPoint: .leading, endPoint: .trailing)
    }

    func applyPaletteOption(_ opt: PaletteOption) {
        currentPaletteName = opt.name
        if let idx = opt.builtInIndex {
            palette = idx
            vm.renderer?.setPalette(idx)
        } else {
            if let img = makeLUTImage(stops: opt.stops) {
                vm.renderer?.setPaletteImage(img)
                vm.renderer?.setPalette(3) // LUT slot
                palette = 3
            }
        }
        vm.requestDraw()
    }

    func makeLUTImage(stops: [(CGFloat, UIColor)], width: Int = 256) -> UIImage? {
        let w = max(2, width)
        let h = 1
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitsPerComp = 8
        let rowBytes = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bitsPerComp, bytesPerRow: rowBytes, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cgStops = stops.map { (loc, ui) in (loc, ui.cgColor) }
        let locations = cgStops.map { $0.0 }
        let colors = cgStops.map { $0.1 } as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locations) else { return nil }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // Palette stop generators
    func hsvStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .red), (0.17, .yellow), (0.33, .green), (0.50, .cyan), (0.67, .blue), (0.83, .magenta), (1.00, .red) ]
    }
    func fireStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.15, .red), (0.50, .orange), (0.85, .yellow), (1.00, .white) ]
    }
    func oceanStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.15, .blue), (0.45, .systemTeal), (0.75, .cyan), (1.00, .white) ]
    }
    func magmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.015, alpha:1)),
          (0.25, UIColor(red:0.090, green:0.022, blue:0.147, alpha:1)),
          (0.50, UIColor(red:0.355, green:0.110, blue:0.312, alpha:1)),
          (0.75, UIColor(red:0.722, green:0.235, blue:0.196, alpha:1)),
          (1.00, UIColor(red:0.987, green:0.940, blue:0.749, alpha:1)) ]
    }
    func infernoStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.013, alpha:1)),
          (0.25, UIColor(red:0.102, green:0.019, blue:0.201, alpha:1)),
          (0.50, UIColor(red:0.591, green:0.125, blue:0.208, alpha:1)),
          (0.75, UIColor(red:0.949, green:0.526, blue:0.132, alpha:1)),
          (1.00, UIColor(red:0.988, green:0.998, blue:0.645, alpha:1)) ]
    }
    func plasmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.050, green:0.030, blue:0.527, alpha:1)),
          (0.25, UIColor(red:0.541, green:0.016, blue:0.670, alpha:1)),
          (0.50, UIColor(red:0.884, green:0.206, blue:0.380, alpha:1)),
          (0.75, UIColor(red:0.993, green:0.666, blue:0.237, alpha:1)),
          (1.00, UIColor(red:0.940, green:0.975, blue:0.131, alpha:1)) ]
    }
    func viridisStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.267, green:0.005, blue:0.329, alpha:1)),
          (0.25, UIColor(red:0.283, green:0.141, blue:0.458, alpha:1)),
          (0.50, UIColor(red:0.254, green:0.265, blue:0.530, alpha:1)),
          (0.75, UIColor(red:0.127, green:0.566, blue:0.550, alpha:1)),
          (1.00, UIColor(red:0.993, green:0.904, blue:0.144, alpha:1)) ]
    }
    func turboStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.189, green:0.071, blue:0.232, alpha:1)),
          (0.25, UIColor(red:0.216, green:0.460, blue:0.996, alpha:1)),
          (0.50, UIColor(red:0.500, green:0.891, blue:0.158, alpha:1)),
          (0.75, UIColor(red:0.994, green:0.760, blue:0.000, alpha:1)),
          (1.00, UIColor(red:0.498, green:0.054, blue:0.000, alpha:1)) ]
    }
    func cubehelixStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.25, .darkGray), (0.50, .systemGreen), (0.75, .systemPurple), (1.00, .white) ]
    }
    func grayscaleStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (1.00, .white) ]
    }
    func sunsetStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.02, blue:0.20, alpha:1)),
          (0.20, UIColor(red:0.35, green:0.02, blue:0.35, alpha:1)),
          (0.40, UIColor(red:0.70, green:0.10, blue:0.30, alpha:1)),
          (0.65, UIColor(red:0.98, green:0.40, blue:0.20, alpha:1)),
          (0.85, UIColor(red:1.00, green:0.75, blue:0.30, alpha:1)),
          (1.00, UIColor(red:1.00, green:0.95, blue:0.70, alpha:1)) ]
    }
    func pastelStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.90, green:0.95, blue:1.00, alpha:1)),
          (0.20, UIColor(red:0.86, green:0.92, blue:1.00, alpha:1)),
          (0.40, UIColor(red:0.92, green:0.86, blue:0.98, alpha:1)),
          (0.60, UIColor(red:0.98, green:0.88, blue:0.90, alpha:1)),
          (0.80, UIColor(red:0.98, green:0.95, blue:0.84, alpha:1)),
          (1.00, UIColor(red:0.90, green:0.98, blue:0.88, alpha:1)) ]
    }
    func auroraStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.02, green:0.03, blue:0.10, alpha:1)),
          (0.25, UIColor(red:0.00, green:0.40, blue:0.30, alpha:1)),
          (0.50, UIColor(red:0.10, green:0.75, blue:0.55, alpha:1)),
          (0.75, UIColor(red:0.40, green:0.85, blue:0.90, alpha:1)),
          (1.00, UIColor(red:0.85, green:0.95, blue:1.00, alpha:1)) ]
    }
    func rainbowSmoothStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .red), (0.17, .orange), (0.33, .yellow), (0.50, .green), (0.67, .blue), (0.83, .purple), (1.00, .red) ]
    }
    func earthStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.14, green:0.08, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.25, green:0.16, blue:0.05, alpha:1)),
          (0.40, UIColor(red:0.38, green:0.26, blue:0.10, alpha:1)),
          (0.60, UIColor(red:0.52, green:0.36, blue:0.16, alpha:1)),
          (0.80, UIColor(red:0.70, green:0.55, blue:0.30, alpha:1)),
          (1.00, UIColor(red:0.90, green:0.82, blue:0.60, alpha:1)) ]
    }
    func forestStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.02, green:0.12, blue:0.02, alpha:1)),
          (0.25, UIColor(red:0.05, green:0.28, blue:0.10, alpha:1)),
          (0.50, UIColor(red:0.10, green:0.45, blue:0.18, alpha:1)),
          (0.75, UIColor(red:0.25, green:0.60, blue:0.32, alpha:1)),
          (1.00, UIColor(red:0.75, green:0.90, blue:0.70, alpha:1)) ]
    }
    func iceStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.07, blue:0.15, alpha:1)),
          (0.25, UIColor(red:0.10, green:0.34, blue:0.55, alpha:1)),
          (0.50, UIColor(red:0.40, green:0.75, blue:0.90, alpha:1)),
          (0.75, UIColor(red:0.75, green:0.92, blue:0.97, alpha:1)),
          (1.00, UIColor(red:0.95, green:0.98, blue:1.00, alpha:1)) ]
    }
    func topoStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.25, blue:0.50, alpha:1)),
          (0.15, UIColor(red:0.10, green:0.50, blue:0.75, alpha:1)),
          (0.30, UIColor(red:0.20, green:0.70, blue:0.40, alpha:1)),
          (0.45, UIColor(red:0.45, green:0.70, blue:0.20, alpha:1)),
          (0.60, UIColor(red:0.70, green:0.70, blue:0.40, alpha:1)),
          (0.75, UIColor(red:0.75, green:0.55, blue:0.35, alpha:1)),
          (0.90, UIColor(red:0.70, green:0.35, blue:0.30, alpha:1)),
          (1.00, UIColor(red:0.95, green:0.95, blue:0.95, alpha:1)) ]
    }

    // --- New vivid palette stop generators ---
    func neonStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor.black),
            (0.08, UIColor(red:0.00, green:1.00, blue:0.70, alpha:1)),
            (0.20, UIColor(red:0.00, green:0.80, blue:1.00, alpha:1)),
            (0.35, UIColor(red:0.40, green:0.20, blue:1.00, alpha:1)),
            (0.55, UIColor(red:1.00, green:0.10, blue:0.90, alpha:1)),
            (0.75, UIColor(red:1.00, green:0.80, blue:0.10, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    func vibrantStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.05, green:0.02, blue:0.15, alpha:1)),
            (0.15, UIColor(red:0.20, green:0.00, blue:0.70, alpha:1)),
            (0.35, UIColor(red:0.00, green:0.60, blue:1.00, alpha:1)),
            (0.55, UIColor(red:0.00, green:0.90, blue:0.40, alpha:1)),
            (0.75, UIColor(red:1.00, green:0.80, blue:0.00, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.15, blue:0.10, alpha:1))
        ]
    }

    func sunsetGlowStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.08, green:0.00, blue:0.15, alpha:1)),
            (0.18, UIColor(red:0.40, green:0.00, blue:0.40, alpha:1)),
            (0.38, UIColor(red:0.85, green:0.20, blue:0.40, alpha:1)),
            (0.60, UIColor(red:1.00, green:0.54, blue:0.10, alpha:1)),
            (0.82, UIColor(red:1.00, green:0.85, blue:0.25, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.98, blue:0.85, alpha:1))
        ]
    }

    func candyStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.10, green:0.00, blue:0.20, alpha:1)),
            (0.20, UIColor(red:0.90, green:0.20, blue:0.75, alpha:1)),
            (0.40, UIColor(red:1.00, green:0.40, blue:0.50, alpha:1)),
            (0.60, UIColor(red:1.00, green:0.70, blue:0.30, alpha:1)),
            (0.80, UIColor(red:0.90, green:0.95, blue:0.40, alpha:1)),
            (1.00, UIColor(red:0.80, green:1.00, blue:0.95, alpha:1))
        ]
    }

    func auroraBorealisStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.00, green:0.02, blue:0.07, alpha:1)),
            (0.18, UIColor(red:0.00, green:0.40, blue:0.35, alpha:1)),
            (0.36, UIColor(red:0.00, green:0.75, blue:0.65, alpha:1)),
            (0.58, UIColor(red:0.35, green:0.95, blue:0.90, alpha:1)),
            (0.78, UIColor(red:0.60, green:0.85, blue:1.00, alpha:1)),
            (1.00, UIColor(red:0.92, green:0.98, blue:1.00, alpha:1))
        ]
    }

    func tropicalStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision with existing helper
        [
            (0.00, UIColor(red:0.00, green:0.10, blue:0.22, alpha:1)),
            (0.20, UIColor(red:0.00, green:0.55, blue:0.60, alpha:1)),
            (0.40, UIColor(red:0.00, green:0.85, blue:0.60, alpha:1)),
            (0.60, UIColor(red:0.95, green:0.80, blue:0.00, alpha:1)),
            (0.80, UIColor(red:1.00, green:0.50, blue:0.00, alpha:1)),
            (1.00, UIColor(red:0.90, green:0.10, blue:0.00, alpha:1))
        ]
    }

    func flamingoStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision
        [
            (0.00, UIColor(red:0.18, green:0.02, blue:0.20, alpha:1)),
            (0.22, UIColor(red:0.80, green:0.10, blue:0.50, alpha:1)),
            (0.44, UIColor(red:1.00, green:0.40, blue:0.70, alpha:1)),
            (0.66, UIColor(red:1.00, green:0.70, blue:0.75, alpha:1)),
            (0.88, UIColor(red:1.00, green:0.90, blue:0.90, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    func lagoonStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision
        [
            (0.00, UIColor(red:0.00, green:0.04, blue:0.10, alpha:1)),
            (0.18, UIColor(red:0.00, green:0.30, blue:0.60, alpha:1)),
            (0.36, UIColor(red:0.00, green:0.62, blue:0.80, alpha:1)),
            (0.62, UIColor(red:0.00, green:0.85, blue:0.75, alpha:1)),
            (0.82, UIColor(red:0.50, green:0.98, blue:0.90, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    func cyberpunkStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.04, green:0.00, blue:0.08, alpha:1)),
            (0.20, UIColor(red:0.12, green:0.00, blue:0.55, alpha:1)),
            (0.40, UIColor(red:0.55, green:0.00, blue:0.85, alpha:1)),
            (0.60, UIColor(red:0.00, green:0.90, blue:0.95, alpha:1)),
            (0.80, UIColor(red:1.00, green:0.20, blue:0.60, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.95, blue:0.90, alpha:1))
        ]
    }

    func lavaStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor.black),
            (0.18, UIColor(red:0.25, green:0.00, blue:0.00, alpha:1)),
            (0.38, UIColor(red:0.65, green:0.00, blue:0.00, alpha:1)),
            (0.58, UIColor(red:1.00, green:0.30, blue:0.00, alpha:1)),
            (0.78, UIColor(red:1.00, green:0.70, blue:0.00, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    // ——— Metallic / Shiny ———
    func metallicSilverStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.05, alpha:1)),
          (0.10, UIColor(white:0.30, alpha:1)),
          (0.22, UIColor(white:0.85, alpha:1)),
          (0.35, UIColor(white:0.35, alpha:1)),
          (0.50, UIColor(white:0.92, alpha:1)),
          (0.65, UIColor(white:0.40, alpha:1)),
          (0.78, UIColor(white:0.88, alpha:1)),
          (1.00, UIColor(white:0.15, alpha:1)) ]
    }
    func chromeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.02, alpha:1)),
          (0.08, UIColor(white:0.25, alpha:1)),
          (0.16, UIColor(white:0.95, alpha:1)),
          (0.24, UIColor(white:0.20, alpha:1)),
          (0.32, UIColor(white:0.98, alpha:1)),
          (0.46, UIColor(white:0.18, alpha:1)),
          (0.64, UIColor(white:0.96, alpha:1)),
          (1.00, UIColor(white:0.10, alpha:1)) ]
    }
    func goldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.07, blue:0.00, alpha:1)),
          (0.15, UIColor(red:0.55, green:0.38, blue:0.00, alpha:1)),
          (0.35, UIColor(red:0.95, green:0.78, blue:0.10, alpha:1)),
          (0.55, UIColor(red:1.00, green:0.88, blue:0.25, alpha:1)),
          (0.75, UIColor(red:0.80, green:0.60, blue:0.05, alpha:1)),
          (1.00, UIColor(red:0.20, green:0.15, blue:0.00, alpha:1)) ]
    }
    func roseGoldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.14, green:0.05, blue:0.05, alpha:1)),
          (0.20, UIColor(red:0.60, green:0.30, blue:0.25, alpha:1)),
          (0.40, UIColor(red:0.95, green:0.65, blue:0.55, alpha:1)),
          (0.60, UIColor(red:1.00, green:0.80, blue:0.70, alpha:1)),
          (0.80, UIColor(red:0.70, green:0.40, blue:0.35, alpha:1)),
          (1.00, UIColor(red:0.18, green:0.08, blue:0.08, alpha:1)) ]
    }
    func steelStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.05, alpha:1)),
          (0.20, UIColor(white:0.25, alpha:1)),
          (0.45, UIColor(white:0.70, alpha:1)),
          (0.65, UIColor(white:0.35, alpha:1)),
          (0.85, UIColor(white:0.80, alpha:1)),
          (1.00, UIColor(white:0.12, alpha:1)) ]
    }
    func bronzeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.02, blue:0.00, alpha:1)),
          (0.20, UIColor(red:0.40, green:0.20, blue:0.05, alpha:1)),
          (0.45, UIColor(red:0.70, green:0.45, blue:0.15, alpha:1)),
          (0.70, UIColor(red:0.48, green:0.28, blue:0.10, alpha:1)),
          (0.90, UIColor(red:0.85, green:0.65, blue:0.35, alpha:1)),
          (1.00, UIColor(red:0.15, green:0.08, blue:0.03, alpha:1)) ]
    }
    func copperStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.07, green:0.02, blue:0.00, alpha:1)),
          (0.20, UIColor(red:0.55, green:0.20, blue:0.05, alpha:1)),
          (0.45, UIColor(red:0.90, green:0.45, blue:0.15, alpha:1)),
          (0.65, UIColor(red:0.70, green:0.30, blue:0.10, alpha:1)),
          (0.85, UIColor(red:1.00, green:0.70, blue:0.45, alpha:1)),
          (1.00, UIColor(red:0.20, green:0.08, blue:0.03, alpha:1)) ]
    }
    func titaniumStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.07, alpha:1)),
          (0.18, UIColor(white:0.25, alpha:1)),
          (0.36, UIColor(white:0.85, alpha:1)),
          (0.54, UIColor(white:0.30, alpha:1)),
          (0.72, UIColor(white:0.90, alpha:1)),
          (1.00, UIColor(white:0.10, alpha:1)) ]
    }
    func mercuryStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.03, alpha:1)),
          (0.16, UIColor(white:0.25, alpha:1)),
          (0.33, UIColor(white:0.98, alpha:1)),
          (0.50, UIColor(white:0.20, alpha:1)),
          (0.66, UIColor(white:0.96, alpha:1)),
          (1.00, UIColor(white:0.08, alpha:1)) ]
    }
    func pewterStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.06, alpha:1)),
          (0.25, UIColor(white:0.22, alpha:1)),
          (0.55, UIColor(white:0.65, alpha:1)),
          (0.75, UIColor(white:0.32, alpha:1)),
          (0.92, UIColor(white:0.78, alpha:1)),
          (1.00, UIColor(white:0.14, alpha:1)) ]
    }
    func iridescentStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.00, blue:0.20, alpha:1)),
          (0.15, UIColor(red:0.00, green:0.65, blue:0.80, alpha:1)),
          (0.30, UIColor(red:0.60, green:0.20, blue:1.00, alpha:1)),
          (0.50, UIColor(red:1.00, green:0.40, blue:0.90, alpha:1)),
          (0.70, UIColor(red:0.10, green:0.90, blue:0.60, alpha:1)),
          (1.00, UIColor(red:0.95, green:0.95, blue:0.95, alpha:1)) ]
    }

    // ——— Gem / Extra Vivid ———
    func sapphireStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.02, blue:0.10, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.20, blue:0.60, alpha:1)),
          (0.45, UIColor(red:0.10, green:0.45, blue:0.95, alpha:1)),
          (0.75, UIColor(red:0.60, green:0.85, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func emeraldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.05, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.35, blue:0.18, alpha:1)),
          (0.45, UIColor(red:0.00, green:0.75, blue:0.40, alpha:1)),
          (0.75, UIColor(red:0.50, green:1.00, blue:0.75, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func rubyStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.00, blue:0.02, alpha:1)),
          (0.22, UIColor(red:0.50, green:0.00, blue:0.20, alpha:1)),
          (0.46, UIColor(red:0.90, green:0.05, blue:0.25, alpha:1)),
          (0.72, UIColor(red:1.00, green:0.50, blue:0.60, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func amethystStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.04, green:0.00, blue:0.08, alpha:1)),
          (0.25, UIColor(red:0.30, green:0.00, blue:0.60, alpha:1)),
          (0.50, UIColor(red:0.70, green:0.25, blue:1.00, alpha:1)),
          (0.80, UIColor(red:0.90, green:0.70, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func citrineStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.06, blue:0.00, alpha:1)),
          (0.22, UIColor(red:0.70, green:0.45, blue:0.00, alpha:1)),
          (0.46, UIColor(red:1.00, green:0.85, blue:0.10, alpha:1)),
          (0.72, UIColor(red:1.00, green:0.95, blue:0.60, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func jadeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.06, blue:0.04, alpha:1)),
          (0.26, UIColor(red:0.00, green:0.35, blue:0.30, alpha:1)),
          (0.52, UIColor(red:0.00, green:0.85, blue:0.65, alpha:1)),
          (0.78, UIColor(red:0.50, green:1.00, blue:0.90, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func coralStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.02, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.85, green:0.25, blue:0.25, alpha:1)),
          (0.45, UIColor(red:1.00, green:0.55, blue:0.45, alpha:1)),
          (0.75, UIColor(red:1.00, green:0.85, blue:0.70, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func midnightStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.00, blue:0.02, alpha:1)),
          (0.25, UIColor(red:0.00, green:0.02, blue:0.15, alpha:1)),
          (0.50, UIColor(red:0.00, green:0.20, blue:0.45, alpha:1)),
          (0.75, UIColor(red:0.20, green:0.45, blue:0.85, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func solarFlareStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.02, blue:0.00, alpha:1)),
          (0.22, UIColor(red:0.75, green:0.30, blue:0.00, alpha:1)),
          (0.44, UIColor(red:1.00, green:0.70, blue:0.00, alpha:1)),
          (0.70, UIColor(red:1.00, green:0.90, blue:0.40, alpha:1)),
          (1.00, UIColor.white) ]
    }
    func glacierStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.02, blue:0.05, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.30, blue:0.60, alpha:1)),
          (0.45, UIColor(red:0.45, green:0.80, blue:1.00, alpha:1)),
          (0.75, UIColor(red:0.85, green:0.95, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }
