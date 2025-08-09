//
//  ContentView.swift
//  MandelbrotMetal
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
                self?.scalePixelsPerUnit = workingScale
            }
        } else {
            workingScale = scalePixelsPerUnit
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
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                MetalFractalView(vm: vm)
                    .contentShape(Rectangle())
                    .gesture(panAndZoom(geo.size))
                    .onTapGesture(count: 2) { point in
                        doubleTapZoom(point: point, size: geo.size, factor: 2.0)
                    }
                
                hud
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear {
                vm.pushViewport(geo.size, screenScale: UIScreen.main.scale)
                vm.requestDraw()
                vm.renderer?.setPerturbation(perturbation)
                vm.renderer?.setPalette(palette)
                vm.renderer?.setDeepZoom(deepZoom)
            }
            .onChange(of: geo.size) { _, newSize in
                vm.pushViewport(newSize, screenScale: UIScreen.main.scale)
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Reset") { reset(geo.size) }
                    PhotosPicker("Import Gradient", selection: $gradientItem, matching: .images)
                        .onChange(of: gradientItem) { _, item in
                            guard let item else { return }
                            Task { @MainActor in
                                if let data = try? await item.loadTransferable(type: Data.self),
                                   let img = UIImage(data: data) {
                                    vm.renderer?.setPaletteImage(img)
                                    vm.renderer?.setPalette(3) // 3 = LUT in shader
                                    vm.requestDraw()
                                }
                            }
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
                    Button("Save 4K") {
                        if let img = vm.renderer?.makeSnapshot(width: 3840,
                                                               height: 2160,
                                                               center: vm.center,
                                                               scalePixelsPerUnit: vm.scalePixelsPerUnit,
                                                               iterations: vm.maxIterations) {
                            snapshotImage = img
                            showShare = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let img = snapshotImage {
                    ShareSheet(items: [img])
                }
            }
        }
    }
    
    private var hud: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mandelbrot (Metal)").font(.headline.monospaced())
            Text("Center: x=\(fmt(vm.center.x)) y=\(fmt(vm.center.y))").font(.caption.monospaced())
            Text(String(format: "Scale: %.2fx", vm.scalePixelsPerUnit)).font(.caption.monospaced())
            Text("Iterations: \(vm.maxIterations)").font(.caption.monospaced())
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
        vm.requestDraw()
    }
    
    private func applyDrag(_ value: DragGesture.Value, size: CGSize) {
        vm.center += dragToComplex(value.translation)
        pendingCenter = .zero
        vm.pushViewport(size, screenScale: UIScreen.main.scale)
        vm.requestDraw()
    }
    
    private func liveUpdate(size: CGSize) {
        var center = vm.center + pendingCenter
        var scale = vm.scalePixelsPerUnit * pendingScale
        scale = max(0.01, min(scale, 1e12))
        center.x = clamp(center.x, -3.0, 3.0)
        center.y = clamp(center.y, -3.0, 3.0)
        
        vm.renderer?.setViewport(center: center,
                                 scalePixelsPerUnit: scale,
                                 sizePts: size,
                                 screenScale: UIScreen.main.scale,
                                 maxIterations: vm.maxIterations)
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
