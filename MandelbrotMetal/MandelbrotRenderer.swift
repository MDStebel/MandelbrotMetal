//
//  MandelbrotRenderer.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/8/25.
//

import Foundation
import MetalKit
import UIKit
import simd

extension Notification.Name {
    static let MandelbrotRendererFallback = Notification.Name("MandelbrotRendererFallback")
    static let SSAAStateChanged = Notification.Name("MandelbrotRenderer.SSAAStateChanged")
}

/// IMPORTANT: This struct must exactly match the struct in my file `mandelbrot.metal`.
/// If I change the Metal struct, remember to mirror the same field order, sizes and padding here.
struct MandelbrotUniforms {
    // Base float mapping
    var origin: SIMD2<Float>
    var step:   SIMD2<Float>
    var maxIt:  Int32
    var size:   SIMD2<UInt32>
    var pixelStep: Int32
    
    // Quality and color
    var subpixelSamples: Int32   // 1 or 4
    var palette: Int32           // 0=HSV, 1=Fire, 2=Ocean, 3=LUT
    var deepMode: Int32          // 0=float, 1=DS, 2=DD
    var _pad0: Int32             // keep 16B alignment
    
    var contrast: Float = 1.0    // contrast shaping for normalized t (1.0 = neutral)
    
    // Double-single mapping splits
    var originHi: SIMD2<Float>
    var originLo: SIMD2<Float>
    var stepHi:   SIMD2<Float>
    var stepLo:   SIMD2<Float>
    
    // Perturbation (optional)
    var perturbation: Int32      // 0/1
    var refCount: Int32          // entries in ref orbit buffer
    var c0: SIMD2<Float>         // reference c
    var _pad1: SIMD2<Float>      // keep 16B alignment
}

final class MandelbrotRenderer: NSObject, MTKViewDelegate {
    
    // MARK: - Metal objects
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let pipelinePerturb: MTLComputePipelineState?
    
    // Offscreen render target (blit to drawable)
    private var outTex: MTLTexture?
    private var paletteTexture: MTLTexture?
    private var dummyPaletteTex: MTLTexture?
    
    // Optional perturbation reference orbit
    private var refOrbitBuffer: MTLBuffer?
    private var dummyOrbitBuffer: MTLBuffer?
    
    private var refinePending = false
    private var highQualityIdle = true
    
    /// Optional manual precision override: nil = auto, 0=float, 1=DS, 2=DD
    private var precisionOverride: Int32? = nil
    
    private weak var mtkViewRef: MTKView?

    /// Remember last zoom to recompute SSAA when interaction toggles
    private var lastScalePPU: Double = 0.0
    /// Anchor zoom at which the current SSAA tier was last committed
    private var ssaaAnchorZ: Double = 0.0
    
    /// Exposes whether sub‑pixel SSAA is active (≥4 samples)
    var isSSAAActive: Bool { uniforms.subpixelSamples >= 4 }
    /// Current SSAA sample count (1, 4, 9, or 16)
    var ssaaSamples: Int { Int(uniforms.subpixelSamples) }

    /// Current SSAA factor (1, 2, 3, 4) derived from samples (1, 4, 9, 16)
    var ssaaFactor: Int {
        switch uniforms.subpixelSamples {
        case 4:  return 2
        case 9:  return 3
        case 16: return 4
        default: return 1
        }
    }

    /// Returns current SSAA state for HUD: (active, samples, factor)
    func ssaaInfo() -> (active: Bool, samples: Int, factor: Int) {
        let samples = Int(uniforms.subpixelSamples)
        let factor: Int
        switch samples {
        case 4:  factor = 2
        case 9:  factor = 3
        case 16: factor = 4
        default: factor = 1
        }
        return (samples >= 4, samples, factor)
    }
    
    var needsRender = true
    
    // Tunables
    private let deepZoomThreshold: Double = 1.0e4 // switch to DS mapping here
    private let ddZoomThreshold: Double = 1.0e7   // switch to DD mapping here

    /// SSAA thresholds with hysteresis (idle)
    private let ssaaIdleUp:    [Double: Int32] = [1.0e5: 4, 1.0e7: 9, 1.0e9: 16]
    private let ssaaIdleDown:  [Double: Int32] = [7.5e4: 1, 7.5e6: 4, 7.5e8: 9] // 0.75× bands

    /// SSAA thresholds with hysteresis (interactive/dragging)
    private let ssaaLiveUp:    [Double: Int32] = [1.0e6: 4, 1.0e8: 9]
    private let ssaaLiveDown:  [Double: Int32] = [7.5e5: 1, 7.5e7: 4]

