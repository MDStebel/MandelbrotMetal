//
//  MetalFractalView.swift
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

struct MetalFractalView: UIViewRepresentable {
    @ObservedObject var vm: FractalVM
    
    @MainActor
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.isPaused = false
        view.enableSetNeedsDisplay = false // continuous redraw
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false

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
        let nominalScale = uiView.window?.screen.scale ?? UIScreen.main.scale
        let sizePts = uiView.bounds.size
        // Floor to whole pixels so it doesn’t bounce between adjacent sizes
        let sizePx = CGSize(
            width: floor(max(1, sizePts.width  * nominalScale)),
            height: floor(max(1, sizePts.height * nominalScale))
        )
        uiView.drawableSize = sizePx

        // Use the ACTUAL pixels-per-point used by MTKView (prevents 1px jumps)
        let scaleUsed: CGFloat
        if sizePts.width > 0 {
            scaleUsed = sizePx.width / sizePts.width
        } else {
            scaleUsed = nominalScale
        }

        vm.pushViewport(sizePts, screenScale: scaleUsed)
        vm.requestDraw()
    }
}
