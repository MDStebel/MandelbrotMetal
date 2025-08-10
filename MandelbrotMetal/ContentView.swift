//
//  ContentView.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/8/25.
//

import MetalKit
import PhotosUI
import Photos
import SwiftUI
import UIKit
import simd

@MainActor
final class FractalVM: ObservableObject {
    @Published var center = SIMD2<Double>(-0.5, 0.0)
    @Published var scalePixelsPerUnit: Double = 1
    @Published var maxIterations: Int = 800
    @Published var baselineScale: Double = 1

    var viewSize: CGSize = .zero

    fileprivate var renderer: MandelbrotRenderer?
    fileprivate weak var mtkView: MTKView?

    func attachRenderer(_ r: MandelbrotRenderer) { self.renderer = r }
    func attachView(_ v: MTKView) { self.mtkView = v }

    func pushViewport(_ size: CGSize, screenScale: CGFloat) {
        guard size != .zero else { return }
        viewSize = size

        let wD = Double(size.width) * Double(screenScale)
        let hD = Double(size.height) * Double(screenScale)
        guard wD.isFinite, hD.isFinite else { return }
        let pixelW = max(1, Int(floor(wD)))
        _ = max(1, Int(floor(hD))) // doc of intent

        let workingScale: Double
        if scalePixelsPerUnit == 1 {
            workingScale = Double(pixelW) / 3.5
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scalePixelsPerUnit = workingScale
                if self.baselineScale == 1 { self.baselineScale = workingScale }
            }
        } else {
            workingScale = scalePixelsPerUnit
            if baselineScale == 1 { baselineScale = workingScale }
        }

        renderer?.setViewport(center: center,
                              scalePixelsPerUnit: workingScale,
                              sizePts: size,
                              screenScale: screenScale,
                              maxIterations: maxIterations)
    }

    func requestDraw() {
        renderer?.needsRender = true
        mtkView?.setNeedsDisplay()
    }

    // MARK: - Persistence
    private let kCenterX = "center_x"
    private let kCenterY = "center_y"
    private let kScale   = "scale_px_per_unit"
    private let kIters   = "max_iters"
    private let kPerturb = "perturb"
    private let kDeep    = "deep"
    private let kPalette = "palette"

    func saveState(perturb: Bool, deep: Bool, palette: Int) {
        let d = UserDefaults.standard
        d.set(center.x, forKey: kCenterX)
        d.set(center.y, forKey: kCenterY)
        d.set(scalePixelsPerUnit, forKey: kScale)
        d.set(maxIterations, forKey: kIters)
        d.set(perturb, forKey: kPerturb)
        d.set(deep, forKey: kDeep)
        d.set(palette, forKey: kPalette)
    }

    func loadState() -> (perturb: Bool, deep: Bool, palette: Int)? {
        let d = UserDefaults.standard
        guard d.object(forKey: kCenterX) != nil else { return nil }
        let cx = d.double(forKey: kCenterX)
        let cy = d.double(forKey: kCenterY)
        center = SIMD2<Double>(cx, cy)
        scalePixelsPerUnit = max(0.01, d.double(forKey: kScale))
        maxIterations = max(100, d.integer(forKey: kIters))
        let perturb = d.bool(forKey: kPerturb)
        let deep = d.bool(forKey: kDeep)
        let palette = d.integer(forKey: kPalette)
        return (perturb, deep, palette)
    }
}

struct MetalFractalView: UIViewRepresentable {
    @ObservedObject var vm: FractalVM
    
