//
//  AccessibleSwitchToggleStyle.swift
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

/// High-Contrast Toggle Style
struct AccessibleSwitchToggleStyle: ToggleStyle {
    var onColor: Color = .accentColor
    var offColor: Color = Color(UIColor.systemGray3).opacity(0.95)
    var knobColor: Color = .white
    var borderColor: Color = .black.opacity(0.25)
    var height: CGFloat = 28
    
    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let width = height * 1.75
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                configuration.isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(isOn ? onColor : offColor)
                RoundedRectangle(cornerRadius: height / 2)
                    .stroke(borderColor, lineWidth: 1)
                Circle()
                    .fill(knobColor)
                    .frame(width: height - 4, height: height - 4)
                    .shadow(radius: 0.6, y: 0.6)
                    .padding(2)
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
