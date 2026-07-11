import AppKit
import SwiftUI

/// SwiftUI can hide scroll indicators, but it cannot force macOS's transient
/// overlay style when the user's global preference is "Always." This tiny,
/// view-only bridge keeps every scroll view in its containing window native
/// while making the indicator float over content and disappear when idle.
struct TransientScrollIndicatorConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TransientScrollIndicatorProbe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TransientScrollIndicatorProbe)?.scheduleConfiguration()
    }
}

private final class TransientScrollIndicatorProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        configureAfterLayout(delay: 0)
        // NavigationSplitView and the selected detail create their native
        // NSScrollViews on later layout turns. A second idempotent pass catches
        // those lazy descendants without observing or changing scroll state.
        configureAfterLayout(delay: 0.25)
    }

    private func configureAfterLayout(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let root = self?.window?.contentView else { return }
            Self.configureScrollViews(in: root)
        }
    }

    private static func configureScrollViews(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        for subview in view.subviews {
            configureScrollViews(in: subview)
        }
    }
}

extension View {
    /// Requests transient overlay indicators for every native scroll view in
    /// this view's window. No content, selection, or scroll state crosses the
    /// AppKit boundary.
    func transientScrollIndicators() -> some View {
        background {
            TransientScrollIndicatorConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}