    @MainActor
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.isPaused = false
        view.enableSetNeedsDisplay = false // continuous redraw
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false
        guard let renderer = MandelbrotRenderer(mtkView: view) else { return view }
        vm.attachRenderer(renderer)
        vm.attachView(view)
        return view
    }
    
    @MainActor
    func updateUIView(_ uiView: MTKView, context: Context) {
        let nominalScale = uiView.window?.screen.scale ?? UIScreen.main.scale
        let sizePts = uiView.bounds.size
        // Floor to whole pixels so it doesn’t bounce between adjacent sizes
        let sizePx = CGSize(
            width: floor(max(1, sizePts.width  * nominalScale)),
            height: floor(max(1, sizePts.height * nominalScale))
        )
        uiView.drawableSize = sizePx

        // Use the ACTUAL pixels-per-point used by MTKView (prevents 1px jumps)
        let scaleUsed: CGFloat
        if sizePts.width > 0 {
            scaleUsed = sizePx.width / sizePts.width
        } else {
            scaleUsed = nominalScale
        }

        vm.pushViewport(sizePts, screenScale: scaleUsed)
        vm.requestDraw()
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @StateObject private var vm = FractalVM()
    @State private var pendingCenter = SIMD2<Double>(0, 0)
    @State private var pendingScale  = 1.0
    @State private var perturbation = false
    @State private var palette = 0 // 0=HSV, 1=Fire, 2=Ocean
    @State private var gradientItem: PhotosPickerItem? = nil
    @State private var showPalettePicker = false
    @State private var currentPaletteName: String = "HSV" // tracks UI label for palette
    
    @State private var deepZoom = false
    @State private var snapshotImage: UIImage? = nil
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var snapshotURL: URL? = nil
    @State private var showAbout = false
    @State private var showHelp = false
    @State private var autoIterations = false
    @State private var showOptionsSheet = false
    struct Bookmark: Codable, Identifiable { var id = UUID(); var name: String; var center: SIMD2<Double>; var scale: Double; var palette: Int; var deep: Bool; var perturb: Bool }
    @State private var bookmarks: [Bookmark] = []
    @State private var showAddBookmark = false
    @State private var newBookmarkName: String = ""
    @State private var fallbackBanner: String? = nil
    @State private var fallbackObserver: NSObjectProtocol? = nil

    enum SnapshotRes: String, CaseIterable, Identifiable {
        case r4k="4K (3840×2160)",
             r6k="6K (5760×3240)",
             r8k="8K (7680×4320)",
             custom="Custom…"; var id: String {
                 rawValue
             }
    }
    @State private var snapRes: SnapshotRes = .r4k
    @State private var customW: String = "3840"
    @State private var customH: String = "2160"
    @State private var showCustomRes = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                fractalCanvas(geo)
                hud
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let banner = fallbackBanner {
                    Text("⚠️ \(banner)")
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                floatingControls(geo)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .onAppear {
                if let s = vm.loadState() {
                    perturbation = s.perturb
                    deepZoom = s.deep
                    palette = s.palette
                }
                vm.pushViewport(currentPointsSize(geo.size), screenScale: currentScreenScale())
                vm.requestDraw()
                vm.renderer?.setPerturbation(perturbation)
                vm.renderer?.setPalette(palette)
                vm.renderer?.setDeepZoom(deepZoom)
                currentPaletteName = (palette == 0 ? "HSV" : palette == 1 ? "Fire" : palette == 2 ? "Ocean" : currentPaletteName)
                loadBookmarks()
                // Listen for renderer fallbacks (perturbation/LUT resource issues)
                fallbackObserver = NotificationCenter.default.addObserver(forName: .MandelbrotRendererFallback, object: nil, queue: .main) { note in
                    if let msg = note.userInfo?["reason"] as? String {
                        fallbackBanner = msg
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            if fallbackBanner == msg { fallbackBanner = nil }
                        }
                    }
                }
            }
            .onDisappear {
                if let obs = fallbackObserver {
                    NotificationCenter.default.removeObserver(obs)
                    fallbackObserver = nil
                }
            }
            .onChange(of: geo.size) { _, newSize in
                vm.pushViewport(currentPointsSize(newSize), screenScale: currentScreenScale())
            }
            .onChange(of: perturbation) { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: deepZoom)     { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: palette)      { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.center)    { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.scalePixelsPerUnit) { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.maxIterations)      { vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .toolbar { }
            .sheet(isPresented: $showPalettePicker) {
                NavigationStack {
                    PalettePickerView(selected: currentPaletteName, options: paletteOptions) { opt in
                        applyPaletteOption(opt)
                        showPalettePicker = false
                    }
                    .navigationTitle("Palettes")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showPalettePicker = false } } }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showCustomRes) {
                NavigationStack {
                    Form {
                        Section(header: Text("Custom Resolution")) {
                            TextField("Width", text: $customW).keyboardType(.numberPad)
                            TextField("Height", text: $customH).keyboardType(.numberPad)
                        }
                    }
                    .navigationTitle("Custom Size")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCustomRes = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { snapRes = .custom; showCustomRes = false } }
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    HelpView()
                        .navigationTitle("Help")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Close") { showHelp = false } }
                        }
                }
            }
            .sheet(isPresented: $showAbout) {
                VStack(spacing: 16) {
                    Text("Mandelbrot Metal").font(.title).bold()
                    Text(appCopyright())
                    Text(appVersionBuild())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Close") { showAbout = false }.padding()
                }
                .padding()
            }
            .sheet(isPresented: $showAddBookmark) {
                NavigationStack {
                    Form { TextField("Name", text: $newBookmarkName) }
                        .navigationTitle("Add Bookmark")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddBookmark = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("Save") {
                                let bm = Bookmark(name: newBookmarkName.isEmpty ? "Bookmark \(bookmarks.count+1)" : newBookmarkName,
                                                  center: vm.center,
                                                  scale: vm.scalePixelsPerUnit,
                                                  palette: palette,
                                                  deep: deepZoom,
                                                  perturb: perturbation)
                                bookmarks.append(bm)
                                saveBookmarks()
                                showAddBookmark = false
                            } }
                        }
                }
            }
            .sheet(isPresented: .constant(false)) { EmptyView() } // placeholder
            .sheet(isPresented: $showOptionsSheet) {
                CompactOptionsSheet(
                    currentPaletteName: $currentPaletteName,
                    showPalettePicker: $showPalettePicker,
                    autoIterations: $autoIterations,
                    iterations: $vm.maxIterations,
                    perturbation: $perturbation,
                    deepZoom: $deepZoom,
                    snapRes: $snapRes,
                    paletteOptions: paletteOptions,
                    applyPalette: { opt in
                        applyPaletteOption(opt)
                    },
                    onImportGradient: { item in
                        gradientItem = item
                        importGradientItem(item)
                    },
                    onSave: { saveCurrentSnapshot() },
                    onAbout: { showAbout = true },
                    onHelp: { showHelp = true },
                    onClose: { showOptionsSheet = false },
                    onCustom: { showCustomRes = true }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
    
    private func currentScreenScale() -> CGFloat {
        if let v = vm.mtkView {
            let ptsW = v.bounds.size.width
            let pxW  = v.drawableSize.width
            if ptsW > 0 { return pxW / ptsW } // actual pixels-per-point
            return v.window?.screen.scale ?? UIScreen.main.scale
        }
        return UIScreen.main.scale
    }

    // NEW: always use the MTKView’s actual points size for mapping
    private func currentPointsSize(_ fallback: CGSize) -> CGSize {
        if let v = vm.mtkView { return v.bounds.size }
        return fallback
    }

    @ViewBuilder
    private func fractalCanvas(_ geo: GeometryProxy) -> some View {
        let singleTap = SpatialTapGesture(count: 1).onEnded { value in
            recenterAtTap(value.location, size: geo.size)
        }
        let doubleTap = SpatialTapGesture(count: 2).onEnded { value in
            doubleTapZoom(point: value.location, size: geo.size, factor: 2.0)
        }

        MetalFractalView(vm: vm)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(panAndZoom(geo.size))                       // pan + pinch
            .highPriorityGesture(doubleTap)                      // ensure double‑tap wins
            .simultaneousGesture(singleTap)                      // single‑tap recenter
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    vm.renderer?.recenterReference(atComplex: vm.center, iterations: vm.maxIterations)
                    vm.requestDraw()
                }
            )
    }

    // Helper to provide compact/regular palette labels with accessibility support
    private func paletteLabel(_ index: Int) -> some View {
        let compact = (hSize == .compact)
        let title: String
        let a11y: String
        switch index {
        case 0: title = "HSV";     a11y = "HSV"
        case 1: title = compact ? "🔥" : "Fire";  a11y = "Fire"
        case 2: title = compact ? "🌊" : "Ocean"; a11y = "Ocean"
        default: title = "LUT";   a11y = "LUT"
        }
        return Text(title)
            .font(compact ? .caption2 : .body)
            .accessibilityLabel(a11y)
            .foregroundStyle(.primary)
    }

    // MARK: - Palette system
    struct PaletteOption: Identifiable { let id = UUID(); let name: String; let builtInIndex: Int?; let stops: [(CGFloat, UIColor)] }

    var paletteOptions: [PaletteOption] {
        [
            // ——— Vivid / Artistic LUTs ———
            PaletteOption(name: "Neon",             builtInIndex: nil, stops: neonStops()),
            PaletteOption(name: "Vibrant",          builtInIndex: nil, stops: vibrantStops()),
            PaletteOption(name: "Sunset Glow",      builtInIndex: nil, stops: sunsetGlowStops()),
            PaletteOption(name: "Candy",            builtInIndex: nil, stops: candyStops()),
            PaletteOption(name: "Aurora Borealis",  builtInIndex: nil, stops: auroraBorealisStops()),
            PaletteOption(name: "Tropical",         builtInIndex: nil, stops: tropicalStopsNew()),
            PaletteOption(name: "Flamingo",         builtInIndex: nil, stops: flamingoStopsNew()),
            PaletteOption(name: "Lagoon",           builtInIndex: nil, stops: lagoonStopsNew()),
            PaletteOption(name: "Cyberpunk",        builtInIndex: nil, stops: cyberpunkStops()),
            PaletteOption(name: "Lava",             builtInIndex: nil, stops: lavaStops()),

            // ——— Metallic / Shiny LUTs ———
            PaletteOption(name: "Metallic Silver",  builtInIndex: nil, stops: metallicSilverStops()),
            PaletteOption(name: "Chrome",           builtInIndex: nil, stops: chromeStops()),
            PaletteOption(name: "Gold",             builtInIndex: nil, stops: goldStops()),
            PaletteOption(name: "Rose Gold",        builtInIndex: nil, stops: roseGoldStops()),
            PaletteOption(name: "Steel",            builtInIndex: nil, stops: steelStops()),
            PaletteOption(name: "Bronze",           builtInIndex: nil, stops: bronzeStops()),
            PaletteOption(name: "Copper",           builtInIndex: nil, stops: copperStops()),
            PaletteOption(name: "Titanium",         builtInIndex: nil, stops: titaniumStops()),
            PaletteOption(name: "Mercury",          builtInIndex: nil, stops: mercuryStops()),
            PaletteOption(name: "Pewter",           builtInIndex: nil, stops: pewterStops()),
            PaletteOption(name: "Iridescent",       builtInIndex: nil, stops: iridescentStops()),

            // ——— Scientific / Utility LUTs ———
            PaletteOption(name: "Magma",            builtInIndex: nil, stops: magmaStops()),
            PaletteOption(name: "Inferno",          builtInIndex: nil, stops: infernoStops()),
            PaletteOption(name: "Plasma",           builtInIndex: nil, stops: plasmaStops()),
            PaletteOption(name: "Viridis",          builtInIndex: nil, stops: viridisStops()),
            PaletteOption(name: "Turbo",            builtInIndex: nil, stops: turboStops()),
            PaletteOption(name: "Cubehelix",        builtInIndex: nil, stops: cubehelixStops()),
            PaletteOption(name: "Grayscale",        builtInIndex: nil, stops: grayscaleStops()),

            // ——— Natural / Classic LUTs ———
            PaletteOption(name: "Sunset",           builtInIndex: nil, stops: sunsetStops()),
            PaletteOption(name: "Pastel",           builtInIndex: nil, stops: pastelStops()),
            PaletteOption(name: "Aurora",           builtInIndex: nil, stops: auroraStops()),
            PaletteOption(name: "Rainbow Smooth",   builtInIndex: nil, stops: rainbowSmoothStops()),
            PaletteOption(name: "Earth",            builtInIndex: nil, stops: earthStops()),
            PaletteOption(name: "Forest",           builtInIndex: nil, stops: forestStops()),
            PaletteOption(name: "Ice",              builtInIndex: nil, stops: iceStops()),
            PaletteOption(name: "Topo",             builtInIndex: nil, stops: topoStops()),

            // ——— Gem / Extra Vivid LUTs ———
            PaletteOption(name: "Sapphire",         builtInIndex: nil, stops: sapphireStops()),
            PaletteOption(name: "Emerald",          builtInIndex: nil, stops: emeraldStops()),
            PaletteOption(name: "Ruby",             builtInIndex: nil, stops: rubyStops()),
            PaletteOption(name: "Amethyst",         builtInIndex: nil, stops: amethystStops()),
            PaletteOption(name: "Citrine",          builtInIndex: nil, stops: citrineStops()),
            PaletteOption(name: "Jade",             builtInIndex: nil, stops: jadeStops()),
            PaletteOption(name: "Coral",            builtInIndex: nil, stops: coralStops()),
            PaletteOption(name: "Midnight",         builtInIndex: nil, stops: midnightStops()),
            PaletteOption(name: "Solar Flare",      builtInIndex: nil, stops: solarFlareStops()),
            PaletteOption(name: "Glacier",          builtInIndex: nil, stops: glacierStops()),

            // ——— GPU Built‑ins (match shader indices) ———
            PaletteOption(name: "HSV",   builtInIndex: 0, stops: hsvStops()),
            PaletteOption(name: "Fire",  builtInIndex: 1, stops: fireStops()),
            PaletteOption(name: "Ocean", builtInIndex: 2, stops: oceanStops())
        ]
    }

    private func palettePreview(for name: String) -> some View {
        let opt = paletteOptions.first { $0.name == name } ?? paletteOptions[0]
        return LinearGradient(gradient: Gradient(stops: opt.stops.map { .init(color: Color($0.1), location: $0.0) }), startPoint: .leading, endPoint: .trailing)
    }

    private func applyPaletteOption(_ opt: PaletteOption) {
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

    private func makeLUTImage(stops: [(CGFloat, UIColor)], width: Int = 256) -> UIImage? {
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
    private func hsvStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .red), (0.17, .yellow), (0.33, .green), (0.50, .cyan), (0.67, .blue), (0.83, .magenta), (1.00, .red) ]
    }
    private func fireStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.15, .red), (0.50, .orange), (0.85, .yellow), (1.00, .white) ]
    }
    private func oceanStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.15, .blue), (0.45, .systemTeal), (0.75, .cyan), (1.00, .white) ]
    }
    private func magmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.015, alpha:1)),
          (0.25, UIColor(red:0.090, green:0.022, blue:0.147, alpha:1)),
          (0.50, UIColor(red:0.355, green:0.110, blue:0.312, alpha:1)),
          (0.75, UIColor(red:0.722, green:0.235, blue:0.196, alpha:1)),
          (1.00, UIColor(red:0.987, green:0.940, blue:0.749, alpha:1)) ]
    }
    private func infernoStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.013, alpha:1)),
          (0.25, UIColor(red:0.102, green:0.019, blue:0.201, alpha:1)),
          (0.50, UIColor(red:0.591, green:0.125, blue:0.208, alpha:1)),
          (0.75, UIColor(red:0.949, green:0.526, blue:0.132, alpha:1)),
          (1.00, UIColor(red:0.988, green:0.998, blue:0.645, alpha:1)) ]
    }
    private func plasmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.050, green:0.030, blue:0.527, alpha:1)),
          (0.25, UIColor(red:0.541, green:0.016, blue:0.670, alpha:1)),
          (0.50, UIColor(red:0.884, green:0.206, blue:0.380, alpha:1)),
          (0.75, UIColor(red:0.993, green:0.666, blue:0.237, alpha:1)),
          (1.00, UIColor(red:0.940, green:0.975, blue:0.131, alpha:1)) ]
    }
    private func viridisStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.267, green:0.005, blue:0.329, alpha:1)),
          (0.25, UIColor(red:0.283, green:0.141, blue:0.458, alpha:1)),
          (0.50, UIColor(red:0.254, green:0.265, blue:0.530, alpha:1)),
          (0.75, UIColor(red:0.127, green:0.566, blue:0.550, alpha:1)),
          (1.00, UIColor(red:0.993, green:0.904, blue:0.144, alpha:1)) ]
    }
    private func turboStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.189, green:0.071, blue:0.232, alpha:1)),
          (0.25, UIColor(red:0.216, green:0.460, blue:0.996, alpha:1)),
          (0.50, UIColor(red:0.500, green:0.891, blue:0.158, alpha:1)),
          (0.75, UIColor(red:0.994, green:0.760, blue:0.000, alpha:1)),
          (1.00, UIColor(red:0.498, green:0.054, blue:0.000, alpha:1)) ]
    }
    private func cubehelixStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (0.25, .darkGray), (0.50, .systemGreen), (0.75, .systemPurple), (1.00, .white) ]
    }
    private func grayscaleStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .black), (1.00, .white) ]
    }
    private func sunsetStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.02, blue:0.20, alpha:1)),
          (0.20, UIColor(red:0.35, green:0.02, blue:0.35, alpha:1)),
          (0.40, UIColor(red:0.70, green:0.10, blue:0.30, alpha:1)),
          (0.65, UIColor(red:0.98, green:0.40, blue:0.20, alpha:1)),
          (0.85, UIColor(red:1.00, green:0.75, blue:0.30, alpha:1)),
          (1.00, UIColor(red:1.00, green:0.95, blue:0.70, alpha:1)) ]
    }
    private func pastelStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.90, green:0.95, blue:1.00, alpha:1)),
          (0.20, UIColor(red:0.86, green:0.92, blue:1.00, alpha:1)),
          (0.40, UIColor(red:0.92, green:0.86, blue:0.98, alpha:1)),
          (0.60, UIColor(red:0.98, green:0.88, blue:0.90, alpha:1)),
          (0.80, UIColor(red:0.98, green:0.95, blue:0.84, alpha:1)),
          (1.00, UIColor(red:0.90, green:0.98, blue:0.88, alpha:1)) ]
    }
    private func auroraStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.02, green:0.03, blue:0.10, alpha:1)),
          (0.25, UIColor(red:0.00, green:0.40, blue:0.30, alpha:1)),
          (0.50, UIColor(red:0.10, green:0.75, blue:0.55, alpha:1)),
          (0.75, UIColor(red:0.40, green:0.85, blue:0.90, alpha:1)),
          (1.00, UIColor(red:0.85, green:0.95, blue:1.00, alpha:1)) ]
    }
    private func rainbowSmoothStops() -> [(CGFloat, UIColor)] {
        [ (0.00, .red), (0.17, .orange), (0.33, .yellow), (0.50, .green), (0.67, .blue), (0.83, .purple), (1.00, .red) ]
    }
    private func earthStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.14, green:0.08, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.25, green:0.16, blue:0.05, alpha:1)),
          (0.40, UIColor(red:0.38, green:0.26, blue:0.10, alpha:1)),
          (0.60, UIColor(red:0.52, green:0.36, blue:0.16, alpha:1)),
          (0.80, UIColor(red:0.70, green:0.55, blue:0.30, alpha:1)),
          (1.00, UIColor(red:0.90, green:0.82, blue:0.60, alpha:1)) ]
    }
    private func forestStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.02, green:0.12, blue:0.02, alpha:1)),
          (0.25, UIColor(red:0.05, green:0.28, blue:0.10, alpha:1)),
          (0.50, UIColor(red:0.10, green:0.45, blue:0.18, alpha:1)),
          (0.75, UIColor(red:0.25, green:0.60, blue:0.32, alpha:1)),
          (1.00, UIColor(red:0.75, green:0.90, blue:0.70, alpha:1)) ]
    }
    private func iceStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.07, blue:0.15, alpha:1)),
          (0.25, UIColor(red:0.10, green:0.34, blue:0.55, alpha:1)),
          (0.50, UIColor(red:0.40, green:0.75, blue:0.90, alpha:1)),
          (0.75, UIColor(red:0.75, green:0.92, blue:0.97, alpha:1)),
          (1.00, UIColor(red:0.95, green:0.98, blue:1.00, alpha:1)) ]
    }
    private func topoStops() -> [(CGFloat, UIColor)] {
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
    private func neonStops() -> [(CGFloat, UIColor)] {
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

    private func vibrantStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.05, green:0.02, blue:0.15, alpha:1)),
            (0.15, UIColor(red:0.20, green:0.00, blue:0.70, alpha:1)),
            (0.35, UIColor(red:0.00, green:0.60, blue:1.00, alpha:1)),
            (0.55, UIColor(red:0.00, green:0.90, blue:0.40, alpha:1)),
            (0.75, UIColor(red:1.00, green:0.80, blue:0.00, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.15, blue:0.10, alpha:1))
        ]
    }

    private func sunsetGlowStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.08, green:0.00, blue:0.15, alpha:1)),
            (0.18, UIColor(red:0.40, green:0.00, blue:0.40, alpha:1)),
            (0.38, UIColor(red:0.85, green:0.20, blue:0.40, alpha:1)),
            (0.60, UIColor(red:1.00, green:0.54, blue:0.10, alpha:1)),
            (0.82, UIColor(red:1.00, green:0.85, blue:0.25, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.98, blue:0.85, alpha:1))
        ]
    }

    private func candyStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.10, green:0.00, blue:0.20, alpha:1)),
            (0.20, UIColor(red:0.90, green:0.20, blue:0.75, alpha:1)),
            (0.40, UIColor(red:1.00, green:0.40, blue:0.50, alpha:1)),
            (0.60, UIColor(red:1.00, green:0.70, blue:0.30, alpha:1)),
            (0.80, UIColor(red:0.90, green:0.95, blue:0.40, alpha:1)),
            (1.00, UIColor(red:0.80, green:1.00, blue:0.95, alpha:1))
        ]
    }

    private func auroraBorealisStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.00, green:0.02, blue:0.07, alpha:1)),
            (0.18, UIColor(red:0.00, green:0.40, blue:0.35, alpha:1)),
            (0.36, UIColor(red:0.00, green:0.75, blue:0.65, alpha:1)),
            (0.58, UIColor(red:0.35, green:0.95, blue:0.90, alpha:1)),
            (0.78, UIColor(red:0.60, green:0.85, blue:1.00, alpha:1)),
            (1.00, UIColor(red:0.92, green:0.98, blue:1.00, alpha:1))
        ]
    }

    private func tropicalStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision with existing helper
        [
            (0.00, UIColor(red:0.00, green:0.10, blue:0.22, alpha:1)),
            (0.20, UIColor(red:0.00, green:0.55, blue:0.60, alpha:1)),
            (0.40, UIColor(red:0.00, green:0.85, blue:0.60, alpha:1)),
            (0.60, UIColor(red:0.95, green:0.80, blue:0.00, alpha:1)),
            (0.80, UIColor(red:1.00, green:0.50, blue:0.00, alpha:1)),
            (1.00, UIColor(red:0.90, green:0.10, blue:0.00, alpha:1))
        ]
    }

    private func flamingoStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision
        [
            (0.00, UIColor(red:0.18, green:0.02, blue:0.20, alpha:1)),
            (0.22, UIColor(red:0.80, green:0.10, blue:0.50, alpha:1)),
            (0.44, UIColor(red:1.00, green:0.40, blue:0.70, alpha:1)),
            (0.66, UIColor(red:1.00, green:0.70, blue:0.75, alpha:1)),
            (0.88, UIColor(red:1.00, green:0.90, blue:0.90, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    private func lagoonStopsNew() -> [(CGFloat, UIColor)] { // renamed to avoid collision
        [
            (0.00, UIColor(red:0.00, green:0.04, blue:0.10, alpha:1)),
            (0.18, UIColor(red:0.00, green:0.30, blue:0.60, alpha:1)),
            (0.36, UIColor(red:0.00, green:0.62, blue:0.80, alpha:1)),
            (0.62, UIColor(red:0.00, green:0.85, blue:0.75, alpha:1)),
            (0.82, UIColor(red:0.50, green:0.98, blue:0.90, alpha:1)),
            (1.00, UIColor.white)
        ]
    }

    private func cyberpunkStops() -> [(CGFloat, UIColor)] {
        [
            (0.00, UIColor(red:0.04, green:0.00, blue:0.08, alpha:1)),
            (0.20, UIColor(red:0.12, green:0.00, blue:0.55, alpha:1)),
            (0.40, UIColor(red:0.55, green:0.00, blue:0.85, alpha:1)),
            (0.60, UIColor(red:0.00, green:0.90, blue:0.95, alpha:1)),
            (0.80, UIColor(red:1.00, green:0.20, blue:0.60, alpha:1)),
            (1.00, UIColor(red:1.00, green:0.95, blue:0.90, alpha:1))
        ]
    }

    private func lavaStops() -> [(CGFloat, UIColor)] {
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
    private func metallicSilverStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.05, alpha:1)),
          (0.10, UIColor(white:0.30, alpha:1)),
          (0.22, UIColor(white:0.85, alpha:1)),
          (0.35, UIColor(white:0.35, alpha:1)),
          (0.50, UIColor(white:0.92, alpha:1)),
          (0.65, UIColor(white:0.40, alpha:1)),
          (0.78, UIColor(white:0.88, alpha:1)),
          (1.00, UIColor(white:0.15, alpha:1)) ]
    }
    private func chromeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.02, alpha:1)),
          (0.08, UIColor(white:0.25, alpha:1)),
          (0.16, UIColor(white:0.95, alpha:1)),
          (0.24, UIColor(white:0.20, alpha:1)),
          (0.32, UIColor(white:0.98, alpha:1)),
          (0.46, UIColor(white:0.18, alpha:1)),
          (0.64, UIColor(white:0.96, alpha:1)),
          (1.00, UIColor(white:0.10, alpha:1)) ]
    }
    private func goldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.07, blue:0.00, alpha:1)),
          (0.15, UIColor(red:0.55, green:0.38, blue:0.00, alpha:1)),
          (0.35, UIColor(red:0.95, green:0.78, blue:0.10, alpha:1)),
          (0.55, UIColor(red:1.00, green:0.88, blue:0.25, alpha:1)),
          (0.75, UIColor(red:0.80, green:0.60, blue:0.05, alpha:1)),
          (1.00, UIColor(red:0.20, green:0.15, blue:0.00, alpha:1)) ]
    }
    private func roseGoldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.14, green:0.05, blue:0.05, alpha:1)),
          (0.20, UIColor(red:0.60, green:0.30, blue:0.25, alpha:1)),
          (0.40, UIColor(red:0.95, green:0.65, blue:0.55, alpha:1)),
          (0.60, UIColor(red:1.00, green:0.80, blue:0.70, alpha:1)),
          (0.80, UIColor(red:0.70, green:0.40, blue:0.35, alpha:1)),
          (1.00, UIColor(red:0.18, green:0.08, blue:0.08, alpha:1)) ]
    }
    private func steelStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.05, alpha:1)),
          (0.20, UIColor(white:0.25, alpha:1)),
          (0.45, UIColor(white:0.70, alpha:1)),
          (0.65, UIColor(white:0.35, alpha:1)),
          (0.85, UIColor(white:0.80, alpha:1)),
          (1.00, UIColor(white:0.12, alpha:1)) ]
    }
    private func bronzeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.02, blue:0.00, alpha:1)),
          (0.20, UIColor(red:0.40, green:0.20, blue:0.05, alpha:1)),
          (0.45, UIColor(red:0.70, green:0.45, blue:0.15, alpha:1)),
          (0.70, UIColor(red:0.48, green:0.28, blue:0.10, alpha:1)),
          (0.90, UIColor(red:0.85, green:0.65, blue:0.35, alpha:1)),
          (1.00, UIColor(red:0.15, green:0.08, blue:0.03, alpha:1)) ]
    }
    private func copperStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.07, green:0.02, blue:0.00, alpha:1)),
          (0.20, UIColor(red:0.55, green:0.20, blue:0.05, alpha:1)),
          (0.45, UIColor(red:0.90, green:0.45, blue:0.15, alpha:1)),
          (0.65, UIColor(red:0.70, green:0.30, blue:0.10, alpha:1)),
          (0.85, UIColor(red:1.00, green:0.70, blue:0.45, alpha:1)),
          (1.00, UIColor(red:0.20, green:0.08, blue:0.03, alpha:1)) ]
    }
    private func titaniumStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.07, alpha:1)),
          (0.18, UIColor(white:0.25, alpha:1)),
          (0.36, UIColor(white:0.85, alpha:1)),
          (0.54, UIColor(white:0.30, alpha:1)),
          (0.72, UIColor(white:0.90, alpha:1)),
          (1.00, UIColor(white:0.10, alpha:1)) ]
    }
    private func mercuryStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.03, alpha:1)),
          (0.16, UIColor(white:0.25, alpha:1)),
          (0.33, UIColor(white:0.98, alpha:1)),
          (0.50, UIColor(white:0.20, alpha:1)),
          (0.66, UIColor(white:0.96, alpha:1)),
          (1.00, UIColor(white:0.08, alpha:1)) ]
    }
    private func pewterStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(white:0.06, alpha:1)),
          (0.25, UIColor(white:0.22, alpha:1)),
          (0.55, UIColor(white:0.65, alpha:1)),
          (0.75, UIColor(white:0.32, alpha:1)),
          (0.92, UIColor(white:0.78, alpha:1)),
          (1.00, UIColor(white:0.14, alpha:1)) ]
    }
    private func iridescentStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.00, blue:0.20, alpha:1)),
          (0.15, UIColor(red:0.00, green:0.65, blue:0.80, alpha:1)),
          (0.30, UIColor(red:0.60, green:0.20, blue:1.00, alpha:1)),
          (0.50, UIColor(red:1.00, green:0.40, blue:0.90, alpha:1)),
          (0.70, UIColor(red:0.10, green:0.90, blue:0.60, alpha:1)),
          (1.00, UIColor(red:0.95, green:0.95, blue:0.95, alpha:1)) ]
    }

    // ——— Gem / Extra Vivid ———
    private func sapphireStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.02, blue:0.10, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.20, blue:0.60, alpha:1)),
          (0.45, UIColor(red:0.10, green:0.45, blue:0.95, alpha:1)),
          (0.75, UIColor(red:0.60, green:0.85, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func emeraldStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.05, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.35, blue:0.18, alpha:1)),
          (0.45, UIColor(red:0.00, green:0.75, blue:0.40, alpha:1)),
          (0.75, UIColor(red:0.50, green:1.00, blue:0.75, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func rubyStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.00, blue:0.02, alpha:1)),
          (0.22, UIColor(red:0.50, green:0.00, blue:0.20, alpha:1)),
          (0.46, UIColor(red:0.90, green:0.05, blue:0.25, alpha:1)),
          (0.72, UIColor(red:1.00, green:0.50, blue:0.60, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func amethystStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.04, green:0.00, blue:0.08, alpha:1)),
          (0.25, UIColor(red:0.30, green:0.00, blue:0.60, alpha:1)),
          (0.50, UIColor(red:0.70, green:0.25, blue:1.00, alpha:1)),
          (0.80, UIColor(red:0.90, green:0.70, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func citrineStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.06, blue:0.00, alpha:1)),
          (0.22, UIColor(red:0.70, green:0.45, blue:0.00, alpha:1)),
          (0.46, UIColor(red:1.00, green:0.85, blue:0.10, alpha:1)),
          (0.72, UIColor(red:1.00, green:0.95, blue:0.60, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func jadeStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.06, blue:0.04, alpha:1)),
          (0.26, UIColor(red:0.00, green:0.35, blue:0.30, alpha:1)),
          (0.52, UIColor(red:0.00, green:0.85, blue:0.65, alpha:1)),
          (0.78, UIColor(red:0.50, green:1.00, blue:0.90, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func coralStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.10, green:0.02, blue:0.02, alpha:1)),
          (0.20, UIColor(red:0.85, green:0.25, blue:0.25, alpha:1)),
          (0.45, UIColor(red:1.00, green:0.55, blue:0.45, alpha:1)),
          (0.75, UIColor(red:1.00, green:0.85, blue:0.70, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func midnightStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.00, blue:0.02, alpha:1)),
          (0.25, UIColor(red:0.00, green:0.02, blue:0.15, alpha:1)),
          (0.50, UIColor(red:0.00, green:0.20, blue:0.45, alpha:1)),
          (0.75, UIColor(red:0.20, green:0.45, blue:0.85, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func solarFlareStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.05, green:0.02, blue:0.00, alpha:1)),
          (0.22, UIColor(red:0.75, green:0.30, blue:0.00, alpha:1)),
          (0.44, UIColor(red:1.00, green:0.70, blue:0.00, alpha:1)),
          (0.70, UIColor(red:1.00, green:0.90, blue:0.40, alpha:1)),
          (1.00, UIColor.white) ]
    }
    private func glacierStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.00, green:0.02, blue:0.05, alpha:1)),
          (0.20, UIColor(red:0.00, green:0.30, blue:0.60, alpha:1)),
          (0.45, UIColor(red:0.45, green:0.80, blue:1.00, alpha:1)),
          (0.75, UIColor(red:0.85, green:0.95, blue:1.00, alpha:1)),
          (1.00, UIColor.white) ]
    }

    @ViewBuilder
    private func floatingControls(_ geo: GeometryProxy) -> some View {
        let compact = (hSize == .compact)
        if compact {
            HStack(spacing: 14) {
                Button(action: { reset(geo.size) }) {
                    Image(systemName: "arrow.counterclockwise")
                        .imageScale(.large)
                        .padding(8)
                }
                .accessibilityLabel("Reset")
                Spacer(minLength: 8)
                Button(action: { saveCurrentSnapshot() }) {
                    Label("Save Image", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                Button(action: { showOptionsSheet = true }) {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .imageScale(.large)
                        .padding(8)
                }
                .accessibilityLabel("Options")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.15))
            )
            .shadow(radius: 10)
            .tint(.primary)
            .foregroundStyle(.primary)
        } else {
            // Regular: polished two-row floating bar (grouped)
            VStack(spacing: 10) {
                let narrow = geo.size.width < 980
                // Row 1 — Navigation • Modes • Iterations
                HStack(alignment: .firstTextBaseline, spacing: narrow ? 12 : 18) {
                    // Navigation
                    Button(action: { reset(geo.size) }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }

                    Divider().frame(height: 22).opacity(0.2)

                    // Modes (aligned labeled toggles)
                    HStack(spacing: 16) {
                        LabeledToggle(title: "Perturb",  systemImage: "bolt.circle", isOn: $perturbation)
                            .onChange(of: perturbation) { _, v in
                                vm.renderer?.setPerturbation(v); vm.requestDraw()
                            }
                        LabeledToggle(title: "Deep Zoom", systemImage: "scope", isOn: $deepZoom)
                            .onChange(of: deepZoom) { _, v in
                                vm.renderer?.setDeepZoom(v); vm.requestDraw()
                            }
                        LabeledToggle(title: "Auto Iter", systemImage: "aqi.medium", isOn: $autoIterations)
                    }

                    Divider().frame(height: 22).opacity(0.2)

                    // Iterations (slider + live value)
                    HStack(spacing: 10) {
                        Text("Iterations")
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)

                        Slider(value: iterBinding, in: 100...12000, step: 100)
                            .frame(width: min(max(geo.size.width * 0.25, 200), 360))

                        Text(autoIterations ? "\(effectiveIterations) (auto)" : "\(vm.maxIterations)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }

                    Spacer(minLength: 8)
                }

                // Row 2 — Color • Bookmarks • Export • Info
                HStack(alignment: .center, spacing: narrow ? 12 : 18) {
                    // Color
                    Button(action: { showPalettePicker = true }) {
                        HStack(spacing: 8) {
                            palettePreview(for: currentPaletteName)
                                .frame(width: 72, height: 18)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            Text("Palette")
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }

                    PhotosPicker(selection: $gradientItem, matching: .images) {
                        Label(narrow ? "Import" : "Import Gradient", systemImage: "photo.on.rectangle")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .onChange(of: gradientItem) { _, item in importGradientItem(item) }

                    // Bookmarks
                    Menu("Bookmarks") {
                        Button("Add Current…") { newBookmarkName = ""; showAddBookmark = true }
                        if !bookmarks.isEmpty {
                            Divider()
                            ForEach(bookmarks) { bm in
                                Button(bm.name) { applyBookmark(bm, size: geo.size) }
                            }
                            Divider()
                            Button("Clear All", role: .destructive) { bookmarks.removeAll(); saveBookmarks() }
                        }
                    }

                    Spacer(minLength: 8) // push Export group + Info to the right

                    // --- Export (Resolution next to Save) ---
                    HStack(spacing: 12) {
                        ResolutionSelector(selection: $snapRes)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: narrow ? 180 : 260)

                        if snapRes == .custom {
                            Button("Custom…") { showCustomRes = true }
                        }

                        // Prominent, visible Save button
                        Button(action: { saveCurrentSnapshot() }) {
                            Label(narrow ? "Save" : "Save Image", systemImage: "square.and.arrow.down")
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(minWidth: narrow ? 110 : 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)                 // make it clearly filled
                        .foregroundStyle(.white)            // ensure label/icon are readable
                        .controlSize(.regular)
                    }
                    .padding(.trailing, 4)

                    // Info
                    Menu {
                        Button(action: { showAbout = true }) { Label("About", systemImage: "info.circle") }
                        Button(action: { showHelp = true }) { Label("Help", systemImage: "questionmark.circle") }
                    } label: { Label("Info", systemImage: "info.circle") }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.15))
            )
            .shadow(radius: 10)
            .tint(.primary)
            .foregroundStyle(.primary)
            .compositingGroup()
            .onChange(of: snapRes) { _, newValue in
                if newValue == .custom { showCustomRes = true }
            }
        }
    }
    
    private var effectiveIterations: Int {
        let liveScale = vm.scalePixelsPerUnit * pendingScale
        return autoIterations ? autoIterationsForScale(liveScale) : vm.maxIterations
    }

    // Move the binding out of the ViewBuilder to avoid type-checker blowups
    private var iterBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(vm.maxIterations) },
            set: { newVal in
                vm.maxIterations = Int(newVal.rounded())
                vm.renderer?.setMaxIterations(vm.maxIterations)
                vm.requestDraw()
            }
        )
    }

    private var hud: some View {
        let compact = (hSize == .compact)
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text("Mandelbrot (Metal)")
                .font(compact ? Font.subheadline : Font.headline)
                .monospaced()
                .legibleText()
            Text("Center: x=\(fmt(vm.center.x)) y=\(fmt(vm.center.y))")
                .font(compact ? Font.caption2 : Font.caption)
                .monospaced()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .legibleText()
            Text("Scale: \(fmtZoom(vm.scalePixelsPerUnit))x")
                .font(compact ? Font.caption2 : Font.caption)
                .monospaced()
                .legibleText()
            Text(autoIterations ? "Iterations: \(effectiveIterations) (auto)" : "Iterations: \(vm.maxIterations)")
                .font(compact ? Font.caption2 : Font.caption)
                .monospaced()
                .legibleText()
        }
        .padding(compact ? 6 : 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.15))
        )
    }
    
    private func fmtZoom(_ x: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f.string(from: x as NSNumber) ?? String(format: "%.1f", x)
    }

    private func panAndZoom(_ size: CGSize) -> some Gesture {
        let pinch = MagnificationGesture()
            .onChanged { value in
                pendingScale = value
                liveUpdate(size: size)
            }
            .onEnded { value in
                applyPinch(value, size: size)
            }
        
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                pendingCenter = dragToComplex(value.translation)
                liveUpdate(size: size)
            }
            .onEnded { value in
                applyDrag(value, size: size)
            }
        
        return drag.simultaneously(with: pinch)
    }
    
    private func applyPinch(_ value: CGFloat, size: CGSize) {
        let factor = Double(value)
        vm.scalePixelsPerUnit *= factor
        pendingScale = 1.0
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        if autoIterations {
            vm.renderer?.setMaxIterations(autoIterationsForScale(vm.scalePixelsPerUnit))
        }
        vm.requestDraw()
    }
    
    private func applyDrag(_ value: DragGesture.Value, size: CGSize) {
        vm.center += dragToComplex(value.translation)
        pendingCenter = .zero
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        if autoIterations {
            vm.renderer?.setMaxIterations(autoIterationsForScale(vm.scalePixelsPerUnit))
        }
        vm.requestDraw()
    }
    
    private func autoIterationsForScale(_ scale: Double) -> Int {
        let base: Int = vm.maxIterations

        // Guard against tiny/NaN baselines in separate steps
        let baseline: Double = max(1e-9, vm.baselineScale)
        let ratio: Double = scale / baseline
        let clampedRatio: Double = max(1.0, ratio)
        let L: Double = max(0.0, log10(clampedRatio)) // decades beyond baseline

        // Tunables (typed)
        let startBoost: Double = 250.0
        let slope: Double      = 900.0   // per 10×
        let quad: Double       = 350.0   // grows with L^2

        // Split the boost pieces so the type-checker doesn’t expand a giant tree
        let linearPart: Double = slope * L
        let quadPart: Double   = quad * (L * L)
        let rawBoost: Double   = startBoost + linearPart + quadPart
        let boost: Int         = max(0, Int(rawBoost.rounded()))

        let target: Int = base + boost
        let capped: Int = min(50_000, max(base, target))
        return capped
    }
    
    private func liveUpdate(size: CGSize) {
        var center = vm.center + pendingCenter
        var scale = vm.scalePixelsPerUnit * pendingScale
        scale = max(0.01, min(scale, 1e12))
        center.x = clamp(center.x, -3.0, 3.0)
        center.y = clamp(center.y, -3.0, 3.0)
        
        let it = autoIterations ? autoIterationsForScale(scale) : vm.maxIterations
        vm.renderer?.setViewport(center: center,
                                 scalePixelsPerUnit: scale,
                                 sizePts: currentPointsSize(size),
                                 screenScale: currentScreenScale(),
                                 maxIterations: it)
        vm.requestDraw()
    }
    
    private func doubleTapZoom(point: CGPoint, size: CGSize, factor: Double) {
        let ds = vm.mtkView?.drawableSize
        let pxW = ds?.width ?? floor(size.width * currentScreenScale())
        let pxH = ds?.height ?? floor(size.height * currentScreenScale())
        let s = Double(pxW / size.width)   // pixels-per-point actually in use
        let pixelW = Double(pxW)
        let pixelH = Double(pxH)
        let invScale = 1.0 / vm.scalePixelsPerUnit
        
        let halfW = 0.5 * pixelW
        let halfH = 0.5 * pixelH
        
        let cxBefore = (Double(point.x) * s - halfW) * invScale + vm.center.x
        let cyBefore = (Double(point.y) * s - halfH) * invScale + vm.center.y
        
        vm.scalePixelsPerUnit *= factor
        
        let invScaleAfter = 1.0 / vm.scalePixelsPerUnit
        let cxAfter = (Double(point.x) * s - halfW) * invScaleAfter + vm.center.x
        let cyAfter = (Double(point.y) * s - halfH) * invScaleAfter + vm.center.y
        
        vm.center += SIMD2<Double>(cxBefore - cxAfter, cyBefore - cyAfter)
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        vm.requestDraw()
    }

    private func recenterAtTap(_ point: CGPoint, size: CGSize) {
        let ds = vm.mtkView?.drawableSize
        let pxW = ds?.width ?? floor(size.width * currentScreenScale())
        let pxH = ds?.height ?? floor(size.height * currentScreenScale())
        let s = Double(pxW / size.width)
        let pixelW = Double(pxW)
        let pixelH = Double(pxH)
        let invScale = 1.0 / vm.scalePixelsPerUnit
        let halfW = 0.5 * pixelW
        let halfH = 0.5 * pixelH
        let cx = (Double(point.x) * s - halfW) * invScale + vm.center.x
        let cy = (Double(point.y) * s - halfH) * invScale + vm.center.y
        vm.renderer?.recenterReference(atComplex: SIMD2<Double>(cx, cy), iterations: vm.maxIterations)
        vm.requestDraw()
    }

    private func applyBookmark(_ bm: Bookmark, size: CGSize) {
        vm.center = bm.center
        vm.scalePixelsPerUnit = bm.scale
        palette = bm.palette
        deepZoom = bm.deep
        perturbation = bm.perturb
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        vm.renderer?.setPalette(palette)
        vm.renderer?.setDeepZoom(deepZoom)
        vm.renderer?.setPerturbation(perturbation)
        currentPaletteName = (palette == 0 ? "HSV" : palette == 1 ? "Fire" : palette == 2 ? "Ocean" : currentPaletteName)
        vm.requestDraw()
    }
    
    private func reset(_ size: CGSize) {
        // Viewport back to default
        vm.center = SIMD2(-0.5, 0.0)
        vm.scalePixelsPerUnit = 1

        // Reset iterations to minimum and restart auto-iter baseline
        vm.maxIterations = 100
        vm.baselineScale = 1   // so autoIterations recalibrates from the new start

        // Apply to renderer immediately
        vm.renderer?.setMaxIterations(vm.maxIterations)

        // Push + draw
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        vm.requestDraw()
    }
    
    private func dragToComplex(_ translation: CGSize) -> SIMD2<Double> {
        let s = currentScreenScale()
        let dx = Double(translation.width)  * Double(s)
        let dy = Double(translation.height) * Double(s)
        let invScale = 1.0 / vm.scalePixelsPerUnit
        return SIMD2<Double>(-dx * invScale, -dy * invScale)
    }
    
    private let kBookmarks = "bookmarks_v1"

    private func importGradientItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                vm.renderer?.setPaletteImage(img)
                vm.renderer?.setPalette(3)
                vm.requestDraw()
            }
        }
    }
    private func saveBookmarks() {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            UserDefaults.standard.set(data, forKey: kBookmarks)
        } catch {
            print("[BM] save failed: \(error)")
        }
    }
    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: kBookmarks) else { return }
        do {
            bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            print("[BM] load failed: \(error)")
        }
    }

    private func saveCurrentSnapshot() {
        // Determine output dimensions from picker
        let dims: (Int, Int)
        switch snapRes {
        case .r4k: dims = (3840, 2160)
        case .r6k: dims = (5760, 3240)
        case .r8k: dims = (7680, 4320)
        case .custom:
            let w = Int(customW) ?? 3840
            let h = Int(customH) ?? 2160
            dims = (w, h)
        }
        let w = dims.0
        let h = dims.1

        // Choose tiled path for very large images
        let totalPixels = w * h
        let useTiled = totalPixels > (3840 * 2160)

        var image: UIImage? = nil
        if useTiled {
            image = vm.renderer?.makeSnapshotTiled(width: w,
                                                   height: h,
                                                   tile: 1024,
                                                   center: vm.center,
                                                   scalePixelsPerUnit: vm.scalePixelsPerUnit,
                                                   iterations: vm.maxIterations)
        } else {
            image = vm.renderer?.makeSnapshot(width: w,
                                              height: h,
                                              center: vm.center,
                                              scalePixelsPerUnit: vm.scalePixelsPerUnit,
                                              iterations: vm.maxIterations)
        }

        guard let img = image else { print("[UI] snapshot failed (nil image)"); return }
        guard let data = img.pngData() else { print("[UI] pngData() failed"); return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm" // safe filename
        let fname = "MandelMetal_\(df.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fname)
        do {
            try data.write(to: url, options: .atomic)
            snapshotURL = url
            snapshotImage = nil
            shareItems = [url]

            // present share sheet; user can choose “Save Image” if they want Photos
            DispatchQueue.main.async { showShare = true }

            print("[UI] wrote snapshot -> \(url.lastPathComponent)")
        } catch {
            print("[UI] failed to write snapshot: \(error)")
        }
    }

    private func appCopyright() -> String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, !s.isEmpty {
            return s
        }
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Michael Stebel. All rights reserved."
    }

    private func appVersionBuild() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))"
    }

    private func fmt(_ x: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        return f.string(from: x as NSNumber) ?? "\(x)"
    }
    
    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
}

