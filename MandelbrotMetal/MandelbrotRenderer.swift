//
//  MandelbrotRenderer.swift
//  Mandelbrot
//
//  Created by Michael Stebel on 8/8/25.
//

import Foundation
import MetalKit
import simd
import UIKit

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
}

final class MandelbrotRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var outTex: MTLTexture?
    private var refOrbitBuffer: MTLBuffer?
    private var paletteTexture: MTLTexture?
    private var dummyOrbitBuffer: MTLBuffer?
    private var dummyPaletteTex: MTLTexture?
    var needsRender = true
    private var uniforms = MandelbrotUniforms(
        origin: .zero,
        step: .init(0.005, 0.005),
        maxIt: 500,
        size: .zero,
        pixelStep: 1,
        palette: 0,
        deepMode: 0,
        originHi: .zero,
        originLo: .zero,
        stepHi: .zero,
        stepLo: .zero,
        perturbation: 0,
        c0: .zero
    )
    func setInteractive(_ on: Bool, baseIterations: Int) {
        uniforms.pixelStep = on ? 2 : 1
        uniforms.maxIt = Int32(on ? max(50, baseIterations/2) : baseIterations)
        needsRender = true
    }
    
    func setPalette(_ mode: Int) {
        uniforms.palette = Int32(mode)
        needsRender = true
    }
    
    
    init?(mtkView: MTKView) {
        print("MandelbrotRenderer.init: starting…")
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MandelbrotRenderer.init: **NO METAL DEVICE** — cannot create renderer")
            return nil
        }
        guard let queue  = device.makeCommandQueue() else {
            print("MandelbrotRenderer.init: **FAILED** to make command queue")
            return nil
        }
        self.device = device
        self.queue  = queue
        
        do {
            let lib = try device.makeDefaultLibrary(bundle: .main)
            guard let fn = lib.makeFunction(name: "mandelbrotKernel") else {
                print("MandelbrotRenderer.init: **KERNEL NOT FOUND** in default library")
                return nil
            }
            self.pipeline = try device.makeComputePipelineState(function: fn)
            print("MandelbrotRenderer.init: pipeline created")
        } catch {
            print("MandelbrotRenderer.init: **FAILED** to build library/pipeline: \(error)")
            return nil
        }
        
        super.init()
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.isOpaque = true
        mtkView.framebufferOnly = false  // allow blit/compute access to drawable texture
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false // continuous redraw
        mtkView.preferredFramesPerSecond = 60
        // Ensure a non-zero drawable size up front
        mtkView.drawableSize = CGSize(width: UIScreen.main.bounds.width * UIScreen.main.scale,
                                      height: UIScreen.main.bounds.height * UIScreen.main.scale)
        mtkView.delegate = self
        print("MandelbrotRenderer.init: complete. framebufferOnly=\(mtkView.framebufferOnly)")
    }
    
    func setViewport(center: SIMD2<Double>, scalePixelsPerUnit: Double,
                     sizePts: CGSize, screenScale: CGFloat, maxIterations: Int) {
        print("Viewport center=\(center) scale=\(scalePixelsPerUnit) px=\(uniforms.size) origin=\(uniforms.origin) step=\(uniforms.step) it=\(uniforms.maxIt)")
        let wD = sizePts.width * screenScale
        let hD = sizePts.height * screenScale
        guard wD.isFinite, hD.isFinite else { return }
        let pixelW = max(1, Int(wD.rounded()))
        let pixelH = max(1, Int(hD.rounded()))
        
        uniforms.size = SIMD2<UInt32>(UInt32(pixelW), UInt32(pixelH))
        uniforms.maxIt = Int32(max(1, maxIterations))
        
        let invScale = 1.0 / max(1e-9, scalePixelsPerUnit)
        let halfW = 0.5 * Double(pixelW)
        let halfH = 0.5 * Double(pixelH)
        let originX = center.x - halfW * invScale
        let originY = center.y - halfH * invScale
        
        uniforms.origin = SIMD2<Float>(Float(originX), Float(originY))
        uniforms.step   = SIMD2<Float>(Float(invScale), Float(invScale))
        
        // Compute double-single split values for origin and step
        func splitDoubleToHiLo(_ d: Double) -> (Float, Float) {
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (hi, lo)
        }
        
        let (oRx, oRxLo) = splitDoubleToHiLo(originX)
        let (oRy, oRyLo) = splitDoubleToHiLo(originY)
        let (sX,  sXLo)  = splitDoubleToHiLo(invScale)
        let (sY,  sYLo)  = splitDoubleToHiLo(invScale)
        uniforms.originHi = SIMD2<Float>(oRx, oRy)
        uniforms.originLo = SIMD2<Float>(oRxLo, oRyLo)
        uniforms.stepHi   = SIMD2<Float>(sX, sY)
        uniforms.stepLo   = SIMD2<Float>(sXLo, sYLo)
        
        allocateTextureIfNeeded(width: pixelW, height: pixelH)
        rebuildReferenceOrbitIfNeeded()
        needsRender = true
    }
    
    func setMaxIterations(_ it: Int) {
        uniforms.maxIt = Int32(max(1, it))
        rebuildReferenceOrbitIfNeeded()
        needsRender = true
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        print("mtkView drawableSizeWillChange ->", size)
        let wF = size.width
        let hF = size.height
        // Guard against NaN/Inf before any Int conversion (avoids runtime trap)
        if !wF.isFinite || !hF.isFinite {
            print("drawableSizeWillChange: non-finite size, skipping")
            return
        }
        let w = max(1, Int((wF).rounded()))
        let h = max(1, Int((hF).rounded()))
        allocateTextureIfNeeded(width: w, height: h)
        needsRender = true
    }
    
    func draw(in view: MTKView) {
        print("MandelbrotRenderer.draw: entered. needsRender=\(needsRender)")
        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer()
        else { print("MandelbrotRenderer.draw: missing drawable or cmd buffer"); return }
        
        // Safety: check drawable texture size before using it
        let dw = drawable.texture.width
        let dh = drawable.texture.height
        if dw <= 0 || dh <= 0 {
            print("draw: drawable has non-positive size (\(dw)x\(dh)), skipping frame")
            cmd.commit()
            return
        }
        
        // Ensure we have an offscreen texture sized to the drawable
        if outTex == nil || outTex?.width != dw || outTex?.height != dh {
            allocateTextureIfNeeded(width: dw, height: dh)
        }
        guard let outTex = self.outTex else {
            print("MandelbrotRenderer.draw: failed to allocate outTex — presenting clear frame")
            drawable.present()
            cmd.commit()
            return
        }
        
        // If uniforms.size is zero (no viewport yet), initialize a default view
        if uniforms.size.x == 0 || uniforms.size.y == 0 {
            uniforms.size = SIMD2<UInt32>(UInt32(dw), UInt32(dh))
            // Default center and scale: show ~3.5 units across
            let scalePixelsPerUnit = Double(dw) / 3.5
            let invScale = 1.0 / max(1e-9, scalePixelsPerUnit)
            let halfW = 0.5 * Double(dw)
            let halfH = 0.5 * Double(dh)
            let center = SIMD2<Double>(-0.5, 0.0)
            let originX = center.x - halfW * invScale
            let originY = center.y - halfH * invScale
            uniforms.origin = SIMD2<Float>(Float(originX), Float(originY))
            uniforms.step   = SIMD2<Float>(Float(invScale), Float(invScale))
        }
        
        print("DRAW tick: outTex=\(outTex.width)x\(outTex.height) drawable=\(drawable.texture.width)x\(drawable.texture.height) uniforms.size=\(uniforms.size) needsRender=\(needsRender)")
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            var u = uniforms
            enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)
            // Always bind resources expected by the kernel to satisfy validation
            if let buf = refOrbitBuffer ?? ensureDummyOrbitBuffer() {
                enc.setBuffer(buf, offset: 0, index: 1)
            }
            enc.setTexture(outTex, index: 0)
            enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)

            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)

            let stepPix = max(1, Int(uniforms.pixelStep))
            let gridW = (Int(uniforms.size.x) + stepPix - 1) / stepPix
            let gridH = (Int(uniforms.size.y) + stepPix - 1) / stepPix
            let groupsW = max(1, (gridW + tg.width  - 1) / tg.width)
            let groupsH = max(1, (gridH + tg.height - 1) / tg.height)
            let tpg = MTLSize(width: groupsW, height: groupsH, depth: 1)
            enc.dispatchThreadgroups(tpg, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        
        // Blit offscreen texture into the drawable
        if let blit = cmd.makeBlitCommandEncoder() {
            let src = MTLOrigin(x: 0, y: 0, z: 0)
            let dst = MTLOrigin(x: 0, y: 0, z: 0)
            let size = MTLSize(width: outTex.width, height: outTex.height, depth: 1)
            blit.copy(from: outTex,
                      sourceSlice: 0,
                      sourceLevel: 0,
                      sourceOrigin: src,
                      sourceSize: size,
                      to: drawable.texture,
                      destinationSlice: 0,
                      destinationLevel: 0,
                      destinationOrigin: dst)
            blit.endEncoding()
        }
        
        drawable.present()
        cmd.commit()
        needsRender = false
    }
    
    // Enable or disable deep zoom (double-single precision coordinate mapping)
    func setDeepZoom(_ on: Bool) {
        uniforms.deepMode = on ? 1 : 0
        needsRender = true
    }
    
    func setPerturbation(_ on: Bool) {
        uniforms.perturbation = on ? 1 : 0
        if on { rebuildReferenceOrbitIfNeeded() }
        needsRender = true
    }
    
    // MARK: - Snapshot (Hi-Res Offscreen Render)
    func makeSnapshot(width: Int, height: Int,
                      center: SIMD2<Double>,
                      scalePixelsPerUnit: Double,
                      iterations: Int) -> UIImage? {
        // Build a one-off output texture (CPU-readable) and render into it using current palette/deep settings
        guard width > 0, height > 0,
              let cmd = queue.makeCommandBuffer() else { return nil }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared // CPU-readable
        guard let snapTex = device.makeTexture(descriptor: desc) else { return nil }
        
        // Prepare uniforms for this resolution (full quality: pixelStep=1)
        var u = uniforms
        u.size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        u.maxIt = Int32(max(1, iterations))
        u.pixelStep = 1
        
        let invScale = 1.0 / max(1e-12, scalePixelsPerUnit)
        let halfW = 0.5 * Double(width)
        let halfH = 0.5 * Double(height)
        let originX = center.x - halfW * invScale
        let originY = center.y - halfH * invScale
        u.origin = SIMD2<Float>(Float(originX), Float(originY))
        u.step   = SIMD2<Float>(Float(invScale), Float(invScale))
        
        // Update deep-zoom hi/lo pairs for snapshot
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
        
        // Encode compute
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(snapTex, index: 0)
            enc.setTexture(paletteTexture ?? ensureDummyPaletteTexture(), index: 1)
            if let buf = refOrbitBuffer ?? ensureDummyOrbitBuffer() {
                enc.setBuffer(buf, offset: 0, index: 1)
            }
            enc.setBytes(&u, length: MemoryLayout<MandelbrotUniforms>.stride, index: 0)

            let w = pipeline.threadExecutionWidth
            let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)

            let stepPix = max(1, Int(u.pixelStep))
            let gridW = (Int(u.size.x) + stepPix - 1) / stepPix
            let gridH = (Int(u.size.y) + stepPix - 1) / stepPix
            let groupsW = max(1, (gridW + tg.width  - 1) / tg.width)
            let groupsH = max(1, (gridH + tg.height - 1) / tg.height)
            let tpg = MTLSize(width: groupsW, height: groupsH, depth: 1)
            enc.dispatchThreadgroups(tpg, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        
        cmd.commit()
        cmd.waitUntilCompleted()
        
        // Read back
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { ptr in
            if let p = ptr.baseAddress {
                let region = MTLRegionMake2D(0, 0, width, height)
                snapTex.getBytes(p, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }
        }
        
        // Make CGImage
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(width: width,
                               height: height,
                               bitsPerComponent: 8,
                               bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow,
                               space: cs,
                               bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                               ),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
    
    // MARK: - Helpers
    private func ensureDummyOrbitBuffer() -> MTLBuffer? {
        if let b = dummyOrbitBuffer { return b }
        var zero = SIMD2<Float>(repeating: 0)
        dummyOrbitBuffer = device.makeBuffer(bytes: &zero,
                                            length: MemoryLayout<SIMD2<Float>>.stride,
                                            options: .storageModeShared)
        return dummyOrbitBuffer
    }

    private func ensureDummyPaletteTexture() -> MTLTexture? {
        if let t = dummyPaletteTex { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var pixel: UInt32 = 0xFFFFFFFF // BGRA = 0xFF_FF_FF_FF (white)
        withUnsafeBytes(of: &pixel) { bytes in
            let region = MTLRegionMake2D(0, 0, 1, 1)
            tex.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        dummyPaletteTex = tex
        return tex
    }

    private func allocateTextureIfNeeded(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if let t = outTex, t.width == width, t.height == height { return }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        outTex = device.makeTexture(descriptor: desc)
    }
    
    private func rebuildReferenceOrbitIfNeeded() {
        // Build a reference orbit at the center pixel c0 using Double for accuracy.
        let w = Int(uniforms.size.x)
        let h = Int(uniforms.size.y)
        guard w > 0 && h > 0 else { return }
        // Center pixel coordinate in complex plane
        let c0x = Double(uniforms.origin.x) + Double(w) * 0.5 * Double(uniforms.step.x)
        let c0y = Double(uniforms.origin.y) + Double(h) * 0.5 * Double(uniforms.step.y)
        uniforms.c0 = SIMD2<Float>(Float(c0x), Float(c0y))
        
        let maxIt = Int(uniforms.maxIt)
        var orbit = [SIMD2<Float>](repeating: .zero, count: maxIt)
        var zr = 0.0, zi = 0.0
        for i in 0..<maxIt {
            // z = z^2 + c0
            let zr2 = zr*zr - zi*zi + c0x
            let zi2 = 2.0*zr*zi + c0y
            zr = zr2; zi = zi2
            orbit[i] = SIMD2<Float>(Float(zr), Float(zi))
        }
        let length = orbit.count * MemoryLayout<SIMD2<Float>>.stride
        refOrbitBuffer = device.makeBuffer(bytes: orbit, length: length, options: .storageModeShared)
    }
    func setPaletteImage(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return }
        
        // Convert to BGRA8 premultipliedFirst in CPU memory
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let byteCount = bytesPerRow * height
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: base,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: cs,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                   ).rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        
        // Create GPU texture and upload
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared // allow CPU replace(region:)
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress {
                let region = MTLRegionMake2D(0, 0, width, height)
                tex.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        self.paletteTexture = tex
    }
}
