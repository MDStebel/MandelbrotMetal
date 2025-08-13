//
//  HelpView.swift
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

struct HelpView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                sectionHeader("Getting Started")
                Text("Pinch to zoom, drag to pan. Double-tap to zoom in at the tap point. Deep Zoom engages automatically at extreme magnifications to reduce precision artifacts.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                sectionHeader("Navigation & Gestures")
                bullet("Magnify — pinch to zoom in/out", "magnifyingglass")
                bullet("Pan", "hand.draw")
                bullet("Zoom at point (×2)", "touchid")

                sectionHeader("Rendering Modes")
                Text("**Deep Zoom** switches the kernel into higher‑precision math (double‑single) for extreme magnifications to mitigate precision artifacts.")
                    .foregroundStyle(.primary)

                sectionHeader("Quality")
                Text("**High‑Quality while idle** renders a sharper preview whenever you’re not touching the screen. It increases precision and may temporarily raise iterations in the background to refine details. This looks better at deep zooms but can use a bit more battery.")
                    .foregroundStyle(.primary)

                sectionHeader("Color & Palettes")
                Text("Choose **HSV**, **Fire**, or **Ocean** palettes. Import a custom gradient (LUT) via **Import Gradient**.")
                    .foregroundStyle(.primary)

                sectionHeader("Iterations")
                Text("Use the **Iterations** stepper to adjust detail. Turn on **Auto Iter** to increase iterations automatically with zoom (about **+400 per 10×** beyond your starting zoom).")
                    .foregroundStyle(.primary)

                sectionHeader("Snapshots & Export")
                Text("Use **Resolution → Save** for 4K/6K/8K. Larger sizes use tiled export to avoid memory spikes. Files are named \"MandelMetal_yyyy‑mm‑dd_HH‑mm.png\" and can be shared from the sheet.")
                    .foregroundStyle(.primary)

                sectionHeader("Bookmarks")
                Text("Save the current view (center, zoom, palette, modes) and recall it from **Bookmarks**.")
                    .foregroundStyle(.primary)

                sectionHeader("Performance Tips")
                bullet("Start simple", "speedometer", suffix: "Explore with moderate iterations; export high‑res later.")
                bullet("Prefer 6K over 8K on older devices", "rectangle.on.rectangle")

                sectionHeader("Troubleshooting")
                bullet("Black screen", "exclamationmark.triangle", suffix: "Ensure iterations aren’t extremely high; try Reset.")
                bullet("Stale color after import", "paintpalette", suffix: "After importing a gradient, ensure the LUT option is active if available.")
                bullet("Blur at extreme zoom", "scope", suffix: "Enable Deep Zoom.")

                Divider().padding(.vertical, 4)
                Text(appMeta())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(compact ? 16 : 20)
        }
    }

    // MARK: UI helpers
    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().frame(width: 3)
            Text(title).font(compact ? .headline : .title3).bold()
        }
        .foregroundStyle(.secondary)
        .padding(.top, compact ? 6 : 8)
    }

    @ViewBuilder private func bullet(_ title: String, _ symbol: String, suffix: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            if let suffix { Text("**\(title)** — \(suffix)") } else { Text("**\(title)**") }
        }
        .font(compact ? .caption : .body)
    }

    private func appMeta() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))"
    }
}
