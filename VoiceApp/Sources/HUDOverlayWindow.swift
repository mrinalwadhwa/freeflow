import AppKit
import SwiftUI
import VoiceKit

/// A floating borderless panel that displays the always-visible HUD overlay.
///
/// The HUD is a pill-shaped overlay anchored at the bottom center of the
/// active screen. It resizes smoothly between a minimized capsule and an
/// expanded pill depending on the current `HUDVisualState`. Mouse tracking
/// is enabled so the HUD can detect hover for the Ready state and accept
/// clicks for hands-free activation.
final class HUDOverlayWindow: NSPanel {

    private let viewModel: HUDViewModel
    private var trackingArea: NSTrackingArea?
    private var hostingView: NSHostingView<HUDContentView>?

    /// Width of the minimized capsule.
    private static let minimizedWidth: CGFloat = 80
    private static let minimizedHeight: CGFloat = 28

    /// Width of the expanded pill (listening, processing, ready, no-target).
    private static let expandedWidth: CGFloat = 280
    private static let expandedHeight: CGFloat = 48

    /// Extra height added when the mic callout tooltip is visible above the pill.
    private static let micCalloutExtraHeight: CGFloat = 30

    init(viewModel: HUDViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.minimizedWidth,
                height: Self.minimizedHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: HUDContentView(viewModel: viewModel))
        hosting.frame = contentRect(forFrameRect: frame)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        hostingView = hosting

        setupMouseTracking()
        positionAtBottomCenter()
        orderFrontRegardless()
    }

    // MARK: - Positioning

    /// Position the HUD at the bottom center of the screen containing the
    /// frontmost application window.
    func positionAtBottomCenter() {
        let screen = activeScreen()
        let screenFrame = screen.visibleFrame
        let size = currentSize()
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.origin.y + 40
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Animate the pill to the correct size for the current visual state,
    /// keeping it centered at the bottom of the screen.
    func animateToCurrentState() {
        let size = currentSize()
        let screen = activeScreen()
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.origin.y + 40
        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        ignoresMouseEvents = !viewModel.visualState.acceptsMouseEvents

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = reduceMotion ? 0.1 : 0.25

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .default)
            context.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }

        updateMouseTracking()
    }

    // MARK: - Mouse tracking

    private func setupMouseTracking() {
        guard let contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    private func updateMouseTracking() {
        guard let contentView, let old = trackingArea else { return }
        contentView.removeTrackingArea(old)
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        viewModel.mouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        viewModel.mouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        // Click on the minimized capsule starts hands-free dictation.
        // Action closures live on the view model, set by the HUD controller.
        if viewModel.visualState == .minimized || viewModel.visualState == .ready {
            viewModel.onClickToRecord?()
        }
    }

    // MARK: - Helpers

    private func currentSize() -> NSSize {
        let calloutExtra: CGFloat =
            viewModel.micCalloutName != nil
            ? Self.micCalloutExtraHeight : 0

        if viewModel.visualState.isExpanded {
            return NSSize(
                width: Self.expandedWidth,
                height: Self.expandedHeight + calloutExtra
            )
        }
        return NSSize(width: Self.minimizedWidth, height: Self.minimizedHeight)
    }

    private func activeScreen() -> NSScreen {
        // Find the screen containing the frontmost application's main window.
        // CGWindowListCopyWindowInfo gives us the bounds of the frontmost app's
        // windows so we can match them to an NSScreen.
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let pid = frontApp.processIdentifier
            let windowList =
                CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                ) as? [[CFString: Any]] ?? []

            for entry in windowList {
                guard
                    let ownerPID = entry[kCGWindowOwnerPID] as? Int32,
                    ownerPID == pid,
                    let boundsDict = entry[kCGWindowBounds] as? [String: CGFloat],
                    let x = boundsDict["X"],
                    let y = boundsDict["Y"],
                    let w = boundsDict["Width"],
                    let h = boundsDict["Height"],
                    w > 0, h > 0
                else { continue }

                let windowCenter = CGPoint(x: x + w / 2, y: y + h / 2)

                for screen in NSScreen.screens {
                    if screen.frame.contains(windowCenter) {
                        return screen
                    }
                }
            }
        }

        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
