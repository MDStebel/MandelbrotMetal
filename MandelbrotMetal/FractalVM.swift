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
    @Published var center = SIMD2<Double>(-0.5, 0.0)
    @Published var scalePixelsPerUnit: Double = 1
    @Published var maxIterations: Int = 800
    @Published var baselineScale: Double = 1

    var viewSize: CGSize = .zero

    var renderer: MandelbrotRenderer?
    weak var mtkView: MTKView?

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