// MARK: - High-Contrast Toggle Style
struct AccessibleSwitchToggleStyle: ToggleStyle {
    var onColor: Color = .accentColor
    var offColor: Color = Color(UIColor.systemGray3).opacity(0.95)
    var knobColor: Color = .white
    var borderColor: Color = .black.opacity(0.25)
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let width = height * 1.75
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                configuration.isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(isOn ? onColor : offColor)
                RoundedRectangle(cornerRadius: height / 2)
                    .stroke(borderColor, lineWidth: 1)
                Circle()
                    .fill(knobColor)
                    .frame(width: height - 4, height: height - 4)
                    .shadow(radius: 0.6, y: 0.6)
                    .padding(2)
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// Small helper to align a switch with its label and icon consistently
private struct LabeledToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(AccessibleSwitchToggleStyle())
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: - Legibility Modifier
extension View {
    /// Boost text/icon legibility over busy backgrounds
    func legibleText() -> some View {
        self
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
    }
}

private struct HelpView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                sectionHeader("Getting Started")
                Text("Pinch to zoom, drag to pan. Double‑tap to zoom in at the tap point. Long‑press to rebuild the **perturbation reference** at the current center.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                sectionHeader("Navigation & Gestures")
                bullet("Magnify", "pinch")
                bullet("Pan", "hand.draw")
                bullet("Zoom at point (×2)", "touchid")
                bullet("Recenter perturbation", "hand.point.up.left.fill", suffix: "Long‑press")
                bullet("Tap‑to‑recenter perturbation", "cursorarrow.rays", suffix: "Single tap anywhere")

                sectionHeader("Rendering Modes")
                Text("**Perturbation** stabilizes ultra‑deep zooms by computing differences from a nearby reference orbit. **Deep Zoom** switches the kernel into double‑single math for more precision.")
                    .foregroundStyle(.primary)

                sectionHeader("Color & Palettes")
                Text("Choose **HSV**, **Fire**, or **Ocean** palettes. Import a custom gradient (LUT) via **Import Gradient**.")
                    .foregroundStyle(.primary)

                sectionHeader("Iterations")
                Text("Use the **Iterations** stepper to adjust detail. Turn on **Auto Iter** to increase iterations automatically with zoom (about **+400 per 10×** beyond your starting zoom).")
                    .foregroundStyle(.primary)

                sectionHeader("Snapshots & Export")
                Text("Use **Resolution → Save** for 4K/6K/8K. Larger sizes use tiled export to avoid memory spikes. Files are named \"MandelMetal_yyyy‑mm‑dd_HH‑mm.png\" and can be shared from the sheet.")
                    .foregroundStyle(.primary)

                sectionHeader("Bookmarks")
                Text("Save the current view (center, zoom, palette, modes) and recall it from **Bookmarks**.")
                    .foregroundStyle(.primary)

                sectionHeader("Performance Tips")
                bullet("Start simple", "speedometer", suffix: "Explore with moderate iterations; export high‑res later.")
                bullet("Use perturbation for deep zooms", "bolt.fill")
                bullet("Prefer 6K over 8K on older devices", "rectangle.on.rectangle")

                sectionHeader("Troubleshooting")
                bullet("Black screen", "exclamationmark.triangle", suffix: "Ensure iterations aren’t extremely high; try Reset.")
                bullet("Stale color after import", "paintpalette", suffix: "After importing a gradient, ensure the LUT option is active if available.")
                bullet("Blur at extreme zoom", "scope", suffix: "Enable Deep Zoom and tap/long‑press to recenter perturbation.")

                Divider().padding(.vertical, 4)
                Text(appMeta())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(compact ? 16 : 20)
        }
    }

    // MARK: UI helpers
    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().frame(width: 3)
            Text(title).font(compact ? .headline : .title3).bold()
        }
        .foregroundStyle(.secondary)
        .padding(.top, compact ? 6 : 8)
    }

    @ViewBuilder private func bullet(_ title: String, _ symbol: String, suffix: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            if let suffix { Text("**\(title)** — \(suffix)") } else { Text("**\(title)**") }
        }
        .font(compact ? .caption : .body)
    }

    private func appMeta() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))"
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Photo Library Saving Helper
enum PhotoSaveError: Error {
    case notAuthorized
    case writeFailed(Error?)
}

