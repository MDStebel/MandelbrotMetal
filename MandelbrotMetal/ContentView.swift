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
        let pixelW = max(1, Int(wD.rounded()))

        let workingScale: Double
        if scalePixelsPerUnit == 1 {
            workingScale = Double(pixelW) / 3.5
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
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
        guard let renderer = MandelbrotRenderer(mtkView: view) else { return view }
        vm.attachRenderer(renderer)
        vm.attachView(view)
        return view
    }
    
    @MainActor
    func updateUIView(_ uiView: MTKView, context: Context) {
        vm.pushViewport(uiView.bounds.size,
                        screenScale: uiView.window?.screen.scale ?? UIScreen.main.scale)
        let scale = uiView.window?.screen.scale ?? UIScreen.main.scale
        let sizePts = uiView.bounds.size
        let sizePx = CGSize(width: max(1, sizePts.width * scale),
                            height: max(1, sizePts.height * scale))
        uiView.drawableSize = sizePx
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

    enum SnapshotRes: String, CaseIterable, Identifiable { case r4k="4K (3840×2160)", r6k="6K (5760×3240)", r8k="8K (7680×4320)", custom="Custom…"; var id: String { rawValue } }
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
                vm.pushViewport(geo.size, screenScale: UIScreen.main.scale)
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
                vm.pushViewport(newSize, screenScale: UIScreen.main.scale)
            }
            .onChange(of: perturbation) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: deepZoom) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: palette) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.center) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.scalePixelsPerUnit) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .onChange(of: vm.maxIterations) { _, _ in vm.saveState(perturb: perturbation, deep: deepZoom, palette: palette) }
            .toolbar { }
            .sheet(isPresented: $showPalettePicker) {
                NavigationView {
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
                NavigationView {
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
                NavigationView {
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
                NavigationView {
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
            .sheet(isPresented: .constant(false)) { EmptyView() } // placeholder to keep chaining stable
            .sheet(isPresented: $showOptionsSheet) {
                CompactOptionsSheet(
                    currentPaletteName: $currentPaletteName,
                    showPalettePicker: $showPalettePicker,
                    autoIterations: $autoIterations,
                    iterations: $vm.maxIterations,
                    perturbation: $perturbation,
                    deepZoom: $deepZoom,
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
                    onClose: { showOptionsSheet = false }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func fractalCanvas(_ geo: GeometryProxy) -> some View {
        MetalFractalView(vm: vm)
            .contentShape(Rectangle())
            .gesture(panAndZoom(geo.size))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    vm.renderer?.recenterReference(atComplex: vm.center, iterations: vm.maxIterations)
                    vm.requestDraw()
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    recenterAtTap(value.location, size: geo.size)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    doubleTapZoom(point: value.location, size: geo.size, factor: 2.0)
                }
            )
    }

    // Helper to provide compact/regular palette labels with accessibility support
    private func paletteLabel(_ index: Int) -> some View {
        let compact = (hSize == .compact)
        let title: String
        let a11y: String
        switch index {
        case 0:
            title = "HSV"; a11y = "HSV"
        case 1:
            title = compact ? "🔥" : "Fire"; a11y = "Fire"
        case 2:
            title = compact ? "🌊" : "Ocean"; a11y = "Ocean"
        default:
            title = "LUT"; a11y = "LUT"
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
            // Built-ins
            PaletteOption(name: "HSV",     builtInIndex: 0, stops: hsvStops()),
            PaletteOption(name: "Fire",    builtInIndex: 1, stops: fireStops()),
            PaletteOption(name: "Ocean",   builtInIndex: 2, stops: oceanStops()),
            // Scientific maps
            PaletteOption(name: "Magma",   builtInIndex: nil, stops: magmaStops()),
            PaletteOption(name: "Inferno", builtInIndex: nil, stops: infernoStops()),
            PaletteOption(name: "Plasma",  builtInIndex: nil, stops: plasmaStops()),
            PaletteOption(name: "Viridis", builtInIndex: nil, stops: viridisStops()),
            PaletteOption(name: "Turbo",   builtInIndex: nil, stops: turboStops()),
            PaletteOption(name: "Cubehelix", builtInIndex: nil, stops: cubehelixStops()),
            // Artistic maps
            PaletteOption(name: "Sunset",  builtInIndex: nil, stops: sunsetStops()),
            PaletteOption(name: "Pastel",  builtInIndex: nil, stops: pastelStops()),
            PaletteOption(name: "Aurora",  builtInIndex: nil, stops: auroraStops()),
            PaletteOption(name: "Rainbow", builtInIndex: nil, stops: rainbowSmoothStops()),
            // Natural maps
            PaletteOption(name: "Earth",   builtInIndex: nil, stops: earthStops()),
            PaletteOption(name: "Forest",  builtInIndex: nil, stops: forestStops()),
            PaletteOption(name: "Ice",     builtInIndex: nil, stops: iceStops()),
            // Utility
            PaletteOption(name: "Topo",    builtInIndex: nil, stops: topoStops()),
            PaletteOption(name: "Grayscale", builtInIndex: nil, stops: grayscaleStops())
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

    // Palette stop generators (simple, smooth approximations)
    private func hsvStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor.red), (0.17, UIColor.yellow), (0.33, UIColor.green), (0.50, UIColor.cyan), (0.67, UIColor.blue), (0.83, UIColor.magenta), (1.00, UIColor.red) ]
    }
    private func fireStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor.black), (0.15, UIColor.red), (0.50, UIColor.orange), (0.85, UIColor.yellow), (1.00, UIColor.white) ]
    }
    private func oceanStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor.black), (0.15, UIColor.blue), (0.45, UIColor.systemTeal), (0.75, UIColor.cyan), (1.00, UIColor.white) ]
    }
    private func magmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.015, alpha:1)), (0.25, UIColor(red:0.090, green:0.022, blue:0.147, alpha:1)), (0.50, UIColor(red:0.355, green:0.110, blue:0.312, alpha:1)), (0.75, UIColor(red:0.722, green:0.235, blue:0.196, alpha:1)), (1.00, UIColor(red:0.987, green:0.940, blue:0.749, alpha:1)) ]
    }
    private func infernoStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.001, green:0.000, blue:0.013, alpha:1)), (0.25, UIColor(red:0.102, green:0.019, blue:0.201, alpha:1)), (0.50, UIColor(red:0.591, green:0.125, blue:0.208, alpha:1)), (0.75, UIColor(red:0.949, green:0.526, blue:0.132, alpha:1)), (1.00, UIColor(red:0.988, green:0.998, blue:0.645, alpha:1)) ]
    }
    private func plasmaStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.050, green:0.030, blue:0.527, alpha:1)), (0.25, UIColor(red:0.541, green:0.016, blue:0.670, alpha:1)), (0.50, UIColor(red:0.884, green:0.206, blue:0.380, alpha:1)), (0.75, UIColor(red:0.993, green:0.666, blue:0.237, alpha:1)), (1.00, UIColor(red:0.940, green:0.975, blue:0.131, alpha:1)) ]
    }
    private func viridisStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.267, green:0.005, blue:0.329, alpha:1)), (0.25, UIColor(red:0.283, green:0.141, blue:0.458, alpha:1)), (0.50, UIColor(red:0.254, green:0.265, blue:0.530, alpha:1)), (0.75, UIColor(red:0.127, green:0.566, blue:0.550, alpha:1)), (1.00, UIColor(red:0.993, green:0.904, blue:0.144, alpha:1)) ]
    }
    private func turboStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor(red:0.189, green:0.071, blue:0.232, alpha:1)), (0.25, UIColor(red:0.216, green:0.460, blue:0.996, alpha:1)), (0.50, UIColor(red:0.500, green:0.891, blue:0.158, alpha:1)), (0.75, UIColor(red:0.994, green:0.760, blue:0.000, alpha:1)), (1.00, UIColor(red:0.498, green:0.054, blue:0.000, alpha:1)) ]
    }
    private func cubehelixStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor.black), (0.25, UIColor.darkGray), (0.50, UIColor.systemGreen), (0.75, UIColor.systemPurple), (1.00, UIColor.white) ]
    }
    private func grayscaleStops() -> [(CGFloat, UIColor)] {
        [ (0.00, UIColor.black), (1.00, UIColor.white) ]
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
        [ (0.00, UIColor.red),
          (0.17, UIColor.orange),
          (0.33, UIColor.yellow),
          (0.50, UIColor.green),
          (0.67, UIColor.blue),
          (0.83, UIColor.purple),
          (1.00, UIColor.red) ]
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
                    Image(systemName: "square.and.arrow.down")
                        .imageScale(.large)
                        .padding(8)
                }
                .accessibilityLabel("Save")
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
            // Regular: two-row floating bar
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button(action: { showAbout = true }) { Label("About", systemImage: "info.circle") }
                    Button(action: { showHelp = true }) { Label("Help", systemImage: "questionmark.circle") }
                    Button(action: { reset(geo.size) }) { Label("Reset", systemImage: "arrow.counterclockwise") }
                    PhotosPicker(selection: $gradientItem, matching: .images) {
                        Label("Import Gradient", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: gradientItem) { _, item in importGradientItem(item) }
                    Spacer(minLength: 8)
                    Button(action: { showPalettePicker = true }) {
                        HStack(spacing: 8) {
                            palettePreview(for: currentPaletteName)
                                .frame(width: 64, height: 18)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            Text("Palette")
                        }
                    }
                    Button(action: { saveCurrentSnapshot() }) { Label("Save", systemImage: "square.and.arrow.up") }
                }
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $perturbation)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                            .onChange(of: perturbation) { _, v in
                                vm.renderer?.setPerturbation(v)
                                vm.requestDraw()
                            }
                        Label("Perturb", systemImage: "bolt.circle")
                    }
                    HStack(spacing: 8) {
                        Toggle("", isOn: $deepZoom)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                            .onChange(of: deepZoom) { _, v in
                                vm.renderer?.setDeepZoom(v)
                                vm.requestDraw()
                            }
                        Label("Deep Zoom", systemImage: "scope")
                    }
                    Stepper(value: $vm.maxIterations, in: 200...4000, step: 100, onEditingChanged: { _ in
                        vm.renderer?.setMaxIterations(vm.maxIterations)
                        vm.requestDraw()
                    }) { Text(autoIterations ? "Iterations: \(effectiveIterations) (auto)" : "Iterations: \(vm.maxIterations)") }
                    HStack(spacing: 8) {
                        Toggle("", isOn: $autoIterations)
                            .labelsHidden()
                            .toggleStyle(AccessibleSwitchToggleStyle())
                        Text("Auto Iter")
                    }
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
                    Menu("Resolution") {
                        Picker("Resolution", selection: $snapRes) {
                            ForEach(SnapshotRes.allCases) { opt in Text(opt.rawValue).tag(opt) }
                        }
                        Button("Custom…") { showCustomRes = true }
                    }
                }
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
        }
    }
    
    private var effectiveIterations: Int {
        // Use live scale (includes in-gesture magnification) so the HUD updates while pinching
        let liveScale = vm.scalePixelsPerUnit * pendingScale
        return autoIterations ? autoIterationsForScale(liveScale) : vm.maxIterations
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
            Text(String(format: "Scale: %.2fx", vm.scalePixelsPerUnit))
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
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        if autoIterations {
            vm.renderer?.setMaxIterations(autoIterationsForScale(vm.scalePixelsPerUnit))
        }
        vm.requestDraw()
    }
    
    private func applyDrag(_ value: DragGesture.Value, size: CGSize) {
        vm.center += dragToComplex(value.translation)
        pendingCenter = .zero
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        if autoIterations {
            vm.renderer?.setMaxIterations(autoIterationsForScale(vm.scalePixelsPerUnit))
        }
        vm.requestDraw()
    }
    
    private func autoIterationsForScale(_ scale: Double) -> Int {
        let base = vm.maxIterations
        let mag = max(1.0, scale / max(1e-9, vm.baselineScale))
        let boost = Int(400.0 * log10(mag)) // +400 per 10× zoom beyond baseline
        let target = base + max(0, boost)
        return min(12_000, max(base, target))
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
                                 sizePts: size,
                                 screenScale: UIScreen.main.scale,
                                 maxIterations: it)
        vm.requestDraw()
    }
    
    private func doubleTapZoom(point: CGPoint, size: CGSize, factor: Double) {
        let s = Double(UIScreen.main.scale)
        let pixelW = Double(size.width) * s
        let pixelH = Double(size.height) * s
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
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        vm.requestDraw()
    }

    private func recenterAtTap(_ point: CGPoint, size: CGSize) {
        let s = Double(UIScreen.main.scale)
        let pixelW = Double(size.width) * s
        let pixelH = Double(size.height) * s
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
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        vm.renderer?.setPalette(palette)
        vm.renderer?.setDeepZoom(deepZoom)
        vm.renderer?.setPerturbation(perturbation)
        currentPaletteName = (palette == 0 ? "HSV" : palette == 1 ? "Fire" : palette == 2 ? "Ocean" : currentPaletteName)
        vm.requestDraw()
    }
    
    private func reset(_ size: CGSize) {
        vm.center = SIMD2(-0.5, 0.0)
        vm.scalePixelsPerUnit = 1
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        vm.requestDraw()
    }
    
    private func dragToComplex(_ translation: CGSize) -> SIMD2<Double> {
        let s = UIScreen.main.scale
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
            DispatchQueue.main.async {
                showShare = true
            }
            print("[UI] wrote snapshot -> \(url.lastPathComponent)")

            // ALSO save to the user's Photos library (add-only permission)
            PhotoSaver.shared.saveToPhotos(img) { result in
                switch result {
                case .success:
                    print("✅ Saved to Photos")
                case .failure(let err):
                    print("❌ Photos save failed: \(err)")
                }
            }
        } catch {
            print("[UI] failed to write snapshot: \(error)")
        }
    }

    private func appCopyright() -> String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, !s.isEmpty {
            return s
        }
        // Fallback if the key is missing
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
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
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
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
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

    let paletteOptions: [ContentView.PaletteOption]
    let applyPalette: (ContentView.PaletteOption) -> Void
    let onImportGradient: (PhotosPickerItem?) -> Void
    let onSave: () -> Void
    let onAbout: () -> Void
    let onHelp: () -> Void
    let onClose: () -> Void

    @State private var localGradientItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationView {
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
                    Stepper(value: $iterations, in: 200...12000, step: 100) {
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
                    Button {
                        onSave()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save Image")
                        }
                    }
                } header: {
                    Text("Export")
                }

                Section {
                    Button {
                        onAbout()
                    } label: { Label("About", systemImage: "info.circle") }
                    Button {
                        onHelp()
                    } label: { Label("Help", systemImage: "questionmark.circle") }
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
