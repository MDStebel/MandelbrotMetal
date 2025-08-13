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
        view.autoResizeDrawable = true

        guard let renderer = MandelbrotRenderer(mtkView: view) else { return view }
        vm.attachRenderer(renderer)
        vm.attachView(view)

        // Ensure an initial draw happens even before the first interaction
        DispatchQueue.main.async { [weak vm] in
            guard let vm else { return }
            let nominalScale = view.window?.screen.scale ?? UIScreen.main.scale
            let sizePts = view.bounds.size
            let sizePx = CGSize(
                width: floor(max(1, sizePts.width  * nominalScale)),
                height: floor(max(1, sizePts.height * nominalScale))
            )
            view.drawableSize = sizePx
            vm.pushViewport(sizePts, screenScale: nominalScale)
            vm.requestDraw()
        }

        return view
    }

    @MainActor
    func updateUIView(_ uiView: MTKView, context: Context) {
        // Let MTKView manage its drawable size (autoResizeDrawable = true)
        let scale = uiView.window?.screen.scale ?? UIScreen.main.scale
        vm.pushViewport(uiView.bounds.size, screenScale: scale)
        vm.requestDraw()
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = FractalVM()
    @State private var pendingCenter = SIMD2<Double>(0, 0)
    @State private var pendingScale  = 1.0
    @State private var palette = 0 // 0=HSV, 1=Fire, 2=Ocean
    @State private var gradientItem: PhotosPickerItem? = nil
    @State private var showPalettePicker = false
    @State private var currentPaletteName: String = "HSV" // tracks UI label for palette
    @State private var snapshotImage: UIImage? = nil
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var snapshotURL: URL? = nil
    @State private var showAbout = false
    @State private var showHelp = false
    @State private var autoIterations = false
    @State private var showOptionsSheet = false
    @State private var showCaptureSheet = false
    @State private var isCapturing = false
    @State private var preserveAspect: Bool = true
    struct Bookmark: Codable, Identifiable { var id = UUID(); var name: String; var center: SIMD2<Double>; var scale: Double; var palette: Int; var deep: Bool; var perturb: Bool }
    @State private var bookmarks: [Bookmark] = []
    @State private var showAddBookmark = false
    @State private var newBookmarkName: String = ""
    @State private var fallbackBanner: String? = nil
    @State private var fallbackObserver: NSObjectProtocol? = nil
    @State private var sizeChangeWork: DispatchWorkItem? = nil
    @State private var lastPushedPointsSize: CGSize = .zero
    @State private var contrast: Double = 1.0

    enum SnapshotRes: String, CaseIterable, Identifiable {
        case canvas = "Canvas"
        case r4k    = "4K (3840×2160)"
        case r6k    = "6K (5760×3240)"
        case r8k    = "8K (7680×4320)"
        case custom = "Custom…"
        var id: String { rawValue }
    }
    @State private var snapRes: SnapshotRes = .r4k
    @State private var customW: String = "3840"
    @State private var customH: String = "2160"
    @State private var showCustomRes = false
    private let kPaletteNameKey = "palette_name_v1"
    @State private var highQualityIdleRender: Bool = true
    private let kContrastKey = "contrast_v1"
    @State private var isInteracting: Bool = false
    private let kHQIdleKey = "hq_idle_render_v1"
    
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
                // Progress overlay during capture
                if isCapturing {
                    VStack(spacing: 12) {
                        ProgressView("Rendering…")
                            .progressViewStyle(.circular)
                        Text("Preparing image, please wait")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .onAppear {
                if let s = vm.loadState() {
                    // Deep Zoom is always on now; ignore saved flag
                    palette = s.palette
                }
                vm.pushViewport(currentPointsSize(geo.size), screenScale: currentScreenScale())
                vm.requestDraw()
                vm.renderer?.setDeepZoom(true)
                vm.renderer?.setHighQualityIdle(highQualityIdleRender)
                vm.renderer?.setInteractive(false, baseIterations: vm.maxIterations)

                // Restore palette by saved name if available; otherwise fall back to index
                if let savedName = UserDefaults.standard.string(forKey: kPaletteNameKey),
                   let opt = paletteOptions.first(where: { $0.name == savedName }) {
                    applyPaletteOption(opt) // rebuild LUT or select GPU built‑in
                } else {
                    vm.renderer?.setPalette(palette)
                    currentPaletteName = (palette == 0 ? "HSV" : palette == 1 ? "Fire" : palette == 2 ? "Ocean" : currentPaletteName)
                    vm.requestDraw()
                }
                if UserDefaults.standard.object(forKey: kHQIdleKey) != nil {
                    highQualityIdleRender = UserDefaults.standard.bool(forKey: kHQIdleKey)
                }
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
                // Restore contrast if present
                if UserDefaults.standard.object(forKey: kContrastKey) != nil {
                    contrast = max(0.5, min(2.0, UserDefaults.standard.double(forKey: kContrastKey)))
                    // Apply to current palette selection
                    applyContrastIfNeeded()
                }
            }
            .onDisappear {
                if let obs = fallbackObserver {
                    NotificationCenter.default.removeObserver(obs)
                    fallbackObserver = nil
                }
            }
            .onChange(of: geo.size) { _, newSize in
                // Debounce resize notifications and avoid 1px thrash that causes canvas jumps
                sizeChangeWork?.cancel()
                let work = DispatchWorkItem { [weak vm] in
                    guard let vm else { return }
                    let pts = currentPointsSize(newSize)
                    // Only push if the points value changed meaningfully (> 0.25pt)
                    let dx = abs(pts.width  - lastPushedPointsSize.width)
                    let dy = abs(pts.height - lastPushedPointsSize.height)
                    if dx > 0.25 || dy > 0.25 {
                        lastPushedPointsSize = pts
                        vm.pushViewport(pts, screenScale: currentScreenScale())
                        vm.requestDraw()
                    }
                }
                sizeChangeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
            .onChange(of: palette) { _, newValue in
                persistPaletteSelection()
                vm.renderer?.setPalette(newValue)
                vm.requestDraw()
            }
            .onChange(of: highQualityIdleRender) { newValue in
                UserDefaults.standard.set(newValue, forKey: kHQIdleKey)
                vm.renderer?.setHighQualityIdle(newValue)
                // Re-evaluate interactive mode based on the switch
                let interactiveNow = newValue ? isInteracting : true
                vm.renderer?.setInteractive(interactiveNow, baseIterations: vm.maxIterations)
                vm.requestDraw()
            }
            .onChange(of: isInteracting) { active in
                let interactiveNow = highQualityIdleRender ? active : true
                vm.renderer?.setInteractive(interactiveNow, baseIterations: vm.maxIterations)
                vm.requestDraw()
            }
            .onChange(of: currentPaletteName) { _, newName in
                if let opt = paletteOptions.first(where: { $0.name == newName }) {
                    applyPaletteOption(opt)
                }
                persistPaletteSelection()
            }
            .onChange(of: contrast) { _ in
                UserDefaults.standard.set(contrast, forKey: kContrastKey)
                applyContrastIfNeeded()
            }
            .onChange(of: vm.center)               { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: vm.scalePixelsPerUnit)   { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: vm.maxIterations)        { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    persistPaletteSelection()
                }
            }
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
            .sheet(isPresented: $showCaptureSheet) {
                NavigationStack {
                    Form {
                        Section(header: Text("Resolution")) {
                            Picker("Preset", selection: $snapRes) {
                                ForEach(SnapshotRes.allCases) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .onChange(of: snapRes) { _, newValue in
                                let aspect = canvasAspect
                                switch newValue {
                                case .canvas:
                                    if let ds = vm.mtkView?.drawableSize, ds.width > 0, ds.height > 0 {
                                        customW = String(Int(ds.width.rounded()))
                                        let h = preserveAspect ? Int((Double(ds.width)/aspect).rounded()) : Int(ds.height.rounded())
                                        customH = String(max(1, h))
                                    }
                                case .r4k:
                                    let w = 3840
                                    let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 2160
                                    customW = String(w); customH = String(max(1, h))
                                case .r6k:
                                    let w = 5760
                                    let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 3240
                                    customW = String(w); customH = String(max(1, h))
                                case .r8k:
                                    let w = 7680
                                    let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 4320
                                    customW = String(w); customH = String(max(1, h))
                                case .custom:
                                    break
                                }
                            }

                            HStack {
                                TextField("Width", text: $customW)
                                    .keyboardType(.numberPad)
                                    .onChange(of: customW) { _, _ in applyWidthFromText() }
                                Text("×")
                                TextField("Height", text: $customH)
                                    .keyboardType(.numberPad)
                                    .disabled(preserveAspect)
                                    .onChange(of: customH) { _, _ in applyHeightFromText() }
                            }

                            Toggle("Preserve canvas aspect", isOn: $preserveAspect)
                                .onChange(of: preserveAspect) { _, on in
                                    if on { applyWidthFromText() }
                                }
                        }

                        Section(header: Text("Format")) {
                            Picker("File Type", selection: $exportFormatRaw) {
                                Text("PNG").tag(ContentView.ExportFormat.png.rawValue)
                                Text("JPEG").tag(ContentView.ExportFormat.jpeg.rawValue)
                            }
                            .pickerStyle(.segmented)

                            if exportFormatRaw == ContentView.ExportFormat.jpeg.rawValue {
                                HStack(spacing: 12) {
                                    Text("JPEG Quality")
                                    Slider(value: $exportJPEGQuality, in: 0.5...1.0, step: 0.05)
                                    Text("\(Int(exportJPEGQuality * 100))%")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("JPEG Quality")
                            }
                        }

                        Section(header: Text("Framing")) {
                            Toggle("Preserve canvas aspect", isOn: $preserveAspect)
                                .onChange(of: preserveAspect) { _, on in
                                    if on { applyWidthFromText() }
                                }
                        }

                        Section {
                            Button {
                                normalizeCustomSizeFromPreset()
                                saveCurrentSnapshot()
                                showCaptureSheet = false
                            } label: {
                                Text("Capture")
                            }
                            .disabled(isCapturing)

                            Button("Cancel", role: .cancel) { showCaptureSheet = false }
                        }
                    }
                    .navigationTitle("Capture Image")
                }
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
                                                  deep: true,
                                                  perturb: false)
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
                    highQualityIdle: $highQualityIdleRender,
                    snapRes: $snapRes,
                    paletteOptions: paletteOptions,
                    applyPalette: { opt in
                        applyPaletteOption(opt)
                    },
                    onImportGradient: { item in
                        gradientItem = item
                        importGradientItem(item)
                    },
                    onSave: { showCaptureSheet = true },
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
    
    private func persistPaletteSelection() {
        UserDefaults.standard.set(currentPaletteName, forKey: kPaletteNameKey)
        vm.saveState(perturb: false, deep: true, palette: palette)
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
        let doubleTap = SpatialTapGesture(count: 2)
            .onChanged { _ in isInteracting = true }
            .onEnded { value in
                isInteracting = true
                doubleTapZoom(point: value.location, size: geo.size, factor: 2.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isInteracting = false }
            }

        MetalFractalView(vm: vm)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(panAndZoom(geo.size))     // pan + pinch
            .highPriorityGesture(doubleTap)    // ×2 zoom at tap point
            .onChange(of: geo.size) { _, newSize in
                onCanvasSizeChanged(newSize)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                vm.pushViewport(currentPointsSize(geo.size), screenScale: currentScreenScale())
                vm.requestDraw()
            }
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
        // If contrast is neutral and this is a built-in, use the fast built-in mode.
        if let idx = opt.builtInIndex, abs(contrast - 1.0) < 0.01 {
            palette = idx
            vm.renderer?.setPalette(idx)
            vm.requestDraw()
            return
        }
        // Otherwise build a LUT (either custom palette or to honor non-1.0 contrast)
        if let img = makeContrastLUTImage(stops: opt.stops, width: 512, contrast: contrast) {
            vm.renderer?.setPaletteImage(img)
            vm.renderer?.setPalette(3)
            palette = 3
        }
        vm.requestDraw()
    }

    // Build a 1×W LUT image from gradient stops
    private func makeLUTImage(stops: [(CGFloat, UIColor)], width: Int = 256) -> UIImage? {
        let w = max(2, width)
        let h = 1
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitsPerComp = 8
        let rowBytes = w * 4
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: bitsPerComp,
            bytesPerRow: rowBytes,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let cgStops: [(CGFloat, CGColor)] = stops.map { ($0.0, $0.1.cgColor) }
        let locations: [CGFloat] = cgStops.map { $0.0 }
        let colors = cgStops.map { $0.1 } as CFArray

        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locations) else { return nil }
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])

        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // Convert sRGB (0...1) to HSV (h in 0...1, s/v in 0...1)
    private func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let cmax = max(r, max(g, b))
        let cmin = min(r, min(g, b))
        let delta = cmax - cmin

        var h: Double = 0.0
        if delta > 1e-12 {
            if cmax == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
            } else if cmax == g {
                h = ((b - r) / delta) + 2.0
            } else {
                h = ((r - g) / delta) + 4.0
            }
            h /= 6.0
            if h < 0 { h += 1.0 }
        }
        let s = cmax == 0 ? 0 : (delta / cmax)
        let v = cmax
        return (h, s, v)
    }

    // Convert HSV (h in 0...1, s/v in 0...1) to sRGB (0...1)
    private func hsvToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
        if s <= 1e-12 { return (v, v, v) }
        let hh = (h - floor(h)) * 6.0
        let i = Int(hh)
        let f = hh - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // Contrast in HSV: adjust V (and gently S) per pixel so hue is preserved
    private func makeContrastLUTImage(stops: [(CGFloat, UIColor)], width: Int = 256, contrast: Double) -> UIImage? {
        // 1) Build a linear LUT image from the provided stops
        guard let base = makeLUTImage(stops: stops, width: width), let cg = base.cgImage else { return nil }
        let w = cg.width
        let h = 1

        // 2) Read source pixels (premultipliedLast from makeLUTImage)
        guard let provider = cg.dataProvider, let cfData = provider.data else { return base }
        let srcLen = CFDataGetLength(cfData)
        guard srcLen >= w * 4 else { return base }
        let srcPtr = CFDataGetBytePtr(cfData)!

        // 3) Allocate destination buffer
        var dst = Data(count: w * 4)
        let mid: Double = 0.5
        // Map UI contrast range (0.5...2.0) to sensible gamma and saturation scaling
        let gamma: Double = max(0.25, min(4.0, 1.0 / contrast)) // <1 = higher contrast, >1 = softer
        let satScale: Double = pow(contrast, 0.35)               // gentle saturation lift with contrast

        dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
            let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            for x in 0 ..< w {
                let i = x * 4
                // sRGB bytes
                let a = Double(srcPtr[i + 3]) / 255.0
                let r = Double(srcPtr[i + 0]) / 255.0
                let g = Double(srcPtr[i + 1]) / 255.0
                let b = Double(srcPtr[i + 2]) / 255.0

                // Convert to HSV, adjust V and S (preserve hue)
                var (hue, sat, val) = rgbToHSV(r: r, g: g, b: b)
                // Remap value around mid using gamma. Using pow on V preserves hues and avoids band shifts.
                let vAdj = pow(val, gamma)
                // Light saturation shaping to keep vivid palettes punchy as contrast rises
                let sAdj = min(1.0, max(0.0, sat * satScale))

                let (rr, gg, bb) = hsvToRGB(h: hue, s: sAdj, v: vAdj)

                // Write as BGRA premultipliedFirst (for MTLPixelFormat.bgra8Unorm)
                dstPtr[i + 0] = UInt8(max(0.0, min(1.0, bb)) * 255.0) // B
                dstPtr[i + 1] = UInt8(max(0.0, min(1.0, gg)) * 255.0) // G
                dstPtr[i + 2] = UInt8(max(0.0, min(1.0, rr)) * 255.0) // R
                dstPtr[i + 3] = UInt8(max(0.0, min(1.0, a )) * 255.0) // A
            }
        }

        // 4) Create CGImage from adjusted buffer
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let newProvider = CGDataProvider(data: dst as CFData) else { return base }
        guard let out = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: newProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return base }
        return UIImage(cgImage: out)
    }

    // If contrast is neutral and a built‑in palette is selected, use fast GPU palette.
    // Otherwise, build a LUT (either custom palette or to honor the non‑1.0 contrast).
    private func applyContrastIfNeeded() {
        if abs(contrast - 1.0) < 0.01 {
            if let opt = paletteOptions.first(where: { $0.name == currentPaletteName }),
               let idx = opt.builtInIndex {
                palette = idx
                vm.renderer?.setPalette(idx)
                vm.requestDraw()
                return
            }
        }
        guard let opt = paletteOptions.first(where: { $0.name == currentPaletteName }) else { return }
        if let img = makeContrastLUTImage(stops: opt.stops, width: 512, contrast: contrast) {
            vm.renderer?.setPaletteImage(img)
            vm.renderer?.setPalette(3) // LUT slot
            palette = 3
            vm.requestDraw()
        }
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

    // ——— Export settings & toast ———
    enum ExportFormat: String { case png, jpeg }
    @AppStorage("exportFormat") private var exportFormatRaw: String = ExportFormat.png.rawValue
    @AppStorage("exportJPEGQuality") private var exportJPEGQuality: Double = 0.95
    @AppStorage("autoSaveToPhotos") private var autoSaveToPhotos: Bool = false
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""

    private var exportFormat: ExportFormat {
        get { ExportFormat(rawValue: exportFormatRaw) ?? .png }
        set { exportFormatRaw = newValue.rawValue }
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
                .disabled(isCapturing)
                Spacer(minLength: 8)
                Button(action: { openCaptureSheet() }) {
                    Label("Capture", systemImage: "camera")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(minWidth: 120, alignment: .center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .foregroundStyle(.white)
                .disabled(isCapturing)
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
                HStack(alignment: .center, spacing: narrow ? 12 : 18) {
                    // Navigation
                    Button(action: { reset(geo.size) }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(isCapturing)

                    Divider().frame(height: 22).opacity(0.2)

                    // Modes (Auto Iter only; Deep Zoom always on)
                    HStack(spacing: 16) {
                        LabeledToggle(title: "Auto Iter", systemImage: "aqi.medium", isOn: $autoIterations)
                        LabeledToggle(title: "HQ idle", systemImage: "sparkles", isOn: $highQualityIdleRender)
                    }

                    Divider().frame(height: 22).opacity(0.2)

                    // Iterations (slider + live value)
                    HStack(spacing: 10) {
                        Text("Iterations")
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)

                        Button(action: {
                            let newVal = max(100, vm.maxIterations - 50)
                            vm.maxIterations = newVal
                            vm.renderer?.setMaxIterations(newVal)
                            vm.requestDraw()
                        }) { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Slider(value: iterBinding, in: 100...5000, step: 50)
                            .controlSize(.small)
                            .frame(width: min(max(geo.size.width * 0.18, 160), 260))

                        Button(action: {
                            let newVal = min(5000, vm.maxIterations + 50)
                            vm.maxIterations = newVal
                            vm.renderer?.setMaxIterations(newVal)
                            vm.requestDraw()
                        }) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Text(autoIterations ? "\(effectiveIterations) (auto)" : "\(vm.maxIterations)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(height: 28)

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

                    // Contrast
                    HStack(spacing: 8) {
                        Text("Contrast")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Slider(value: Binding(
                            get: { contrast },
                            set: { contrast = max(0.5, min(2.0, $0)) }
                        ), in: 0.5...2.0, step: 0.05)
                            .frame(width: 160)
                        Text(String(format: "%.2f×", contrast))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

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

                    // --- Copy (quick clipboard export of current canvas) ---
                    Button(action: { copyCanvasToClipboard() }) {
                        Label("Copy", systemImage: "square.on.square")
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isCapturing)

                    // --- Capture (opens a dialog with resolution) ---
                    Button(action: { openCaptureSheet() }) {
                        Label(narrow ? "Capture" : "Capture Image", systemImage: "camera")
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .frame(minWidth: narrow ? 140 : 160, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .foregroundStyle(.white)
                    .controlSize(.regular)
                    .disabled(isCapturing)

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
            .disabled(isCapturing)
            .overlay(
                Group {
                    if showToast {
                        Text(toastMessage)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            .transition(.opacity)
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
            )
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
                let clamped = min(5000, max(100, Int(newVal.rounded())))
                vm.maxIterations = clamped
                vm.renderer?.setMaxIterations(clamped)
                vm.requestDraw()
            }
        )
    }

    private var hud: some View {
        let compact = (hSize == .compact)
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text("Mandelbrot Metal")
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
            if let tag = vm.renderer?.deepZoomActiveTag {
                Text(tag).font(.caption2).padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            vm.renderer?.ssaaActiveTag.map { Text($0).font(.caption2).monospaced().padding(4).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.2))) }
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
                isInteracting = true
                vm.renderer?.setInteractive(true, baseIterations: effectiveIterations)
                vm.mtkView?.preferredFramesPerSecond = 30
                pendingScale = value
                liveUpdate(size: size)
            }
            .onEnded { value in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { isInteracting = false }
                vm.renderer?.setInteractive(false, baseIterations: effectiveIterations)
                vm.mtkView?.preferredFramesPerSecond = 60
                applyPinch(value, size: size)
            }
        
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                isInteracting = true
                vm.renderer?.setInteractive(true, baseIterations: effectiveIterations)
                vm.mtkView?.preferredFramesPerSecond = 30
                pendingCenter = dragToComplex(value.translation)
                liveUpdate(size: size)
            }
            .onEnded { value in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { isInteracting = false }
                vm.renderer?.setInteractive(false, baseIterations: effectiveIterations)
                vm.mtkView?.preferredFramesPerSecond = 60
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
        // Baseline is the zoom level when the session started or was last reset
        let mag = max(1.0, scale / max(1e-9, vm.baselineScale))
        // Tunables:
        let k: Double = 600.0   // growth per decade
        let p: Double = 1.25    // curve steepness
        let bump: Double = 40.0 // gentle bias so small zooms still increase a bit
        let extra = k * pow(log10(mag), p) + bump
        let target = Int((Double(vm.maxIterations)) + max(0.0, extra))
        return min(5_000, max(100, target)) // clamp to your new max
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

    // Called when the device rotates or the available canvas size changes.
    // Ensures the renderer gets the new size and triggers a fresh render.
    private func onCanvasSizeChanged(_ size: CGSize) {
        // Recompute effective iterations if auto is enabled
        let it = autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations

        // Push the updated viewport (same center/scale, new size)
        vm.renderer?.setViewport(
            center: vm.center,
            scalePixelsPerUnit: vm.scalePixelsPerUnit,
            sizePts: currentPointsSize(size),
            screenScale: currentScreenScale(),
            maxIterations: it
        )

        // Ask Metal view to redraw
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

    private func applyBookmark(_ bm: Bookmark, size: CGSize) {
        vm.center = bm.center
        vm.scalePixelsPerUnit = bm.scale
        palette = bm.palette
        vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
        vm.renderer?.setPalette(palette)
        vm.renderer?.setDeepZoom(true)
        currentPaletteName = (palette == 0 ? "HSV" : palette == 1 ? "Fire" : palette == 2 ? "Ocean" : currentPaletteName)
        vm.requestDraw()
    }
    
    private func reset(_ size: CGSize) {
        // Viewport back to default
        vm.center = SIMD2(-0.5, 0.0)
        vm.scalePixelsPerUnit = 1

        // Reset iterations to minimum and restart auto-iter baseline
        vm.maxIterations = 100
        // Also reset contrast to neutral and rebuild palette/LUT
        contrast = 1.0
        applyContrastIfNeeded()
        persistPaletteSelection()
        isInteracting = false
        vm.baselineScale = 1   // so autoIterations recalibrates from the new start

        // Apply to renderer immediately
        let it = autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations
        if autoIterations { vm.maxIterations = it }
        vm.renderer?.setMaxIterations(it)
        vm.renderer?.setInteractive(false, baseIterations: vm.maxIterations)

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
                currentPaletteName = "Custom LUT"
                persistPaletteSelection()
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

    private func commitPendingInteractions(_ size: CGSize) {
        // Fold any in-flight gestures into the model so snapshots use the latest view
        if pendingScale != 1.0 || pendingCenter != .zero {
            vm.center += pendingCenter
            vm.scalePixelsPerUnit *= pendingScale
            pendingCenter = .zero
            pendingScale = 1.0

            // Recompute iterations if auto is enabled
            if autoIterations {
                let it = autoIterationsForScale(vm.scalePixelsPerUnit)
                vm.maxIterations = it
                vm.renderer?.setMaxIterations(it)
            }
            // Ensure renderer matches the current maxIterations before pushing viewport
            vm.renderer?.setMaxIterations(vm.maxIterations)
            // Push the updated viewport to the renderer immediately
            vm.pushViewport(currentPointsSize(size), screenScale: currentScreenScale())
            vm.requestDraw()
        }
    }

    private func saveCurrentSnapshot() {
        guard let renderer = vm.renderer else {
            print("[UI] renderer is nil — cannot snapshot")
            isCapturing = false
            return
        }
        if isCapturing { print("[UI] capture already in progress — ignoring"); return }
        
        // Show HUD right away
        isCapturing = true
        print("[UI] saveCurrentSnapshot() starting…")
        
        // Resolve target dimensions from picker (respect "Preserve canvas aspect")
        let aspect = canvasAspect
        let dims: (Int, Int)
        switch snapRes {
        case .canvas:
            let canvasW = Int(vm.mtkView?.drawableSize.width  ?? 3840)
            let canvasH = Int(vm.mtkView?.drawableSize.height ?? 2160)
            let w = Int(customW) ?? canvasW
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : (Int(customH) ?? canvasH)
            dims = (max(16, w), max(16, h))
        case .r4k:
            let w = 3840
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 2160
            dims = (w, max(16, h))
        case .r6k:
            let w = 5760
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 3240
            dims = (w, max(16, h))
        case .r8k:
            let w = 7680
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 4320
            dims = (w, max(16, h))
        case .custom:
            let w = Int(customW) ?? 3840
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : (Int(customH) ?? 2160)
            dims = (max(16, w), max(16, h))
        }
        let (w, h) = dims
        
        // 1) Commit any in-flight pan/zoom before saving (main thread)
        let commitSize = vm.mtkView?.bounds.size ?? UIScreen.main.bounds.size
        commitPendingInteractions(commitSize)
        
        // 2) Ensure palette & effective iterations match the view (main thread)
        renderer.setPalette(palette)
        let effectiveIters = autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations
        let exportIters = min(2_500, max(100, effectiveIters))
        // NOTE: Do not change vm.maxIterations or the renderer's live iterations here.
        // We pass `exportIters` to the capture routine only, keeping the UI slider unchanged.

        // Immutable snapshot of state AFTER the commit
        let snapCenter = vm.center
        var snapScale  = vm.scalePixelsPerUnit
        if let ds = vm.mtkView?.drawableSize, ds.width > 0 {
            // If export width differs from canvas width, adjust pixels-per-unit so FOV is preserved.
            // Same aspect -> same framing; different aspect -> we still match horizontal FOV.
            let canvasW = Double(ds.width)
            let scaleFactor = Double(w) / canvasW
            snapScale = vm.scalePixelsPerUnit * scaleFactor
        }
        let t0 = CACurrentMediaTime()
        
        // 3) Start async capture (tiles always; avoids big single allocations)
        renderer.captureAsyncTiled(
            width: w,
            height: h,
            tile: 256,
            center: snapCenter,
            scalePixelsPerUnit: snapScale,
            iterations: exportIters,
            progress: { _ in
                // HUD already visible via isCapturing; nothing else needed
            },
            completion: { img in
                let dt = CACurrentMediaTime() - t0
                defer { self.isCapturing = false }
                guard let img else {
                    print("[UI] snapshot failed after \(String(format: "%.2f", dt))s")
                    return
                }
                print("[UI] capture finished in \(String(format: "%.2f", dt))s")
                self.handleSnapshotResult(img)
            }
        )
    }
    
    private func handleSnapshotResult(_ img: UIImage) {
        print("[UI] handleSnapshotResult: preparing export…")

        let fmt = exportFormat
        let q = max(0.5, min(1.0, exportJPEGQuality))
        let data: Data?
        let ext: String
        switch fmt {
        case .png:
            data = img.pngData()
            ext = "png"
        case .jpeg:
            data = img.jpegData(compressionQuality: q)
            ext = "jpg"
        }

        guard let outData = data else { print("[UI] image encode failed"); return }

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm"
        let fname = "MandelMetal_\(df.string(from: Date())).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fname)

        do {
            shareItems.removeAll()
            try outData.write(to: url, options: .atomic)
            snapshotURL = url
            shareItems = [url]

            // Optional auto‑save to Photos
            if autoSaveToPhotos {
                PhotoSaver.shared.saveToPhotos(img) { result in
                    switch result {
                    case .success:
                        self.showTransientToast("Saved to Photos ✓")
                    case .failure:
                        self.showTransientToast("Couldn’t save to Photos")
                    }
                }
            }

            // Present share sheet reliably
            showShare = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showShare = true }
        } catch {
            print("[UI] failed to write snapshot: \(error)")
            showTransientToast("Export failed")
        }
    }

    private func showTransientToast(_ message: String) {
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) { showToast = false }
        }
    }

    private func copyCanvasToClipboard() {
        guard let renderer = vm.renderer else { return }
        // Commit any in‑flight gestures so we copy what we see
        let commitSize = vm.mtkView?.bounds.size ?? UIScreen.main.bounds.size
        commitPendingInteractions(commitSize)

        let ds = vm.mtkView?.drawableSize
        let w = Int(ds?.width ?? 0), h = Int(ds?.height ?? 0)
        guard w > 0, h > 0 else { return }

        let it = autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations
        let exportIters = min(2_500, max(100, it))

        // Keep framing identical to canvas
        let img = renderer.makeSnapshot(
            width: w,
            height: h,
            center: vm.center,
            scalePixelsPerUnit: vm.scalePixelsPerUnit,
            iterations: exportIters
        )
        if let img { UIPasteboard.general.image = img; showTransientToast("Copied ✓") }
    }

    // Helper to open the capture sheet, prefilling custom size with current canvas pixels
    private func openCaptureSheet() {
        // Prefill the capture dialog with the current canvas pixel size
        if let ds = vm.mtkView?.drawableSize, ds.width > 0, ds.height > 0 {
            customW = String(Int(ds.width.rounded(.toNearestOrAwayFromZero)))
            customH = String(Int(ds.height.rounded(.toNearestOrAwayFromZero)))
            snapRes = .canvas   // <- was .custom
        }
        isInteracting = false
        showCaptureSheet = true
        
        // Keep height in lockstep with width if preserving aspect
        if preserveAspect { applyWidthFromText() }
    }
    
    // Canvas aspect (width / height) based on the current drawable; safe fallbacks
    private var canvasAspect: Double {
        if let ds = vm.mtkView?.drawableSize, ds.width > 0, ds.height > 0 {
            return Double(ds.width) / Double(ds.height)
        }
        let sz = UIScreen.main.bounds.size
        return Double(sz.width) / max(1.0, Double(sz.height))
    }

    // Parse width text and update height when preserving aspect
    private func applyWidthFromText() {
        let aspect = canvasAspect
        let w = max(16, Int(customW) ?? 0)
        if preserveAspect {
            let h = Int((Double(w) / aspect).rounded())
            customH = String(max(16, h))
        }
    }

    // Parse height text (used only when preserveAspect == false)
    private func applyHeightFromText() {
        _ = max(16, Int(customH) ?? 0)
    }

    // Ensure customW/customH match the selected preset and toggle
    private func normalizeCustomSizeFromPreset() {
        let aspect = canvasAspect
        switch snapRes {
        case .canvas:
            // keep canvas; recompute H from W if preserving aspect
            if preserveAspect, let w = Int(customW) {
                customH = String(max(16, Int((Double(w)/aspect).rounded())))
            }
        case .r4k:
            let w = 3840
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 2160
            customW = String(w)
            customH = String(max(16, h))
        case .r6k:
            let w = 5760
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 3240
            customW = String(w)
            customH = String(max(16, h))
        case .r8k:
            let w = 7680
            let h = preserveAspect ? Int((Double(w)/aspect).rounded()) : 4320
            customW = String(w)
            customH = String(max(16, h))
        case .custom:
            // honor current fields; if preserving aspect, recompute H from W
            if preserveAspect, let w = Int(customW) {
                customH = String(max(16, Int((Double(w)/aspect).rounded())))
            }
        }
    }

    private func appCopyright() -> String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, !s.isEmpty {
            return s
        }
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Michael Stebel Consulting, LLC. All rights reserved."
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
                VStack(alignment: .leading, spacing: 18) {
                    // Title
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.3x3")
                            .imageScale(.large)
                        Text("Mandelbrot Metal — Help")
                            .font(.title2).bold()
                    }
                    .padding(.bottom, 4)

                    Text("A quick guide to the controls, gestures, and new features.")
                        .foregroundStyle(.secondary)

                    // Gestures
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Drag to pan", systemImage: "hand.draw")
                            Label("Pinch to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                            Label("Double-tap to zoom in 2× at the tap point", systemImage: "magnifyingglass")
                            Label("Reset from the bottom bar", systemImage: "arrow.counterclockwise")
                        }
                    } label: { Label("Gestures", systemImage: "hand.point.up.left") }

                    // Color & Palettes
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Palette Picker with categories", systemImage: "paintpalette")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("• Vivid: Neon, Vibrant, Sunset Glow, Candy, Aurora Borealis, Tropical, Flamingo, Lagoon, Cyberpunk, Lava")
                                Text("• Metallics: Metallic Silver, Chrome, Gold, Rose Gold, Steel, Bronze, Copper, Titanium, Mercury, Pewter, Iridescent")
                                Text("• Scientific: Magma, Inferno, Plasma, Viridis, Turbo, Cubehelix, Grayscale")
                                Text("• Natural & Gem collections")
                            }

                            Divider()

                            Label("Live Gradient Editor", systemImage: "slider.horizontal.3")
                            Text("Build custom palettes from gradient stops. You can also import an image from Photos to sample its gradient.")
                                .font(.footnote).foregroundStyle(.secondary)

                            Label("Palette dithering toggle", systemImage: "checkerboard.rectangle")
                            Text("Reduces banding in smooth gradients. Toggle in Options.", comment: "helper hint")
                                .font(.footnote).foregroundStyle(.secondary)

                            Label("Contrast control (0.5×–2.0×)", systemImage: "circle.lefthalf.filled")
                            Text("Adjusts brightness/value while preserving hue. When contrast = 1.0, built-in GPU palettes are used automatically for maximum performance.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } label: { Label("Color & Palettes", systemImage: "paintpalette") }

                    // Rendering & Quality
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Deep Zoom is always on", systemImage: "sparkles")
                            Text("The renderer seamlessly switches to high-precision paths as you zoom.")
                                .font(.footnote).foregroundStyle(.secondary)

                            Label("Auto Iterations (optional)", systemImage: "aqi.medium")
                            Text("Iteration count scales with zoom so details stay crisp without manual tuning.")
                                .font(.footnote).foregroundStyle(.secondary)

                            Label("High-Quality Idle", systemImage: "wand.and.stars")
                            Text("When not interacting, frames refine with higher iteration budgets.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } label: { Label("Rendering & Quality", systemImage: "cpu") }

                    // Export, Capture & Bookmarks
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Copy current canvas to clipboard", systemImage: "square.on.square")
                            Label("Capture image (PNG/JPEG)", systemImage: "camera")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("• Presets: Canvas, 4K, 6K, 8K, or Custom size")
                                Text("• JPEG quality control and aspect preservation")
                            }
                            .font(.footnote).foregroundStyle(.secondary)

                            Label("Bookmarks", systemImage: "bookmark")
                            Text("Save and return to favorite views.", comment: "helper hint")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } label: { Label("Export & Bookmarks", systemImage: "square.and.arrow.up") }

                    // Tips
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Use Options for palettes, contrast, dithering, Auto Iterations & HQ Idle", systemImage: "slider.horizontal.3")
                            Label("If the image ever appears blank after a rotation, just tap or pan — it auto-refreshes.", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: { Label("Tips", systemImage: "lightbulb") }

                    Spacer(minLength: 4)
                    
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
                    Text("Version \(version) (\(build))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
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
            Text("Canvas").tag(ContentView.SnapshotRes.canvas)
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

// MARK: - Capture Sheet
private struct CaptureSheet: View {
    @Binding var snapRes: ContentView.SnapshotRes
    @Binding var customW: String
    @Binding var customH: String

    // NEW bindings for format/aspect
    @Binding var exportFormatRaw: String
    @Binding var exportJPEGQuality: Double
    @Binding var preserveAspect: Bool

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

                Section(header: Text("Format")) {
                    Picker("File Type", selection: $exportFormatRaw) {
                        Text("PNG").tag(ContentView.ExportFormat.png.rawValue)
                        Text("JPEG").tag(ContentView.ExportFormat.jpeg.rawValue)
                    }
                    .pickerStyle(.segmented)

                    if exportFormatRaw == ContentView.ExportFormat.jpeg.rawValue {
                        HStack(spacing: 12) {
                            Text("JPEG Quality")
                            Slider(value: $exportJPEGQuality, in: 0.5...1.0, step: 0.05)
                            Text("\(Int(exportJPEGQuality * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("JPEG Quality")
                    }
                }
                
                Section(header: Text("Framing")) {
                    Toggle("Preserve canvas aspect", isOn: $preserveAspect)
                }

                Section(header: Text("After Capture")) {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "autoSaveToPhotos") },
                        set: { UserDefaults.standard.set($0, forKey: "autoSaveToPhotos") }
                    )) { Label("Auto‑save to Photos", systemImage: "photo") }
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
                            Text((UserDefaults.standard.string(forKey: "exportFormat") ?? "png").uppercased() == "JPEG" ? "Capture (JPEG)" : "Capture (PNG)")
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