final class PhotoSaver {
    static let shared = PhotoSaver()

    /// Requests add-only permission if needed, then saves the image to Photos.
    func saveToPhotos(_ image: UIImage, completion: @escaping (Result<Void, PhotoSaveError>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(.notAuthorized)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, err in
                DispatchQueue.main.async {
                    ok ? completion(.success(())) : completion(.failure(.writeFailed(err)))
                }
            })
        }
    }
}

private struct PalettePickerView: View {
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
private struct PaletteSwatchButton: View {
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

// MARK: - Resolution Selector (Segmented)
private struct ResolutionSelector: View {
    @Binding var selection: ContentView.SnapshotRes

    var body: some View {
        Picker("Resolution", selection: $selection) {
            Text("4K").tag(ContentView.SnapshotRes.r4k)
            Text("6K").tag(ContentView.SnapshotRes.r6k)
            Text("8K").tag(ContentView.SnapshotRes.r8k)
            Text("Custom").tag(ContentView.SnapshotRes.custom)
        }
        .pickerStyle(.segmented)
        .lineLimit(1)
        .minimumScaleFactor(0.95)
    }
}

// MARK: - Compact Options Sheet (iPhone)
private struct CompactOptionsSheet: View {
    @Binding var currentPaletteName: String
    @Binding var showPalettePicker: Bool
    @Binding var autoIterations: Bool
    @Binding var iterations: Int
    @Binding var perturbation: Bool
    @Binding var deepZoom: Bool
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
                    HStack {
                        Label("Perturbation", systemImage: "bolt.circle")
                        Spacer()
                        Toggle("", isOn: $perturbation)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                    }
                    HStack {
                        Label("Deep Zoom", systemImage: "scope")
                        Spacer()
                        Toggle("", isOn: $deepZoom)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                    }
                } header: {
                    Text("Modes")
                }

                Section {
                    Stepper(value: $iterations, in: 100...12000, step: 100) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ResolutionSelector(selection: $snapRes)
                            if snapRes == .custom {
                                Button("Custom…") { onCustom() }
                            }
                        }
                        Button {
                            onSave()
                        } label: {
                            Label("Save Image", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("Export")
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