    /// Additional debounce to prevent SSAA bounce: require a meaningful zoom delta
    private let ssaaMinRatioUp: Double = 1.6   // must zoom in by ≥1.6× since last tier change
    private let ssaaMinRatioDown: Double = 1.6 // must zoom out by ≥1.6× since last tier change
    
    private var uniforms = MandelbrotUniforms(
        origin: .zero,
        step: .init(
            0.005,
            0.005
        ),
        maxIt: 500,
        size: .zero,
        pixelStep: 1,
        subpixelSamples: 1,
        palette: 0,
        deepMode: 0,
        _pad0: 0,
        contrast: 1.0,
        originHi: .zero,
        originLo: .zero,
        stepHi: .zero,
        stepLo: .zero,
        perturbation: 0,
        refCount: 0,
        c0: .zero,
        _pad1: .zero
    )
    
    // MARK: - Lifecycle
    init?(mtkView: MTKView) {
        print("MandelbrotRenderer.init: starting…")
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MandelbrotRenderer.init: **NO METAL DEVICE** — cannot create renderer")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            print("MandelbrotRenderer.init: **FAILED** to make command queue")
            return nil
        }
        self.device = device
        self.queue = queue
        
        do {
            let lib = try device.makeDefaultLibrary(bundle: .main)
            
            // Primary kernel
            guard let fnMain = lib.makeFunction(name: "mandelbrotKernel") else {
                print("MandelbrotRenderer.init: **KERNEL NOT FOUND** (mandelbrotKernel) in default library")
                return nil
            }
            self.pipeline = try device.makeComputePipelineState(function: fnMain)
            
            // Optional perturbation kernel (same bindings)
            if let fnPerturb = lib.makeFunction(name: "mandelbrotKernelPerturb") {
                self.pipelinePerturb = try? device.makeComputePipelineState(function: fnPerturb)
                if self.pipelinePerturb == nil {
                    print("MandelbrotRenderer.init: warn: failed to create pipeline for mandelbrotKernelPerturb; will fall back to main kernel")
                }
            } else {
                self.pipelinePerturb = nil
                print("MandelbrotRenderer.init: mandelbrotKernelPerturb not found; running without perturbation pipeline")
            }
            
            print("MandelbrotRenderer.init: pipeline(s) created")
        } catch {
            print("MandelbrotRenderer.init: **FAILED** to build library/pipeline: \(error)")
            return nil
        }
        
        super.init()
        mtkViewRef = mtkView
        
