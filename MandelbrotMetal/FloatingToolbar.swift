//
//  FloatingToolbar.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/15/25.
//

import SwiftUI

struct FloatingToolbar: View {
    // Hook these to your VM / renderer
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var reset: () -> Void

    @Binding var iterations: Int
    var stepIterations: (Int) -> Void // +/– 50 or whatever you use
    @Binding var smoothShading: Bool   // your “smooth color/banding” toggle
    @Binding var highQualityIdle: Bool // “HQ Idle”
    @Binding var paletteName: String
    var pickPalette: () -> Void        // opens your palette picker
    var capture: () -> Void            // opens capture sheet

    // Read‑only HUD bits
    let ssaaText: String?              // e.g., "SSAA×2" or nil to hide

    // Layout
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        GeometryReader { geo in
            let compact = isCompact(geo: geo)
            let stack = compact ? AnyLayout(VStackLayout(spacing: 10)) :
                                  AnyLayout(HStackLayout(alignment: .center, spacing: 12))

            stack {
                groupExplore(compact)
                divider(compact)
                groupQuality(compact)
                divider(compact)
                groupColor(compact)
                divider(compact)
                groupOutput(compact)
            }
            .padding(compact ? 12 : 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .shadow(radius: 8, y: 4)
            .frame(maxWidth: compact ? min(geo.size.width - 20, 420) : min(geo.size.width - 40, 840))
            .padding(.horizontal, compact ? 10 : 20)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: – Groups

    @ViewBuilder
    private func groupExplore(_ compact: Bool) -> some View {
        let lay = compact ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        lay {
            ToolbarButton(icon: "plus.magnifyingglass", label: "Zoom In", compact: compact, action: zoomIn)
            ToolbarButton(icon: "minus.magnifyingglass", label: "Zoom Out", compact: compact, action: zoomOut)
            ToolbarButton(icon: "arrow.counterclockwise", label: "Reset", compact: compact, action: reset)
        }
    }

    @ViewBuilder
    private func groupQuality(_ compact: Bool) -> some View {
        let lay = compact ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        lay {
            IterationMiniControl(iterations: $iterations, step: stepIterations, compact: compact)

            Toggle(isOn: $smoothShading) {
                if compact {
                    Label("Smooth", systemImage: "wand.and.stars")
                        .labelStyle(.iconOnly)
                } else {
                    Label("Smooth", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
            }
            .toggleStyle(.switch)
            .lineLimit(1)

            Toggle(isOn: $highQualityIdle) {
                if compact {
                    Label("HQ Idle", systemImage: "bolt.badge.clock")
                        .labelStyle(.iconOnly)
                } else {
                    Label("HQ Idle", systemImage: "bolt.badge.clock")
                        .labelStyle(.titleAndIcon)
                }
            }
            .toggleStyle(.switch)
            .lineLimit(1)

            if let ssaa = ssaaText {
                Text(ssaa)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                    .accessibilityLabel("Sub‑pixel AA \(ssaa)")
            }
        }
    }

    @ViewBuilder
    private func groupColor(_ compact: Bool) -> some View {
        let lay = compact ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        lay {
            Button(action: pickPalette) {
                if compact {
                    Label {
                        HStack(spacing: 6) {
                            Text("PALETTE")
                            Text(paletteName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    } icon: { Image(systemName: "swatchpalette") }
                    .labelStyle(.iconOnly)
                } else {
                    Label {
                        HStack(spacing: 6) {
                            Text("Palette")
                            Text(paletteName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    } icon: { Image(systemName: "swatchpalette") }
                    .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func groupOutput(_ compact: Bool) -> some View {
        ToolbarButton(
            icon: "camera",
            label: "Capture",
            compact: compact,
            role: .none,
            prominent: true,
            action: capture
        )
    }

    @ViewBuilder
    private func divider(_ compact: Bool) -> some View {
        if compact {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        } else {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }

    private func isCompact(geo: GeometryProxy) -> Bool {
        // Heuristic: if narrow OR iPhone portrait OR small iPad portrait, use vertical stack.
        let narrow = geo.size.width < 640
        return narrow || hSize == .compact
    }
}

// MARK: – Small components

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let compact: Bool
    var role: ButtonRole? = nil
    var prominent: Bool = false
    var action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            Button(role: role, action: action) {
                if compact {
                    Label(label, systemImage: icon)
                        .labelStyle(.iconOnly)
                } else {
                    Label(label, systemImage: icon)
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
            Button(role: role, action: action) {
                if compact {
                    Label(label, systemImage: icon)
                        .labelStyle(.iconOnly)
                } else {
                    Label(label, systemImage: icon)
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

private struct IterationMiniControl: View {
    @Binding var iterations: Int
    var step: (Int) -> Void
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Text("Iterations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { step(-50) } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.bordered)

            Text("\(iterations)")
                .font(.caption.monospaced())
                .frame(minWidth: 48)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))

            Button { step(+50) } label: {
                Image(systemName: "plus.circle")
            }.buttonStyle(.bordered)
        }
    }
}
