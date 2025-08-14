//
//  ColorExtension.swift
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

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        switch s.count {
        case 3: // RGB 12-bit, like F0A
            let r = CGFloat((rgb & 0xF00) >> 8) / 15.0
            let g = CGFloat((rgb & 0x0F0) >> 4) / 15.0
            let b = CGFloat(rgb & 0x00F) / 15.0
            self.init(red: r, green: g, blue: b, alpha: 1)
        case 6: // RRGGBB 24-bit
            let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(rgb & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: 1)
        case 8: // AARRGGBB 32-bit
            let a = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            let r = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            let g = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            let b = CGFloat(rgb & 0x000000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: a)
        default:
            self.init(white: 1, alpha: 1) // fallback
        }
    }
}

