//
//  IterationOverlay.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/15/25.
//

import SwiftUI

struct IterationOverlay: View {
    @Binding var iterations: Int
    var onChange: (Int) -> Void
    var onDone: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Capsule().fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)

                HStack {
                    Text("Iterations")
                        .font(.footnote.bold())
                    Spacer()
                    Text("\(iterations)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                Slider(value: Binding(
                    get: { Double(iterations) },
                    set: { iterations = Int($0.rounded()); onChange(iterations) }
                ), in: 50...5000, step: 50)

                HStack(spacing: 10) {
                    Button {
                        iterations = max(50, iterations - 50)
                        onChange(iterations)
                    } label: { Label("−50", systemImage: "minus.circle") }
                        .buttonStyle(.bordered)

                    Button {
                        iterations = min(5000, iterations + 50)
                        onChange(iterations)
                    } label: { Label("+50", systemImage: "plus.circle") }
                        .buttonStyle(.bordered)

                    Spacer()

                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .ignoresSafeArea(.keyboard)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(duration: 0.35), value: iterations)
    }
}