        // MTKView config
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isOpaque = true
        mtkView.framebufferOnly = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.drawableSize = CGSize(
            width: UIScreen.main.bounds.width * UIScreen.main.scale,
            height: UIScreen.main.bounds.height * UIScreen.main.scale
        )
        mtkView.delegate = self
        // Disable perturbation by default; the reference orbit will be built on the first setViewport()
        // and subsequently rebuilt on viewport changes (see setViewport(_:)).
        uniforms.perturbation = 0  // default OFF; enable via UI with setPerturbation(true)
        print("MandelbrotRenderer.init: complete. framebufferOnly=\(mtkView.framebufferOnly)")
    }
    
    // MARK: - SSAA Tier Selection
    /// Decide SSAA tier (samples per pixel: 1,4,9,16) for given zoom and state, with hysteresis.
    private func chooseSSAA(z: Double,
                            wasZ: Double,
                            prevSamples: Int32,
                            idle: Bool,
                            deepMode: Int32) -> Int32 {
        // Select the correct threshold tables
        let up   = idle ? ssaaIdleUp   : ssaaLiveUp
        let down = idle ? ssaaIdleDown : ssaaLiveDown

        // Direction checks with a small epsilon
        let eps = 1e-6
        let zoomingIn  = z > wasZ + eps
        let zoomingOut = z < wasZ - eps

        // Helper to compute the desired tier for a given table.
        func tier(for value: Double, using table: [Double: Int32]) -> Int32 {
            var chosen: Int32 = 1
            for (th, t) in table.sorted(by: { $0.key < $1.key }) {
                if value >= th { chosen = t }
            }
            return chosen
        }

        var proposedUp = tier(for: z, using: up)
        var proposedDown = tier(for: z, using: down)

        // Cap 16-sample tier unless we're in true DD (deepMode==2)
        if deepMode < 2 && proposedUp == 16 { proposedUp = 9 }
        if deepMode < 2 && proposedDown == 16 { proposedDown = 9 }

        // Hysteresis: only allow increases while zooming IN, and decreases while zooming OUT.
        var result = prevSamples
        if zoomingIn {
            result = max(prevSamples, proposedUp)
        } else if zoomingOut {
            result = min(prevSamples, proposedDown)
        } else {
            // No clear direction: hold the previous tier unless we crossed far beyond "up"
            result = max(prevSamples, proposedUp)
        }

        // --- Additional stabilization using an anchor zoom value ---
        // Only allow tier increases if we've zoomed in *enough* since the last change
        if result > prevSamples {
            // If this is the first time, initialize the anchor
            if ssaaAnchorZ <= 0 { ssaaAnchorZ = max(1.0, z) }
            let required = max(ssaaAnchorZ * ssaaMinRatioUp, wasZ * 1.05) // also avoid micro wiggles
            if z < required {
                result = prevSamples // not enough zoom-in to warrant a jump
            }
        }
        // Only allow tier decreases if we've zoomed out *enough* since the last change
        if result < prevSamples {
            if ssaaAnchorZ <= 0 { ssaaAnchorZ = max(1.0, z) }
            let required = min(ssaaAnchorZ / ssaaMinRatioDown, wasZ / 1.05)
            if z > required {
                result = prevSamples // not enough zoom-out to drop a tier
            }
        }
        // If we truly changed the tier, move the anchor to the new zoom
        if result != prevSamples {
            ssaaAnchorZ = max(1.0, z)
        }
        return result
    }

    // MARK: - Public knobs (called from UI)
    /// Toggle fast/idle quality (keeps full resolution; adjusts iteration count only).
    func setInteractive(_ on: Bool, baseIterations: Int) {
        uniforms.pixelStep = 1
        if on {
            uniforms.maxIt = Int32(max(50, baseIterations / 2))
            refinePending = false
        } else {
            uniforms.maxIt = Int32(max(1, baseIterations))
            refinePending = highQualityIdle
        }
        // Recompute SSAA from last zoom using hysteresis; do not force a downshift due to the toggle.
        let prev = uniforms.subpixelSamples
        let target = chooseSSAA(z: lastScalePPU,
                                wasZ: lastScalePPU,     // no direction implied by toggle
                                prevSamples: prev,
                                idle: !on && highQualityIdle,
                                deepMode: uniforms.deepMode)
        let newSamples = max(prev, target)
        if newSamples != prev {
            uniforms.subpixelSamples = newSamples
            NotificationCenter.default.post(name: .SSAAStateChanged,
                                            object: self,
                                            userInfo: ["active": (newSamples >= 4),
                                                       "samples": Int(newSamples),
                                                       "factor": self.ssaaFactor])
        }
        needsRender = true
        DispatchQueue.main.async { [weak self] in self?.mtkViewRef?.setNeedsDisplay() }
    }
    
    func setContrast(_ value: Float) {
        // avoid divide-by-zero in kernel; 1.0 = neutral
        uniforms.contrast = max(0.01, value)
        needsRender = true
        mtkViewRef?.setNeedsDisplay()
    }
    
    func setPalette(_ mode: Int) {
        uniforms.palette = Int32(mode)
        needsRender = true
    }
    
    func setMaxIterations(_ it: Int) {
        uniforms.maxIt = Int32(max(1, it))
        refinePending = highQualityIdle
        needsRender = true
    }
    
    /// Deep Zoom is effectively always on now (DS mapping is enabled by threshold below).
    func setDeepZoom(_ on: Bool) {
        // Kept for API compatibility; behavior controlled by setViewport.
        needsRender = true
    }

    /// Set precision mode override. Pass nil for automatic (by zoom thresholds), or 0/1/2 for Float/DS/DD.
    func setPrecisionMode(_ mode: Int?) {
        if let m = mode {
            let clamped = max(0, min(2, m))
            precisionOverride = Int32(clamped)
        } else {
            precisionOverride = nil
        }
        needsRender = true
        DispatchQueue.main.async { [weak self] in self?.mtkViewRef?.setNeedsDisplay() }
    }
    
    func setHighQualityIdle(_ on: Bool) {
        highQualityIdle = on
        refinePending = on
        needsRender = true
    }
    
    func setPerturbation(_ on: Bool) {
        uniforms.perturbation = on ? 1 : 0
        if on {
            // Build initial reference orbit at current center
            let w = Int(uniforms.size.x), h = Int(uniforms.size.y)
            guard w > 0 && h > 0 else { return }
            let c0x = Double(uniforms.origin.x) + Double(w) * 0.5 * Double(uniforms.step.x)
            let c0y = Double(uniforms.origin.y) + Double(h) * 0.5 * Double(uniforms.step.y)
            buildReferenceOrbit(c0: SIMD2<Double>(c0x, c0y), maxIt: Int(uniforms.maxIt))
        }
        needsRender = true
    }
    
    func recenterReference(atComplex c: SIMD2<Double>, iterations: Int? = nil) {
        buildReferenceOrbit(c0: c, maxIt: max(1, iterations ?? Int(uniforms.maxIt)))
        needsRender = true
    }
    
    // MARK: - Viewport
    func setViewport(center: SIMD2<Double>,
                     scalePixelsPerUnit: Double,
                     sizePts: CGSize,
                     screenScale: CGFloat,
                     maxIterations: Int) {
        // Remember previous zoom for SSAA monotonicity logic.
        let wasScalePPU = lastScalePPU
        guard sizePts.width.isFinite, sizePts.height.isFinite, screenScale.isFinite else { return }
        
        let pixelW = max(1, Int((sizePts.width * screenScale).rounded()))
        let pixelH = max(1, Int((sizePts.height * screenScale).rounded()))
        uniforms.size = SIMD2<UInt32>(UInt32(pixelW), UInt32(pixelH))
        uniforms.maxIt = Int32(max(1, maxIterations))
        uniforms.pixelStep = 1
//        let prevSSAA = (uniforms.subpixelSamples >= 4)
        
        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        
        // ---- Precision selection: Float → DS → DD ----
        if let override = precisionOverride {
            uniforms.deepMode = override
        } else if scalePixelsPerUnit >= ddZoomThreshold {
            uniforms.deepMode = 2   // Double‑Double path
        } else if scalePixelsPerUnit >= deepZoomThreshold {
            uniforms.deepMode = 1   // Double‑Single path
        } else {
            uniforms.deepMode = 0   // Float path
        }
        
        // Pick SSAA based on zoom, previous zoom, previous samples, idle state and precision mode.
        let prevSamples = uniforms.subpixelSamples
        let proposed = chooseSSAA(z: scalePixelsPerUnit,
                                  wasZ: wasScalePPU,
                                  prevSamples: prevSamples,
                                  idle: highQualityIdle,
                                  deepMode: uniforms.deepMode)

        if uniforms.subpixelSamples != proposed {
            let before = uniforms.subpixelSamples
            uniforms.subpixelSamples = proposed
            let factorBefore: Int = (before == 16 ? 4 : (before == 9 ? 3 : (before == 4 ? 2 : 1)))
            let factorAfter:  Int = (proposed == 16 ? 4 : (proposed == 9 ? 3 : (proposed == 4 ? 2 : 1)))
//            print(String(format: "[SSAA] z=%.3e was=%.3e deep=%d idle=%@ prev=%d -> proposed=%d",
//                         scalePixelsPerUnit, wasScalePPU, uniforms.deepMode, String(highQualityIdle), before, proposed))
            if factorAfter != factorBefore {
                NotificationCenter.default.post(name: .SSAAStateChanged,
                                                object: self,
                                                userInfo: [
                                                    "active": (proposed >= 4),
                                                    "samples": Int(proposed),
                                                    "factor": factorAfter
                                                ])
            }
            ssaaAnchorZ = max(1.0, scalePixelsPerUnit)
        }

        // Update lastScalePPU for next time
        lastScalePPU = scalePixelsPerUnit
        
        // Base mapping
        let halfW = 0.5 * Double(pixelW)
        let halfH = 0.5 * Double(pixelH)
        let originX = center.x - halfW * invScale
        let originY = center.y - halfH * invScale
        uniforms.origin = .init(Float(originX), Float(originY))
        uniforms.step   = .init(Float(invScale), Float(invScale))
        
        @inline(__always)
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }
        // DS splits
        let (oHx, oLx) = split(originX)
        let (oHy, oLy) = split(originY)
        let (sHx, sLx) = split(invScale)
        let (sHy, sLy) = split(invScale)
        uniforms.originHi = .init(oHx, oHy)
        uniforms.originLo = .init(oLx, oLy)
        uniforms.stepHi   = .init(sHx, sHy)
        uniforms.stepLo   = .init(sLx, sLy)
        
        // Rebuild perturbation orbit when enabled
        if uniforms.perturbation != 0 {
            let w = Int(uniforms.size.x), h = Int(uniforms.size.y)
            if w > 0 && h > 0 {
                let c0x = Double(uniforms.origin.x) + Double(w) * 0.5 * Double(uniforms.step.x)
                let c0y = Double(uniforms.origin.y) + Double(h) * 0.5 * Double(uniforms.step.y)
                buildReferenceOrbit(c0: SIMD2<Double>(c0x, c0y), maxIt: Int(uniforms.maxIt))
            }
        }
        
        allocateTextureIfNeeded(width: pixelW, height: pixelH)
        refinePending = highQualityIdle
        needsRender = true
    }
    
    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else {
            print("drawableSizeWillChange: non-finite size, skipping")
            return
        }
        allocateTextureIfNeeded(width: Int(size.width.rounded()),
                                height: Int(size.height.rounded()))
        needsRender = true
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else {
            print("MandelbrotRenderer.draw: missing drawable or cmd buffer")
            return
        }
        
        let dw = drawable.texture.width
        let dh = drawable.texture.height
        guard dw > 0, dh > 0 else {
            cmd.commit()
            return
        }
        
        if outTex == nil || outTex?.width != dw || outTex?.height != dh {
            allocateTextureIfNeeded(width: dw, height: dh)
        }
        guard let outTex = self.outTex else {
            drawable.present()
            cmd.commit()
            return
        }
        
        // Seed uniforms on first draw
        if uniforms.size.x == 0 || uniforms.size.y == 0 {
            uniforms.size = SIMD2<UInt32>(UInt32(dw), UInt32(dh))
            let scalePixelsPerUnit = Double(dw) / 3.5
            let invScale = 1.0 / max(1e-9, scalePixelsPerUnit)
            let center = SIMD2<Double>(-0.5, 0.0)
            let originX = center.x - 0.5 * Double(dw) * invScale
            let originY = center.y - 0.5 * Double(dh) * invScale
            uniforms.origin = SIMD2<Float>(Float(originX), Float(originY))
            uniforms.step   = SIMD2<Float>(Float(invScale), Float(invScale))
            @inline(__always)
            func split(_ d: Double) -> (Float, Float) {
                let hi = Float(d)
                let lo = Float(d - Double(hi))
                return (hi, lo)
            }
            let (oHx, oLx) = split(originX)
            let (oHy, oLy) = split(originY)
            let (sHx, sLx) = split(invScale)
            let (sHy, sLy) = split(invScale)
            uniforms.originHi = SIMD2<Float>(oHx, oHy)
            uniforms.originLo = SIMD2<Float>(oLx, oLy)
            uniforms.stepHi   = SIMD2<Float>(sHx, sHy)
            uniforms.stepLo   = SIMD2<Float>(sLx, sLy)

            // Ensure SSAA is reasonable for the first frame
            lastScalePPU = Double(dw) / 3.5
            let firstSSAA = chooseSSAA(
                z: lastScalePPU,
                wasZ: lastScalePPU,
                prevSamples: uniforms.subpixelSamples,
                idle: highQualityIdle,
                deepMode: uniforms.deepMode
            )
            uniforms.subpixelSamples = firstSSAA
            ssaaAnchorZ = max(1.0, lastScalePPU)
            // Notify initial SSAA state for HUD
            let initialFactor: Int
            switch firstSSAA {
            case 4:  initialFactor = 2
            case 9:  initialFactor = 3
            case 16: initialFactor = 4
            default: initialFactor = 1
            }
            NotificationCenter.default.post(name: .SSAAStateChanged,
                                            object: self,
                                            userInfo: [
                                                "active": (firstSSAA >= 4),
                                                "samples": Int(firstSSAA),
                                                "factor": initialFactor
                                            ])
        }
        
        validateBindingsAndFallback()
        
        // Encode compute kernel
        if let enc = cmd.makeComputeCommandEncoder() {
            // Pick kernel: use perturb version only when enabled, orbit present, and pipeline available
            let usePerturb = (uniforms.perturbation != 0 && uniforms.refCount > 0 && pipelinePerturb != nil)
            let pipe = usePerturb ? pipelinePerturb! : pipeline
            enc.setComputePipelineState(pipe)
            
            var u = uniforms
            // Bindings must match the kernel signature:
            // buffer(0): uniforms, buffer(1): refOrbit (optional), tex(0): outTex, tex(1): paletteTex
            enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
            let orbitBuf = (u.perturbation != 0 && u.refCount > 0) ? (refOrbitBuffer ?? ensureDummyOrbitBuffer()) : ensureDummyOrbitBuffer()
            enc.setBuffer(orbitBuf, offset: 0, index: 1)
            enc.setTexture(outTex, index: 0)
            enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)
            
            // Uniform threadgroup sizing (simulator-safe)
            let w = pipe.threadExecutionWidth
            let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)
            let gridW = Int(u.size.x), gridH = Int(u.size.y)
            let groups = MTLSize(width:  (gridW + tg.width  - 1) / tg.width,
                                 height: (gridH + tg.height - 1) / tg.height,
                                 depth:  1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        
        // Blit offscreen -> drawable
        if let blit = cmd.makeBlitCommandEncoder() {
            let size = MTLSize(width: outTex.width, height: outTex.height, depth: 1)
            blit.copy(from: outTex,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: size,
                      to: drawable.texture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        
        drawable.present()
        
        // (Removed: No unconditional SSAA HUD notification here; HUD only updates on actual SSAA changes.)
        
        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            if self.highQualityIdle && self.refinePending {
                self.needsRender = true
                self.refinePending = false
                DispatchQueue.main.async { self.mtkViewRef?.setNeedsDisplay() }
            }
        }
        
        cmd.commit()
        needsRender = false
    }
    
    // MARK: - Snapshot (single pass)
    func makeSnapshot(width: Int,
                      height: Int,
                      center: SIMD2<Double>,
                      scalePixelsPerUnit: Double,
                      iterations: Int) -> UIImage? {
        
        guard width > 0, height > 0,
              let cmd = queue.makeCommandBuffer() else {
            print("[Snapshot] early exit: bad size or no command buffer")
            return nil
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let snapTex = device.makeTexture(descriptor: desc) else {
            print("[Snapshot] failed to allocate snapTex")
            return nil
        }
        
        var u = uniforms
        u.size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        u.maxIt = Int32(max(1, max(iterations, Int(uniforms.maxIt))))
        u.pixelStep = 1
        // Force highest precision + SSAA for exports
        u.deepMode = 2   // use Double-Double for captures
        u.subpixelSamples = 4
        
        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let originX = center.x - 0.5 * Double(width) * invScale
        let originY = center.y - 0.5 * Double(height) * invScale
        u.origin = SIMD2<Float>(Float(originX), Float(originY))
        u.step   = SIMD2<Float>(Float(invScale), Float(invScale))
        
        @inline(__always)
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }
        let (oRx, oRxLo) = split(originX)
        let (oRy, oRyLo) = split(originY)
        let (sX,  sXLo)  = split(invScale)
        let (sY,  sYLo)  = split(invScale)
        u.originHi = SIMD2<Float>(oRx, oRy)
        u.originLo = SIMD2<Float>(oRxLo, oRyLo)
        u.stepHi   = SIMD2<Float>(sX, sY)
        u.stepLo   = SIMD2<Float>(sXLo, sYLo)
        
        if let enc = cmd.makeComputeCommandEncoder() {
            let usePerturb = (u.perturbation != 0 && u.refCount > 0 && pipelinePerturb != nil)
            let pipe = usePerturb ? pipelinePerturb! : pipeline
            enc.setComputePipelineState(pipe)
            var uLocal = u
            enc.setBytes(&uLocal, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
            let orbitBuf = (uLocal.perturbation != 0 && uLocal.refCount > 0) ? (self.refOrbitBuffer ?? self.ensureDummyOrbitBuffer()) : self.ensureDummyOrbitBuffer()
            enc.setBuffer(orbitBuf, offset: 0, index: 1)
            enc.setTexture(snapTex, index: 0)
            enc.setTexture(self.paletteTexture ?? self.ensureDummyPaletteTexture(), index: 1)
            let w = pipe.threadExecutionWidth
            let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)
            let gridW = Int(u.size.x), gridH = Int(u.size.y)
            let groups = MTLSize(width:  (gridW + tg.width  - 1) / tg.width,
                                 height: (gridH + tg.height - 1) / tg.height,
                                 depth:  1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        
        cmd.commit()
        cmd.waitUntilCompleted()
        
        // Readback
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { ptr in
            if let p = ptr.baseAddress {
                snapTex.getBytes(p, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, width, height),
                                 mipmapLevel: 0)
            }
        }
        
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        
        return UIImage(cgImage: cg)
    }
    
    // MARK: - Async Tiled Capture
    func captureAsyncTiled(width: Int,
                           height: Int,
                           tile: Int = 256,
                           center: SIMD2<Double>,
                           scalePixelsPerUnit: Double,
                           iterations: Int,
                           progress: @escaping (Double) -> Void,
                           completion: @escaping (UIImage?) -> Void) {
        let W = max(1, width)
        let H = max(1, height)
        let tileSize = max(64, tile)
        
        let bpp = 4
        let rowBytes = W * bpp
        var full = Data(count: rowBytes * H)
        
        var u = self.uniforms
        u.maxIt = Int32(max(1, iterations))
        u.pixelStep = 1
        u.deepMode = 2   // use Double-Double for tiled captures
        u.subpixelSamples = 4
        
        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let originXFull = center.x - 0.5 * Double(W) * invScale
        let originYFull = center.y - 0.5 * Double(H) * invScale
        
        @inline(__always)
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }
        
        // Build list of tiles in center-out order
        var tiles: [(x: Int, y: Int, w: Int, h: Int)] = []
        let cols = (W + tileSize - 1) / tileSize
        let rows = (H + tileSize - 1) / tileSize
        let cx = cols / 2
        let cy = rows / 2
        func tileRect(_ i: Int, _ j: Int) -> (x: Int, y: Int, w: Int, h: Int) {
            let x0 = i * tileSize
            let y0 = j * tileSize
            return (x0, y0, min(tileSize, W - x0), min(tileSize, H - y0))
        }
        var ring = 0
        while tiles.count < cols * rows {
            let iMin = max(0, cx - ring)
            let iMax = min(cols - 1, cx + ring)
            let jMin = max(0, cy - ring)
            let jMax = min(rows - 1, cy + ring)
            if jMin < rows { for i in iMin...iMax { tiles.append(tileRect(i, jMin)) } }
            if iMax < cols && jMin + 1 <= jMax { for j in (jMin + 1)...jMax { tiles.append(tileRect(iMax, j)) } }
            if jMax < rows && jMax != jMin { for i in stride(from: iMax, through: iMin, by: -1) { tiles.append(tileRect(i, jMax)) } }
            if iMin < cols && iMax != iMin && jMax - 1 >= jMin + 1 {
                for j in stride(from: jMax - 1, through: jMin + 1, by: -1) { tiles.append(tileRect(iMin, j)) }
            }
            ring += 1
            if tiles.count > cols * rows { tiles.removeLast(tiles.count - cols * rows) }
        }
        
        let renderQueue = DispatchQueue(label: "mandel.capture.queue", qos: .userInitiated)
        
        func finishImage(_ data: Data) {
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: data as CFData) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            guard let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: rowBytes, space: cs,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                   ),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { DispatchQueue.main.async { completion(nil) }; return }
            DispatchQueue.main.async { completion(UIImage(cgImage: cg)) }
        }
        
        func renderTile(at index: Int) {
            if index >= tiles.count { finishImage(full); return }
            let t = tiles[index]
            renderQueue.async {
                autoreleasepool {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                        width: t.w, height: t.h, mipmapped: false)
                    desc.usage = [.shaderWrite, .shaderRead]
                    desc.storageMode = .shared
                    guard let tex = self.device.makeTexture(descriptor: desc),
                          let cmd = self.queue.makeCommandBuffer() else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    
                    // Tile mapping
                    let tOriginX = originXFull + Double(t.x) * invScale
                    let tOriginY = originYFull + Double(t.y) * invScale
                    u.origin = SIMD2<Float>(Float(tOriginX), Float(tOriginY))
                    u.step   = SIMD2<Float>(Float(invScale), Float(invScale))
                    u.size   = SIMD2<UInt32>(UInt32(t.w), UInt32(t.h))
                    
                    let (oRx, oRxLo) = split(tOriginX)
                    let (oRy, oRyLo) = split(tOriginY)
                    let (sX,  sXLo)  = split(invScale)
                    let (sY,  sYLo)  = split(invScale)
                    u.originHi = SIMD2<Float>(oRx, oRy)
                    u.originLo = SIMD2<Float>(oRxLo, oRyLo)
                    u.stepHi   = SIMD2<Float>(sX, sY)
                    u.stepLo   = SIMD2<Float>(sXLo, sYLo)
                    
                    if let enc = cmd.makeComputeCommandEncoder() {
                        var uLocal = u
                        if uLocal.palette == 3 && self.paletteTexture == nil { uLocal.palette = 0 }
                        
                        let usePerturb = (uLocal.perturbation != 0 && uLocal.refCount > 0 && self.pipelinePerturb != nil)
                        let pipe = usePerturb ? self.pipelinePerturb! : self.pipeline
                        enc.setComputePipelineState(pipe)
                        
                        enc.setBytes(&uLocal, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
                        let orbitBuf = (uLocal.perturbation != 0 && uLocal.refCount > 0)
                        ? (self.refOrbitBuffer ?? self.ensureDummyOrbitBuffer())
                        : self.ensureDummyOrbitBuffer()
                        enc.setBuffer(orbitBuf, offset: 0, index: 1)
                        enc.setTexture(tex, index: 0)
                        enc.setTexture(self.paletteTexture ?? self.ensureDummyPaletteTexture(), index: 1)
                        
                        let wth = pipe.threadExecutionWidth
                        let hth = max(1, pipe.maxTotalThreadsPerThreadgroup / wth)
                        let tg = MTLSize(width: wth, height: hth, depth: 1)
                        let groups = MTLSize(width:  (t.w + tg.width  - 1) / tg.width,
                                             height: (t.h + tg.height - 1) / tg.height,
                                             depth:  1)
                        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                        enc.endEncoding()
                    }
                    
                    cmd.addCompletedHandler { _ in
                        full.withUnsafeMutableBytes { p in
                            guard let base = p.baseAddress else { return }
                            let region = MTLRegionMake2D(0, 0, t.w, t.h)
                            tex.getBytes(base.advanced(by: t.y * rowBytes + t.x * bpp),
                                         bytesPerRow: rowBytes,
                                         from: region, mipmapLevel: 0)
                        }
                        let pct = Double(index + 1) / Double(tiles.count)
                        DispatchQueue.main.async { progress(pct) }
                        renderTile(at: index + 1)
                    }
                    
                    cmd.commit()
                }
            }
        }
        
        DispatchQueue.main.async { progress(0.0) }
        renderTile(at: 0)
    }
    
    // MARK: - Helpers / fallback
    
    private func validateBindingsAndFallback() {
        if uniforms.palette == 3 && paletteTexture == nil {
            let msg = "LUT unavailable: fell back to HSV"
            print("[Renderer] \(msg)")
            uniforms.palette = 0
            NotificationCenter.default.post(name: .MandelbrotRendererFallback, object: self, userInfo: ["reason": msg])
        }
        if uniforms.perturbation != 0 && refOrbitBuffer == nil {
            let msg = "Perturbation off: no reference orbit bound"
            print("[Renderer] \(msg)")
            uniforms.perturbation = 0
            NotificationCenter.default.post(name: .MandelbrotRendererFallback, object: self, userInfo: ["reason": msg])
        }
    }
    
    private func ensureDummyOrbitBuffer() -> MTLBuffer? {
        if let b = dummyOrbitBuffer { return b }
        var zero = SIMD2<Float>(repeating: 0)
        dummyOrbitBuffer = device.makeBuffer(bytes: &zero,
                                             length: MemoryLayout<SIMD2<Float>>.stride,
                                             options: .storageModeShared)
        return dummyOrbitBuffer
    }
    
    private func buildReferenceOrbit(c0: SIMD2<Double>, maxIt: Int) {
        var orbit = [SIMD2<Float>](repeating: .zero, count: maxIt)
        var zr = 0.0, zi = 0.0
        for i in 0..<maxIt {
            let zr2 = zr*zr - zi*zi + c0.x
            let zi2 = 2.0*zr*zi + c0.y
            zr = zr2; zi = zi2
            orbit[i] = SIMD2<Float>(Float(zr), Float(zi))
        }
        uniforms.c0 = SIMD2<Float>(Float(c0.x), Float(c0.y))
        uniforms.refCount = Int32(maxIt)
        let length = orbit.count * MemoryLayout<SIMD2<Float>>.stride
        refOrbitBuffer = device.makeBuffer(bytes: orbit, length: length, options: .storageModeShared)
        print("[Perturb] orbit len=\(maxIt) c0=\(c0)")
    }
    
    private func ensureDummyPaletteTexture() -> MTLTexture? {
        if let t = dummyPaletteTex { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var pixel: UInt32 = 0xFFFFFFFF // BGRA white
        withUnsafeBytes(of: &pixel) { bytes in
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: bytes.baseAddress!,
                        bytesPerRow: 4)
        }
        dummyPaletteTex = tex
        return tex
    }
    
    private func allocateTextureIfNeeded(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if let t = outTex, t.width == width, t.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        outTex = device.makeTexture(descriptor: desc)
    }
    
    // Upload a custom LUT image (BGRA8)
    func setPaletteImage(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return }
        
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: base, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                   ).rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress {
                tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        self.paletteTexture = tex
        self.needsRender = true
    }
}

extension MandelbrotRenderer {
    /// Convenience: reset contrast to default (1.0) and trigger a redraw.
    func resetContrast() {
        setContrast(1.0)
    }

    /// Read current contrast value (1.0 = neutral)
    func getContrast() -> Float {
        return uniforms.contrast
    }
}
