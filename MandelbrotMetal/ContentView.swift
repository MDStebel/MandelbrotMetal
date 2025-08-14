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
    struct Bookmark: Codable, Identifiable { var id = UUID(); var name: String; var center: SIMD2<Double>; var scale: Double; var palette: Int; var deep: Bool; var perturb: Bool }
    @State private var bookmarks: [Bookmark] = []
    @State private var showAddBookmark = false
    @State private var newBookmarkName: String = ""
    @State private var fallbackBanner: String? = nil
    @State private var fallbackObserver: NSObjectProtocol? = nil
    @State private var useDisplayP3 = true
    @State private var lutWidth = 1024

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
    @State private var isInteracting: Bool = false
    private let kHQIdleKey = "hq_idle_render_v1"
    
    var body: some View {
        NavigationStack { GeometryReader { geo in
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
                // Tiny HUD chip for SSAA status
                if (vm.renderer?.isSSAAActive ?? false) {
                    Text("SSAA×2")
                        .font(.caption2).bold()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                        .accessibilityLabel("Super sampling active: two by two")
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
            }
            .onDisappear {
                if let obs = fallbackObserver {
                    NotificationCenter.default.removeObserver(obs)
                    fallbackObserver = nil
                }
            }
            .onChange(of: geo.size) { _, newSize in
                // Geometry changed (rotation/split view/resize). Recompute drawable size
                // from the new points size so the aspect ratio stays correct.
                DispatchQueue.main.async {
                    if let v = vm.mtkView {
                        let scale = v.window?.screen.scale ?? UIScreen.main.scale
                        v.drawableSize = CGSize(width: newSize.width * scale,
                                                height: newSize.height * scale)
                    }
                    vm.pushViewport(currentPointsSize(newSize), screenScale: currentScreenScale())
                    vm.requestDraw()
                }
            }
            .onChange(of: palette) { persistPaletteSelection() }
            .onChange(of: highQualityIdleRender) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: kHQIdleKey)
                vm.renderer?.setHighQualityIdle(newValue)
                // Re-evaluate interactive mode based on the switch
                let interactiveNow = newValue ? isInteracting : true
                vm.renderer?.setInteractive(interactiveNow, baseIterations: vm.maxIterations)
                vm.requestDraw()
            }
            .onChange(of: useDisplayP3) { _, _ in refreshCurrentLUT() }
            .onChange(of: lutWidth) { _, _ in refreshCurrentLUT() }
            .onChange(of: isInteracting) { _, active in
                let interactiveNow = highQualityIdleRender ? active : true
                vm.renderer?.setInteractive(interactiveNow, baseIterations: vm.maxIterations)
                vm.requestDraw()
            }
            .onChange(of: currentPaletteName) { _, _ in persistPaletteSelection() }
            .onChange(of: vm.center)               { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: vm.scalePixelsPerUnit)   { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: vm.maxIterations)        { vm.saveState(perturb: false, deep: true, palette: palette) }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    persistPaletteSelection()
                }
            }
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
                CaptureSheet(
                    snapRes: $snapRes,
                    customW: $customW,
                    customH: $customH,
                    onConfirm: { saveCurrentSnapshot() },
                    onClose: { showCaptureSheet = false },
                    onCustomTap: { showCustomRes = true }
                )
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
                optionsSheet()
            }
            .navigationTitle("Mandelbrot")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

