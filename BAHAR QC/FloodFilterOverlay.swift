//
//  FloodFilterOverlay.swift
//  BAHAR QC
//
//  Full-screen "underwater POV" effect. Activates when the user lowers the
//  phone below the AR-detected waterline — they're effectively standing in
//  the water and looking around at submerged eye level.
//
//  This is a pure SwiftUI overlay (TimelineView + Canvas). It draws on TOP
//  of the AR camera feed and the 3D water plane, painting a blue-tinted
//  "submerged" view with animated caustics and a light shaft from above.
//

import SwiftUI

struct UnderwaterPOVOverlay: View {
    /// `true` = the AR camera is below the water surface; show the overlay.
    let active: Bool

    var body: some View {
        if !active {
            EmptyView()
        } else {
            GeometryReader { geom in
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Canvas { gc, size in
                        drawUnderwater(gc: &gc, size: size, time: t)
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: active)
        }
    }

    private func drawUnderwater(gc: inout GraphicsContext,
                                size: CGSize, time: TimeInterval) {
        // 1. Deep blue gradient — brighter near the top (toward the surface),
        // darker at the bottom (down into the water).
        let topColor    = Color(red: 0.10, green: 0.32, blue: 0.50).opacity(0.55)
        let bottomColor = Color(red: 0.02, green: 0.10, blue: 0.18).opacity(0.85)
        let gradient = Gradient(colors: [topColor, bottomColor])
        let rect = CGRect(origin: .zero, size: size)
        gc.fill(Path(rect),
                with: .linearGradient(gradient,
                                      startPoint: CGPoint(x: size.width / 2, y: 0),
                                      endPoint:   CGPoint(x: size.width / 2, y: size.height)))

        // 2. Animated caustic bands — wavy horizontal stripes drifting across
        // the upper third, suggesting sunlight refracted through the surface.
        let steps = 80
        gc.opacity = 0.35
        for band in 0..<6 {
            let baseY = size.height * 0.05 + CGFloat(band) * size.height * 0.06
            var path = Path()
            for s in 0...steps {
                let x = CGFloat(s) / CGFloat(steps) * size.width
                let phase = Double(x / size.width) * .pi * 2 * 3 + time * 1.2 + Double(band) * 0.7
                let y = baseY + CGFloat(sin(phase)) * 8
                if s == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            gc.stroke(path,
                      with: .color(Color(red: 0.65, green: 0.85, blue: 0.95)),
                      lineWidth: 1.5)
        }

        // 3. Bright light shaft pulsing from above — adds depth and "looking
        // up at the surface" feel.
        gc.opacity = 0.18 + 0.06 * sin(time * 0.8)
        let shaftWidth = size.width * 0.55
        let shaftRect = CGRect(x: (size.width - shaftWidth) / 2, y: 0,
                               width: shaftWidth, height: size.height * 0.5)
        let shaftGrad = Gradient(colors: [
            Color.white.opacity(0.45),
            Color.white.opacity(0)
        ])
        gc.fill(Path(ellipseIn: shaftRect),
                with: .linearGradient(shaftGrad,
                                      startPoint: CGPoint(x: shaftRect.midX, y: shaftRect.minY),
                                      endPoint:   CGPoint(x: shaftRect.midX, y: shaftRect.maxY)))

        // 4. Drifting bubble specks rising from below — animated vertical
        // motion gives the underwater scene life.
        gc.opacity = 0.55
        for i in 0..<14 {
            let seed = Double(i) * 1.37
            let xJitter = CGFloat(sin(time * 0.5 + seed * 1.9))
            let baseX = (CGFloat(i) / 14.0) * size.width + xJitter * 12
            let rise = CGFloat(fmod(time * (0.06 + seed.truncatingRemainder(dividingBy: 0.06)), 1.0))
            let y = size.height - rise * size.height
            let r = 2 + CGFloat(seed.truncatingRemainder(dividingBy: 4))
            let bubble = Path(ellipseIn: CGRect(x: baseX - r, y: y - r,
                                                width: r * 2, height: r * 2))
            gc.stroke(bubble,
                      with: .color(Color.white.opacity(0.7)),
                      lineWidth: 0.6)
        }
    }
}
