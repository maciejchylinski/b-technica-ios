import SwiftUI
import UIKit

/// Holds the Gantt scroll offset. Only the canvas observes it, so scrolling
/// redraws the visible viewport without re-evaluating the surrounding screen.
@MainActor
final class GanttScrollController: ObservableObject {
    @Published fileprivate(set) var offset: CGPoint = .zero

    fileprivate weak var scrollView: GanttUIScrollView?

    var viewportSize: CGSize { scrollView?.bounds.size ?? .zero }

    /// Scrolls so `x` (content coordinates) is the left edge, clamped to the content.
    /// Applied after layout if the scroll view is not sized yet.
    func scroll(toX x: CGFloat, animated: Bool) {
        guard let scrollView, scrollView.bounds.width > 0 else {
            pendingX = x
            return
        }
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let target = CGPoint(x: min(max(0, x), maxX), y: scrollView.contentOffset.y)
        scrollView.setContentOffset(target, animated: animated)
    }

    func scroll(byX delta: CGFloat) {
        guard let scrollView else { return }
        scroll(toX: scrollView.contentOffset.x + delta, animated: true)
    }

    fileprivate var pendingX: CGFloat?

    fileprivate func publish(_ point: CGPoint) {
        if offset != point { offset = point }
    }
}

final class GanttUIScrollView: UIScrollView {
    fileprivate weak var controller: GanttScrollController?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, let controller, let x = controller.pendingX {
            controller.pendingX = nil
            controller.scroll(toX: x, animated: false)
        }
    }
}

/// Transparent native scroll view laid over the Gantt canvas. Provides inertia,
/// bounce and direction locking; taps are reported in viewport coordinates.
struct GanttScrollView: UIViewRepresentable {
    let contentSize: CGSize
    let controller: GanttScrollController
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> GanttUIScrollView {
        let view = GanttUIScrollView()
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.isDirectionalLockEnabled = true
        view.alwaysBounceHorizontal = true
        view.delegate = context.coordinator
        view.contentSize = contentSize
        view.controller = controller
        controller.scrollView = view

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return view
    }

    func updateUIView(_ view: GanttUIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        if view.contentSize != contentSize {
            context.coordinator.isUpdating = true
            view.contentSize = contentSize
            context.coordinator.isUpdating = false
            let offset = view.contentOffset
            DispatchQueue.main.async { controller.publish(offset) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let controller: GanttScrollController
        var onTap: ((CGPoint) -> Void)?
        var isUpdating = false

        init(controller: GanttScrollController) {
            self.controller = controller
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset
            if isUpdating {
                // Avoid publishing during a SwiftUI view update.
                DispatchQueue.main.async { [controller] in controller.publish(offset) }
            } else {
                controller.publish(offset)
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            let location = recognizer.location(in: scrollView)
            onTap?(CGPoint(
                x: location.x - scrollView.contentOffset.x,
                y: location.y - scrollView.contentOffset.y
            ))
        }
    }
}
