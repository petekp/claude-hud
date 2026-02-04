import AppKit
import SwiftUI

struct ScrollViewScrollerInsetsConfigurator: NSViewRepresentable {
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(from: view, topInset: topInset, bottomInset: bottomInset)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView, topInset: topInset, bottomInset: bottomInset)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        private weak var scrollView: NSScrollView?

        func attach(from view: NSView, topInset: CGFloat, bottomInset: CGFloat) {
            let found = findScrollView(from: view)
            guard let found else { return }

            if scrollView !== found {
                scrollView = found
            }

            found.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        }

        private func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let superview = current?.superview {
                current = superview
            }

            guard let root = current else { return nil }
            return findScrollView(in: root)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            for subview in view.subviews {
                if let found = findScrollView(in: subview) {
                    return found
                }
            }

            return nil
        }
    }
}
