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
}

// Must match the Metal struct exactly.
struct MandelbrotUniforms {
    var origin: SIMD2<Float>
    var step: SIMD2<Float>
    var maxIt: Int32
    var size: SIMD2<UInt32>
    var pixelStep: Int32
    var palette: Int32
    var deepMode: Int32
    var originHi: SIMD2<Float>
    var originLo: SIMD2<Float>
    var stepHi: SIMD2<Float>
    var stepLo: SIMD2<Float>
    var perturbation: Int32
    var c0: SIMD2<Float>
    var subpixelSamples: Int32
}

final class MandelbrotRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal objects
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    // Offscreen texture (we blit to the drawable)
    private var outTex: MTLTexture?
    private var paletteTexture: MTLTexture?
    private var dummyPaletteTex: MTLTexture?
    
    private weak var mtkViewRef: MTKView?
    private var refinePending = false
    private var highQualityIdle = true

    // MARK: - State
    var needsRender = true

    private var uniforms = MandelbrotUniforms(
        origin: .zero,
        step: .init(0.005, 0.005),
        maxIt: 500,
        size: .zero,
        pixelStep: 1,
        palette: 0,
        deepMode: 1,
        originHi: .zero,
        originLo: .zero,
        stepHi: .zero,
        stepLo: .zero,
        perturbation: 0,
        c0: .zero,
        subpixelSamples: 1
    )

    // Enable deep precision sooner to reduce blockiness
    private let deepZoomThreshold: Double = 1.0e4

    // MARK: - Public knobs (called from UI)
    /// Toggle between interactive (fast) and idle (refined) rendering, and trigger a render immediately.
    func setInteractive(_ on: Bool, baseIterations: Int) {
        // Always render at full pixel resolution; vary quality via iterations and sub‑pixel samples.
        uniforms.pixelStep = 1

        if on {
            // FAST path while user is touching: fewer iterations, single sample, no refine queued
            uniforms.maxIt = Int32(max(50, baseIterations / 2))
            uniforms.subpixelSamples = 1
            refinePending = false
        } else {
            // IDLE path: restore iterations target; queue a refine pass if enabled
            uniforms.maxIt = Int32(max(1, baseIterations))
            uniforms.subpixelSamples = 1   // first pass
            refinePending = highQualityIdle // schedule 4× pass after this frame
        }

        needsRender = true
        // Ensure MTKView wakes up to draw the pass immediately
        DispatchQueue.main.async { [weak self] in self?.mtkViewRef?.setNeedsDisplay() }
    }

    func setPalette(_ mode: Int) {
        uniforms.palette = Int32(mode)
        needsRender = true
    }

    func setMaxIterations(_ it: Int) {
        uniforms.maxIt = Int32(max(1, it))
        uniforms.subpixelSamples = 1
        refinePending = highQualityIdle
        needsRender = true
    }

    func setDeepZoom(_ on: Bool) {
        // Deep Zoom is now always-on; keep method for API compatibility.
        uniforms.deepMode = 1
        needsRender = true
    }

    func setHighQualityIdle(_ on: Bool) {
        highQualityIdle = on
        if on {
            // schedule a refine on next frame
            uniforms.subpixelSamples = 1
            refinePending = true
        } else {
            // stick to single-sample; cancel any queued refine
            uniforms.subpixelSamples = 1
            refinePending = false
        }
        needsRender = true
    }

    // Compatibility no-ops so existing UI compiles/runs even though perturbation is removed.
    func setPerturbation(_ on: Bool) {
        if on {
            print("[Renderer] Perturbation mode was removed; ignoring toggle ON")
            NotificationCenter.default.post(
                name: .MandelbrotRendererFallback,
                object: self,
                userInfo: ["reason": "Perturbation not available"]
            )
        }
    }
    func recenterReference(atComplex c: SIMD2<Double>, iterations: Int? = nil) {
        // no-op
        print("[Renderer] recenterReference() is a no-op (perturbation removed)")
    }

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
            guard let fn = lib.makeFunction(name: "mandelbrotKernel") else {
                print("MandelbrotRenderer.init: **KERNEL NOT FOUND** in default library")
                return nil
            }
            self.pipeline = try device.makeComputePipelineState(function: fn)
            self.uniforms.deepMode = 1
            print("MandelbrotRenderer.init: pipeline created")
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
        print("MandelbrotRenderer.init: complete. framebufferOnly=\(mtkView.framebufferOnly)")
    }

    // MARK: - Viewport
    func setViewport(center: SIMD2<Double>,
                     scalePixelsPerUnit: Double,
                     sizePts: CGSize,
                     screenScale: CGFloat,
                     maxIterations: Int)
    {
        print("Viewport center=\(center) scale=\(scalePixelsPerUnit) px=\(uniforms.size) origin=\(uniforms.origin) step=\(uniforms.step) it=\(uniforms.maxIt)")

        guard sizePts.width.isFinite, sizePts.height.isFinite,
              screenScale.isFinite else { return }

        let pixelW = max(1, Int((sizePts.width * screenScale).rounded()))
        let pixelH = max(1, Int((sizePts.height * screenScale).rounded()))
        uniforms.size = SIMD2<UInt32>(UInt32(pixelW), UInt32(pixelH))
        uniforms.maxIt = Int32(max(1, maxIterations))
        uniforms.pixelStep = 1

        let invScale = 1.0 / max(1e-9, scalePixelsPerUnit)

        // Always enable double-single mapping & iteration to avoid blockiness at any zoom.
        uniforms.deepMode = 1

        // Origin/step in float (legacy)
        let halfW = 0.5 * Double(pixelW)
        let halfH = 0.5 * Double(pixelH)
        let originX = center.x - halfW * invScale
        let originY = center.y - halfH * invScale
        uniforms.origin = SIMD2<Float>(Float(originX), Float(originY))
        uniforms.step   = SIMD2<Float>(Float(invScale), Float(invScale))

        // Hi/Lo splits for DS mapping in the kernel
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }
        let (oRx, oRxLo) = split(originX)
        let (oRy, oRyLo) = split(originY)
        let (sX,  sXLo)  = split(invScale)
        let (sY,  sYLo)  = split(invScale)

        uniforms.originHi = SIMD2<Float>(oRx, oRy)
        uniforms.originLo = SIMD2<Float>(oRxLo, oRyLo)
        uniforms.stepHi   = SIMD2<Float>(sX,  sY)
        uniforms.stepLo   = SIMD2<Float>(sXLo, sYLo)

        allocateTextureIfNeeded(width: pixelW, height: pixelH)
        uniforms.subpixelSamples = 1
        refinePending = highQualityIdle
        needsRender = true
    }

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        print("mtkView drawableSizeWillChange ->", size)
        let wF = size.width, hF = size.height
        guard wF.isFinite, hF.isFinite else {
            print("drawableSizeWillChange: non-finite size, skipping")
            return
        }
        let w = max(1, Int(wF.rounded()))
        let h = max(1, Int(hF.rounded()))
        allocateTextureIfNeeded(width: w, height: h)
        needsRender = true
    }

    func draw(in view: MTKView) {
        // Optional: skip if not requested
        // if !needsRender { return }

        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else {
            print("MandelbrotRenderer.draw: missing drawable or cmd buffer")
            return
        }

        let dw = drawable.texture.width
        let dh = drawable.texture.height
        guard dw > 0, dh > 0 else {
            print("draw: drawable has non-positive size (\(dw)x\(dh)), skipping frame")
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
        }

        // Validate palette bindings and fallback if necessary, each frame
        validateBindingsAndFallback()
        // Encode compute
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            var u = uniforms
            enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
            enc.setTexture(outTex, index: 0)
            enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)

            // Uniform threadgroup sizing (simulator-safe)
            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)

            let gridW = Int(uniforms.size.x)
            let gridH = Int(uniforms.size.y)
            let groups = MTLSize(
                width:  (gridW + tg.width  - 1) / tg.width,
                height: (gridH + tg.height - 1) / tg.height,
                depth:  1
            )
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
        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            if self.highQualityIdle && self.refinePending {
                self.uniforms.subpixelSamples = 4
                self.needsRender = true
                self.refinePending = false
                DispatchQueue.main.async { self.mtkViewRef?.setNeedsDisplay() }
            }
        }
        cmd.commit()
        needsRender = false
    }

    // MARK: - Snapshot (Tiled Ultra-Hi-Res)
    func makeSnapshotTiled(width: Int,
                           height: Int,
                           tile: Int = 1024,
                           center: SIMD2<Double>,
                           scalePixelsPerUnit: Double,
                           iterations: Int) -> UIImage? {
        let W = max(1, width)
        let H = max(1, height)
        let tileSize = max(64, tile)

        let bpp = 4
        let rowBytes = W * bpp
        var full = Data(count: rowBytes * H)

        var u = uniforms
        u.maxIt = Int32(max(iterations, Int(uniforms.maxIt)))
        u.pixelStep = 1
        u.deepMode = 1 // force DS for exports
        // Increase iterations proportionally to zoom for deep exports
        u.maxIt = Int32(max(Int(u.maxIt), Int(Double(u.maxIt) * (scalePixelsPerUnit / deepZoomThreshold))))

        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let originXFull = center.x - 0.5 * Double(W) * invScale
        let originYFull = center.y - 0.5 * Double(H) * invScale

        @inline(__always)
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }

        var y0 = 0
        while y0 < H {
            let h = min(tileSize, H - y0)
            var x0 = 0
            while x0 < W {
                let w = min(tileSize, W - x0)

                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
                )
                desc.usage = [.shaderWrite, .shaderRead]
                desc.storageMode = .shared
                guard let tex = device.makeTexture(descriptor: desc),
                      let cmd = queue.makeCommandBuffer() else { return nil }

                // Tile mapping + DS splits
                let tOriginX = originXFull + Double(x0) * invScale
                let tOriginY = originYFull + Double(y0) * invScale
                u.origin = SIMD2<Float>(Float(tOriginX), Float(tOriginY))
                u.step   = SIMD2<Float>(Float(invScale), Float(invScale))
                u.size   = SIMD2<UInt32>(UInt32(w), UInt32(h))

                let (oRx, oRxLo) = split(tOriginX)
                let (oRy, oRyLo) = split(tOriginY)
                let (sX,  sXLo)  = split(invScale)
                let (sY,  sYLo)  = split(invScale)
                u.originHi = SIMD2<Float>(oRx, oRy)
                u.originLo = SIMD2<Float>(oRxLo, oRyLo)
                u.stepHi   = SIMD2<Float>(sX, sY)
                u.stepLo   = SIMD2<Float>(sXLo, sYLo)

                if let enc = cmd.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(pipeline)
                    enc.setTexture(tex, index: 0)
                    enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)
                    enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)

                    let wth = pipeline.threadExecutionWidth
                    let hth = max(1, pipeline.maxTotalThreadsPerThreadgroup / wth)
                    let tg = MTLSize(width: wth, height: hth, depth: 1)

                    let gridW = Int(u.size.x)
                    let gridH = Int(u.size.y)
                    let groups = MTLSize(
                        width:  (gridW + tg.width  - 1) / tg.width,
                        height: (gridH + tg.height - 1) / tg.height,
                        depth:  1
                    )
                    enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                    enc.endEncoding()
                }

                cmd.commit()
                cmd.waitUntilCompleted()

                // Copy tile into full buffer
                full.withUnsafeMutableBytes { p in
                    guard let base = p.baseAddress else { return }
                    tex.getBytes(base.advanced(by: y0 * rowBytes + x0 * bpp),
                                 bytesPerRow: rowBytes,
                                 from: MTLRegionMake2D(0, 0, w, h),
                                 mipmapLevel: 0)
                }

                x0 += w
            }
            y0 += h
        }

        // Build CGImage
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: full as CFData) else { return nil }
        guard let cg = CGImage(
            width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }

        return UIImage(cgImage: cg)
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
        u.deepMode = 1 // force DS for export
        u.size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        u.maxIt = Int32(max(1, max(iterations, Int(uniforms.maxIt))))
        u.pixelStep = 1
        // Increase iterations proportionally to zoom for deep exports
        u.maxIt = Int32(max(Int(u.maxIt), Int(Double(u.maxIt) * (scalePixelsPerUnit / deepZoomThreshold))))

        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let originX = center.x - 0.5 * Double(width) * invScale
        let originY = center.y - 0.5 * Double(height) * invScale
        u.origin = SIMD2<Float>(Float(originX), Float(originY))
        u.step   = SIMD2<Float>(Float(invScale), Float(invScale))

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
            enc.setComputePipelineState(pipeline)
            enc.setTexture(snapTex, index: 0)
            enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)
            enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)

            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)

            let gridW = Int(u.size.x)
            let gridH = Int(u.size.y)
            let groups = MTLSize(
                width:  (gridW + tg.width  - 1) / tg.width,
                height: (gridH + tg.height - 1) / tg.height,
                depth:  1
            )
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

    // MARK: - Helpers
    private func validateBindingsAndFallback() {
        // If LUT palette is selected but not loaded, fall back to HSV.
        if uniforms.palette == 3 && paletteTexture == nil {
            let msg = "LUT unavailable: fell back to HSV"
            print("[Renderer] \(msg)")
            uniforms.palette = 0
            NotificationCenter.default.post(name: .MandelbrotRendererFallback,
                                            object: self,
                                            userInfo: ["reason": msg])
        }
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
    }
    
    // MARK: - Async Tiled Capture (non-blocking, progress + completion)
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

        // Prepare full BGRA buffer
        let bpp = 4
        let rowBytes = W * bpp
        let totalBytes = rowBytes * H
        var full = Data(count: totalBytes)

        // Snapshot uniforms (do not mutate live uniforms)
        var u = self.uniforms
        u.maxIt = Int32(max(1, iterations))
        u.pixelStep = 1
        u.deepMode = 1 // high precision
        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let originXFull = center.x - 0.5 * Double(W) * invScale
        let originYFull = center.y - 0.5 * Double(H) * invScale

        @inline(__always)
        func split(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }

        // Build tile list (center-out order for better perceived progress)
        var tiles: [(x: Int, y: Int, w: Int, h: Int)] = []
        let cols = (W + tileSize - 1) / tileSize
        let rows = (H + tileSize - 1) / tileSize
        let cx = cols / 2
        let cy = rows / 2

        func tileRect(_ i: Int, _ j: Int) -> (x: Int, y: Int, w: Int, h: Int) {
            let x0 = i * tileSize
            let y0 = j * tileSize
            let tw = min(tileSize, W - x0)
            let th = min(tileSize, H - y0)
            return (x: x0, y: y0, w: tw, h: th)
        }

        var ring = 0
        tiles.reserveCapacity(cols * rows)
        while tiles.count < cols * rows {
            let iMin = max(0, cx - ring)
            let iMax = min(cols - 1, cx + ring)
            let jMin = max(0, cy - ring)
            let jMax = min(rows - 1, cy + ring)

            // top row (left -> right)
            if jMin < rows {
                for i in iMin...iMax {
                    let t = tileRect(i, jMin)
                    if t.w > 0 && t.h > 0 { tiles.append(t) }
                }
            }
            // right column (top+1 -> bottom)
            if iMax < cols && jMin + 1 <= jMax {
                for j in (jMin + 1)...jMax {
                    let t = tileRect(iMax, j)
                    if t.w > 0 && t.h > 0 { tiles.append(t) }
                }
            }
            // bottom row (right -> left)
            if jMax < rows && jMax != jMin {
                for i in stride(from: iMax, through: iMin, by: -1) {
                    let t = tileRect(i, jMax)
                    if t.w > 0 && t.h > 0 { tiles.append(t) }
                }
            }
            // left column (bottom-1 -> top+1)
            if iMin < cols && iMax != iMin && jMax - 1 >= jMin + 1 {
                for j in stride(from: jMax - 1, through: jMin + 1, by: -1) {
                    let t = tileRect(iMin, j)
                    if t.w > 0 && t.h > 0 { tiles.append(t) }
                }
            }
            ring += 1
        }
        if tiles.count > cols * rows { tiles.removeLast(tiles.count - cols * rows) }
        guard !tiles.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let totalTiles = tiles.count
        let renderQueue = DispatchQueue(label: "mandel.capture.queue", qos: .userInitiated)

        func finishImage() {
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: full as CFData) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard let cg = CGImage(width: W, height: H,
                                   bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: rowBytes, space: cs,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                       CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                   ),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(UIImage(cgImage: cg)) }
        }

        func renderTile(at index: Int) {
            if index >= totalTiles {
                finishImage()
                return
            }
            let t = tiles[index]
            renderQueue.async {
                autoreleasepool {
                    // Shared texture so we can getBytes() after GPU finishes
                    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                        width: t.w, height: t.h, mipmapped: false)
                    desc.usage = [.shaderWrite, .shaderRead]
                    desc.storageMode = .shared
                    guard let tex = self.device.makeTexture(descriptor: desc),
                          let cmd = self.queue.makeCommandBuffer() else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

                    // Tile uniforms
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
                        enc.setComputePipelineState(self.pipeline)

                        // Fallback: if palette == LUT (3) but no LUT bound, use HSV instead to avoid white output.
                        var uLocal = u
                        if uLocal.palette == 3 && self.paletteTexture == nil {
                            uLocal.palette = 0 // HSV
                        }

                        enc.setBytes(&uLocal, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
                        enc.setTexture(tex, index: 0)
                        // Bind LUT only if actually used; otherwise a dummy is harmless, but not required.
                        enc.setTexture(self.paletteTexture ?? self.ensureDummyPaletteTexture(), index: 1)

                        let wth = self.pipeline.threadExecutionWidth
                        let hth = max(1, self.pipeline.maxTotalThreadsPerThreadgroup / wth)
                        let tg = MTLSize(width: wth, height: hth, depth: 1)
                        let groups = MTLSize(
                            width:  (t.w + tg.width  - 1) / tg.width,
                            height: (t.h + tg.height - 1) / tg.height,
                            depth:  1
                        )
                        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                        enc.endEncoding()
                    }

                    cmd.addCompletedHandler { _ in
                        // Copy tile into big buffer
                        full.withUnsafeMutableBytes { p in
                            guard let base = p.baseAddress else { return }
                            let region = MTLRegionMake2D(0, 0, t.w, t.h)
                            tex.getBytes(base.advanced(by: t.y * rowBytes + t.x * bpp),
                                         bytesPerRow: rowBytes,
                                         from: region, mipmapLevel: 0)
                        }
                        let pct = Double(index + 1) / Double(totalTiles)
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
}
