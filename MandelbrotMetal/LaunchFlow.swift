//
//  LaunchFlow.swift
//  MandelbrotMetal
//
//  Created by Michael Stebel on 8/9/25.
//

import SwiftUI

/// Launch Flow Container
struct LaunchFlow<Main: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    // Swap in your real root view here
    let main: () -> Main

    @State private var showAnimatedLaunch = true

    var body: some View {
        ZStack {
            if showAnimatedLaunch {
                AnimatedLaunchView(
                    backgroundName: backgroundAssetName(scheme: scheme, hSize: hSize, vSize: vSize),
                    logoName: logoAssetName(hSize: hSize, vSize: vSize)
                )
                .transition(.opacity)
                .task {
                    // Keep the animated launch visible briefly, then transition
                    try? await Task.sleep(nanoseconds: 1_100_000_000) // ~1.1s
                    withAnimation(.easeOut(duration: 0.35)) {
                        showAnimatedLaunch = false
                    }
                }
            } else {
                main()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Asset selectors
    private func isLandscape(_ h: UserInterfaceSizeClass?, _ v: UserInterfaceSizeClass?) -> Bool {
        // Heuristic: iPad often regular/regular; detect by aspect ratio at runtime instead.
        // This is a conservative orientation check that works well at launch time:
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return false }
        return window.bounds.width > window.bounds.height
    }

    private func backgroundAssetName(scheme: ColorScheme,
                                     hSize: UserInterfaceSizeClass?,
                                     vSize: UserInterfaceSizeClass?) -> String {
        if isLandscape(hSize, vSize) {
            switch scheme {
            case .dark:   return "LaunchBackground_Landscape_UltraDark"
            case .light:  return "LaunchBackground_Landscape_Light"
            @unknown default: return "LaunchBackground_Landscape"
            }
        } else {
            switch scheme {
            case .dark:   return "LaunchBackground_UltraDark"
            case .light:  return "LaunchBackground_Light"
            @unknown default: return "LaunchBackground"
            }
        }
    }

    private func logoAssetName(hSize: UserInterfaceSizeClass?,
                               vSize: UserInterfaceSizeClass?) -> String {
        isLandscape(hSize, vSize) ? "LaunchLogo_Landscape" : "LaunchLogo"
    }
}

// MARK: - Animated Launch View
struct AnimatedLaunchView: View {
    let backgroundName: String
    let logoName: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    @State private var glow = 0.0
    @State private var scale: CGFloat = 1.0
    @State private var logoOpacity: Double = 0.0

    @State private var bgOpacity: Double = 1.0
    private var isPad: Bool { hSize == .regular && vSize == .regular }

    private var tuning: (maxWidth: CGFloat, baseScale: CGFloat, pulse: CGFloat, glowRadius: CGFloat) {
        // Compact-width iPhones get a smaller logo and slightly stronger pulse
        if hSize == .compact && vSize == .regular {
            return (maxWidth: 420, baseScale: 1.0, pulse: 0.024, glowRadius: 28)
        }
        // Landscape phones / small iPads
        if hSize == .compact && vSize == .compact {
            return (maxWidth: 520, baseScale: 0.95, pulse: 0.018, glowRadius: 22)
        }
        // Regular iPads / large devices
        return (maxWidth: 620, baseScale: 0.98, pulse: 0.012, glowRadius: 18)
    }

    var body: some View {
        ZStack {
            Image(backgroundName)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(bgOpacity)

            Image(logoName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: tuning.maxWidth)
                .shadow(
                    color: .cyan.opacity((scheme == .dark ? 0.28 : 0.18) + 0.35 * glow),
                    radius: tuning.glowRadius + (isPad ? 6 : 10) * glow, x: 0, y: 0
                )
                .scaleEffect(tuning.baseScale + CGFloat(glow) * tuning.pulse)
                .opacity(logoOpacity)
                .padding()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { logoOpacity = 1.0 }
            if reduceMotion {
                glow = 0.0
            } else {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    glow = 1.0
                }
            }
            withAnimation(.easeInOut(duration: 0.35).delay(0.65)) { bgOpacity = 0.0 }
        }
    }
}

//// MARK: - App Entry Example (replace ContentView with your root)
//@main
//struct MandelbrotMetalApp: App {
//    var body: some Scene {
//        WindowGroup {
//            LaunchFlow {
//                ContentView() // <- your main UI
//            }
//        }
//    }
//}
//
//// MARK: - Demo ContentView placeholder
//struct ContentView: View {
//    var body: some View {
//        Text("Main UI goes here")
//            .font(.title.bold())
//            .padding()
//    }
//}
