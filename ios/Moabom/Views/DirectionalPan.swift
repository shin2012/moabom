import SwiftUI
import UIKit

/// UIKit pan that only starts when the finger moves mainly along `axis`.
/// Unlike a SwiftUI DragGesture, it doesn't swallow touches meant for an enclosing ScrollView
/// (on iOS 18 a SwiftUI DragGesture inside a ScrollView blocks scrolling, even as a simultaneous gesture).
struct DirectionalPan: UIGestureRecognizerRepresentable {
    enum Direction { case horizontal, vertical }
    let direction: Direction
    var onBegan: () -> Void = {}
    let onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void = { _ in }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: Direction = .horizontal

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            let v = p.velocity(in: p.view)
            switch direction {
            case .horizontal: return abs(v.x) > abs(v.y) * 1.2
            case .vertical: return abs(v.y) > abs(v.x) * 1.2
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        let c = Coordinator()
        c.direction = direction
        return c
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let t = g.translation(in: g.view)
        let size = CGSize(width: t.x, height: t.y)
        switch g.state {
        case .began: onBegan(); onChanged(size)
        case .changed: onChanged(size)
        case .ended, .cancelled, .failed: onEnded(size)
        default: break
        }
    }
}
