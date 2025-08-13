//
//  BundleIdentifiers.swift
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

func appCopyright() -> String {
    if let s = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, !s.isEmpty {
        return s
    }
    let year = Calendar.current.component(.year, from: Date())
    return "© \(year) Michael Stebel Consulting, LLC. All rights reserved."
}

func appVersionBuild() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return "Version \(version) (\(build))"
}
