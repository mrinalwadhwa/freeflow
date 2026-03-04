import AppKit
import SwiftUI
import VoiceKit

/// A floating borderless window that displays recording state as a pill-shaped HUD.
///
/// The HUD appears near the bottom-center of the screen and shows:
/// - A pulsing red dot during recording
/// - A spinning indicator during processing
/// - A brief checkmark during injection before dismissing
///
/// Driven by `RecordingCoordinator.stateStream`.
final class HUDOverlayWindow: NSPanel {

    private let hudViewModel: HUDViewModel

    init(viewModel: HUDViewModel) {
        self.hudViewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: HUDOverlayView(viewModel: viewModel))
        hostingView.frame = contentRect(forFrameRect: frame)
        contentView = hostingView

        positionAtBottomCenter()
    }

    /// Position the HUD near the bottom center of the main screen.
    func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.origin.y + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Show the HUD with a fade-in animation.
    func showAnimated() {
        alphaValue = 0
        orderFrontRegardless()
        positionAtBottomCenter()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hide the HUD with a fade-out animation.
    func hideAnimated(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                self?.orderOut(nil)
                completion?()
            })
    }
}

// MARK: - View model

/// Publish recording state changes on the main actor for SwiftUI observation.
@MainActor
final class HUDViewModel: ObservableObject {

    @Published var recordingState: RecordingState = .idle
    @Published var isVisible: Bool = false

    private var observationTask: Task<Void, Never>?

    /// Begin observing a `RecordingCoordinator`'s state stream.
    func observe(coordinator: RecordingCoordinator) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.recordingState = state
                self?.isVisible = state != .idle
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    deinit {
        observationTask?.cancel()
    }
}

// MARK: - SwiftUI HUD view

/// The pill-shaped HUD overlay rendered with SwiftUI.
struct HUDOverlayView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            if viewModel.isVisible {
                HStack(spacing: 8) {
                    stateIndicator
                    stateLabel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.recordingState)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isVisible)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.recordingState {
        case .recording:
            PulsingDot(color: .red)
        case .processing:
            SpinnerView()
        case .injecting:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14, weight: .semibold))
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch viewModel.recordingState {
        case .recording:
            Text("Recording")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        case .processing:
            Text("Processing")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        case .injecting:
            Text("Done")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Pulsing dot

/// An animated red dot that pulses while recording.
struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Spinner

/// A small spinning activity indicator for the processing state.
struct SpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Image(systemName: "arrow.trianglehead.2.clockwise")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: 1.0).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
    }
}
