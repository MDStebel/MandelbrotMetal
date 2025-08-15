//
//  FractalVM.swift
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

@MainActor
final class FractalVM: ObservableObject {
    // Viewport
    @Published var center = SIMD2<Double>(-0.5, 0.0)
    @Published var scalePixelsPerUnit: Double = 1
    @Published var maxIterations: Int = 800
    @Published var baselineScale: Double = 1
    @Published var contrast: Double = 1.0

    // Palette & rendering options
    @Published var paletteIndex: Int = 0
    @Published var useDisplayP3: Bool = true
    @Published var smoothingEnabled: Bool = true  // banding reduction toggle

    // View / Metal hookups
    var viewSize: CGSize = .zero
    var renderer: MandelbrotRenderer?
    weak var mtkView: MTKView?

    func attachRenderer(_ r: MandelbrotRenderer) { self.renderer = r }
    func attachView(_ v: MTKView) { self.mtkView = v }

    /// Push the current viewport to the renderer.
    func pushViewport(_ size: CGSize, screenScale: CGFloat) {
        guard size != .zero else { return }
        viewSize = size

        let wD = Double(size.width) * Double(screenScale)
        let hD = Double(size.height) * Double(screenScale)
        guard wD.isFinite, hD.isFinite else { return }
        let pixelW = max(1, Int(floor(wD)))
        _ = max(1, Int(floor(hD))) // document intent for height

        let workingScale: Double
        if scalePixelsPerUnit == 1 {
            // Seed a sensible default scale based on width (≈ fits -2.5…1 on real axis)
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
        renderer?.setPalette(paletteIndex)
        renderer?.setContrast(Float(contrast))
        renderer?.needsRender = true
        mtkView?.setNeedsDisplay()
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
    private let kPalette = "palette"
    private let kContrast = "contrast"

    func saveState(palette: Int, contrast: Double) {
        let d = UserDefaults.standard
        d.set(contrast, forKey: kContrast)
        d.set(center.x, forKey: kCenterX)
        d.set(center.y, forKey: kCenterY)
        d.set(scalePixelsPerUnit, forKey: kScale)
        d.set(maxIterations, forKey: kIters)
        d.set(palette, forKey: kPalette)
    }

    func loadState() -> (palette: Int, contrast: Double)? {
        let d = UserDefaults.standard
        guard d.object(forKey: kCenterX) != nil else { return nil }
        let cx = d.double(forKey: kCenterX)
        let cy = d.double(forKey: kCenterY)
        center = SIMD2<Double>(cx, cy)
        scalePixelsPerUnit = max(0.01, d.double(forKey: kScale))
        maxIterations = max(100, d.integer(forKey: kIters))
        let palette = d.integer(forKey: kPalette)
        let c = d.object(forKey: kContrast) != nil ? d.double(forKey: kContrast) : 1.0
        contrast = c
        paletteIndex = palette
        return (palette, c)
    }
}
