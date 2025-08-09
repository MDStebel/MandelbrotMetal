//
//  ContentView.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/8/25.
//

import SwiftUI
import MetalKit
import simd
import PhotosUI
import UIKit

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
    @StateObject private var vm = FractalVM()
    @State private var pendingCenter = SIMD2<Double>(0, 0)
    @State private var pendingScale  = 1.0
    @State private var perturbation = false
    @State private var palette = 0 // 0=HSV, 1=Fire, 2=Ocean
    @State private var gradientItem: PhotosPickerItem? = nil
    
    @State private var deepZoom = false
    @State private var snapshotImage: UIImage? = nil
    @State private var showShare = false
    @State private var snapshotURL: URL? = nil
    @State private var showAbout = false
    @State private var autoIterations = false
    struct Bookmark: Codable, Identifiable { var id = UUID(); var name: String; var center: SIMD2<Double>; var scale: Double; var palette: Int; var deep: Bool; var perturb: Bool }
    @State private var bookmarks: [Bookmark] = []
    @State private var showAddBookmark = false
    @State private var newBookmarkName: String = ""

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
                loadBookmarks()
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
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    bottomToolbar(geo)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = snapshotURL {
                    ShareSheet(items: [url])
                } else if let img = snapshotImage {
                    ShareSheet(items: [img])
                }
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
            .sheet(isPresented: $showAbout) {
                VStack(spacing: 20) {
                    Text("MandelbrotMetal").font(.title).bold()
                    Text("© 2025 Michael Stebel. All rights reserved.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tips:")
                        Text("• Pinch to zoom, drag to pan, double‑tap to zoom in.")
                        Text("• Toggle Deep Zoom and Perturb for ultra‑deep stable zooms.")
                        Text("• Import Gradient to use a custom LUT palette.")
                        Text("• Long‑press to re‑center the perturbation reference.")
                        Text("• Use Resolution → Save for 4K/6K/8K; large sizes use tiled export.")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func bottomToolbar(_ geo: GeometryProxy) -> some View {
        Button("About") { showAbout = true }
        Button("Reset") { reset(geo.size) }
        PhotosPicker("Import Gradient", selection: $gradientItem, matching: .images)
            .onChange(of: gradientItem) { _, item in
                importGradientItem(item)
            }
        Spacer()
        Toggle("Perturb", isOn: $perturbation)
            .onChange(of: perturbation) { _, v in
                vm.renderer?.setPerturbation(v)
                vm.requestDraw()
            }
        Toggle("Deep Zoom", isOn: $deepZoom)
            .onChange(of: deepZoom) { _, v in
                vm.renderer?.setDeepZoom(v)
                vm.requestDraw()
            }
        Picker("Palette", selection: $palette) {
            Text("HSV").tag(0)
            Text("Fire").tag(1)
            Text("Ocean").tag(2)
        }
        .pickerStyle(.segmented)
        .onChange(of: palette) { _, newVal in
            vm.renderer?.setPalette(newVal)
            vm.requestDraw()
        }
        Spacer()
        Stepper("Iterations: \(vm.maxIterations)",
                value: $vm.maxIterations,
                in: 200...4000, step: 100) { _ in
            vm.renderer?.setMaxIterations(vm.maxIterations)
            vm.requestDraw()
        }
        Toggle("Auto Iter", isOn: $autoIterations)
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
        Button("Save") { saveCurrentSnapshot() }
    }
    
    private var effectiveIterations: Int {
        autoIterations ? autoIterationsForScale(vm.scalePixelsPerUnit) : vm.maxIterations
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mandelbrot (Metal)").font(.headline.monospaced())
            Text("Center: x=\(fmt(vm.center.x)) y=\(fmt(vm.center.y))").font(.caption.monospaced())
            Text(String(format: "Scale: %.2fx", vm.scalePixelsPerUnit)).font(.caption.monospaced())
            Text(autoIterations ? "Iterations: \(effectiveIterations) (auto)" : "Iterations: \(vm.maxIterations)")
                .font(.caption.monospaced())
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            showShare = true
            print("[UI] wrote snapshot -> \(url.lastPathComponent)")
        } catch {
            print("[UI] failed to write snapshot: \(error)")
        }
    }

    private func fmt(_ x: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        return f.string(from: x as NSNumber) ?? "\(x)"
    }
    
    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