@ViewBuilder
private func optionsSheet() -> some View {
    CompactOptionsSheet(
        currentPaletteName: $currentPaletteName,
        showPalettePicker: $showPalettePicker,
        autoIterations: $autoIterations,
        iterations: $vm.maxIterations,
        highQualityIdle: $highQualityIdleRender,
        useDisplayP3: $useDisplayP3,
        lutWidth: $lutWidth,
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

    // MARK: - Data-driven palette infrastructure (hex → UIColor)
    var paletteOptions: [PaletteOption] {
        return PaletteCatalog.shared.optionsSortedByFavorites()
    }

    private func toggleFavorite(_ option: PaletteOption) {
        PaletteFavorites.shared.toggle(name: option.name)
    }

    private func isFavorite(_ option: PaletteOption) -> Bool {
        PaletteFavorites.shared.isFavorite(name: option.name)
    }

    private func palettePreview(for name: String) -> some View {
        let opt = paletteOptions.first { $0.name == name } ?? paletteOptions[0]
        return LinearGradient(gradient: Gradient(stops: opt.stops.map { .init(color: Color($0.1), location: $0.0) }), startPoint: .leading, endPoint: .trailing)
    }
    
    private func refreshCurrentLUT() {
        // Only rebuild if the current palette is LUT-based (not GPU built-in)
        guard let opt = paletteOptions.first(where: { $0.name == currentPaletteName && $0.builtInIndex == nil }) else {
            return
        }
        if let img = makeLUTImage(stops: opt.stops, width: lutWidth, useDisplayP3: useDisplayP3) {
            vm.renderer?.setPaletteImage(img)
            vm.renderer?.setPalette(3) // LUT slot
            palette = 3
            vm.requestDraw()
        }
    }

    private func applyPaletteOption(_ opt: PaletteOption) {
        currentPaletteName = opt.name
        if let idx = opt.builtInIndex {
            palette = idx
            vm.renderer?.setPalette(idx)
        } else {
            if let img = makeLUTImage(stops: opt.stops, width: lutWidth, useDisplayP3: useDisplayP3) {
                vm.renderer?.setPaletteImage(img)
                vm.renderer?.setPalette(3) // LUT slot
                palette = 3
            }
        }
        vm.requestDraw()
    }

    private func makeLUTImage(stops: [(CGFloat, UIColor)], width: Int, useDisplayP3: Bool) -> UIImage? {
        let w = max(2, width)
        let h = 1
        let cs = useDisplayP3 ? CGColorSpace(name: CGColorSpace.displayP3)! : CGColorSpace(name: CGColorSpace.sRGB)!
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
                Menu {
                    Toggle("Wide Color (P3)", isOn: $useDisplayP3)
                    Toggle("High‑res LUT (1024px)", isOn: Binding(
                        get: { lutWidth == 1024 },
                        set: { lutWidth = $0 ? 1024 : 256 }
                    ))
                } label: {
                    Label("Color", systemImage: "paintpalette")
                        .labelStyle(.iconOnly)
                        .imageScale(.large)
                        .padding(8)
                }
                .accessibilityLabel("Color options")
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
                    Menu {
                        Toggle("Wide Color (P3)", isOn: $useDisplayP3)
                        Toggle("High‑res LUT (1024px)", isOn: Binding(
                            get: { lutWidth == 1024 },
                            set: { lutWidth = $0 ? 1024 : 256 }
                        ))
                    } label: {
                        Label("Color", systemImage: "paintpalette")
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
          let f: Font = compact ? .caption2 : .caption
          HStack(spacing: 6) {
              Text("Color:")
              Text(useDisplayP3 ? "P3" : "sRGB").bold()
              Text("•")
              Text("LUT \(lutWidth)")
          }
          .font(f)
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
                isInteracting = true
                pendingScale = value
                liveUpdate(size: size)
            }
            .onEnded { value in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { isInteracting = false }
                applyPinch(value, size: size)
            }
        
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                isInteracting = true
                pendingCenter = dragToComplex(value.translation)
                liveUpdate(size: size)
            }
            .onEnded { value in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { isInteracting = false }
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
        isInteracting = false
        vm.baselineScale = 1   // so autoIterations recalibrates from the new start

        // Apply to renderer immediately
        vm.renderer?.setMaxIterations(vm.maxIterations)
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

        isCapturing = true
        print("[UI] saveCurrentSnapshot() starting… (single‑pass canvas capture)")

        // Desired export dimensions (used after capture for scaling only)
        let exportDims: (Int, Int)
        switch snapRes {
        case .canvas:
            if let ds = vm.mtkView?.drawableSize { exportDims = (Int(ds.width), Int(ds.height)) } else { exportDims = (3840, 2160) }
        case .r4k:    exportDims = (3840, 2160)
        case .r6k:    exportDims = (5760, 3240)
        case .r8k:    exportDims = (7680, 4320)
        case .custom: exportDims = (Int(customW) ?? 3840, Int(customH) ?? 2160)
        }

        // Commit any in‑flight pan/zoom so the snapshot matches what you see
        let commitSize = vm.mtkView?.bounds.size ?? UIScreen.main.bounds.size
        commitPendingInteractions(commitSize)

        // Use current view settings
        renderer.setPalette(palette)
        let effectiveIters = autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations
        let exportIters = min(2_500, max(100, effectiveIters))
        vm.maxIterations = exportIters
        renderer.setMaxIterations(exportIters)

        // Capture EXACT canvas resolution to avoid any framing/clipping from tiling
        let canvasW = Int(vm.mtkView?.drawableSize.width  ?? UIScreen.main.bounds.size.width  * UIScreen.main.scale)
        let canvasH = Int(vm.mtkView?.drawableSize.height ?? UIScreen.main.bounds.size.height * UIScreen.main.scale)
        let snapCenter = vm.center
        let snapScale  = vm.scalePixelsPerUnit

        let t0 = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            let img = renderer.makeSnapshot(width: canvasW,
                                            height: canvasH,
                                            center: snapCenter,
                                            scalePixelsPerUnit: snapScale,
                                            iterations: exportIters)
            DispatchQueue.main.async {
                defer { self.isCapturing = false }
                guard let baseImg = img else { print("[UI] snapshot failed"); return }

                let (ew, eh) = exportDims
                let finalImg: UIImage
                if ew != canvasW || eh != canvasH {
                    finalImg = self.scaleImagePreservingAspect(baseImg, to: CGSize(width: ew, height: eh))
                } else {
                    finalImg = baseImg
                }
                self.handleSnapshotResult(finalImg)
                let dt = CACurrentMediaTime() - t0
                print("[UI] capture finished in \(String(format: "%.2f", dt))s (canvas \(canvasW)x\(canvasH) → export \(ew)x\(eh))")
            }
        }
    }

    private func scaleImagePreservingAspect(_ image: UIImage, to target: CGSize) -> UIImage {
        let srcW = max(1, image.size.width)
        let srcH = max(1, image.size.height)
        let scaleX = target.width / srcW
        let scaleY = target.height / srcH
        let scale = min(scaleX, scaleY) // aspect‑fit (no cropping)
        let outW = floor(srcW * scale)
        let outH = floor(srcH * scale)
        let dx = (target.width - outW) * 0.5
        let dy = (target.height - outH) * 0.5

        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = true
        fmt.scale = 1
        // Wide‑gamut hint for devices that support it. `UIGraphicsImageRendererFormat`
        // doesn’t expose a color‑space selector on iOS; Photos will color‑manage on save.
        fmt.preferredRange = useDisplayP3 ? .extended : .standard

        let renderer = UIGraphicsImageRenderer(size: target, format: fmt)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(x: dx, y: dy, width: outW, height: outH))
        }
    }
    
    private func handleSnapshotResult(_ img: UIImage) {
        print("[UI] handleSnapshotResult: preparing share…")
        guard let data = img.pngData() else { print("[UI] pngData() failed"); return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let fname = "MandelMetal_\(df.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fname)

        do {
            // Clear shareItems to avoid reusing a stale array
            shareItems.removeAll()
            try data.write(to: url, options: .atomic)
            snapshotURL = url
            shareItems = [url]
            // Present share sheet reliably (dismiss then present to avoid a stale controller)
            showShare = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showShare = true
            }
        } catch {
            print("[UI] failed to write snapshot: \(error)")
        }
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
    }


    private func fmt(_ x: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        return f.string(from: x as NSNumber) ?? "\(x)"
    }
    
    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
    
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

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
