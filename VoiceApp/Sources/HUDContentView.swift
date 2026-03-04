import SwiftUI
import VoiceKit

/// The pill-shaped HUD overlay rendered with SwiftUI.
///
/// Displays different content depending on the current `HUDVisualState`:
/// minimized capsule, ready hint, listening waveform (held or hands-free),
/// processing indicator, or no-target recovery message. All state
/// communication uses animation rather than text labels, except for
/// instructional hints (Ready) and error recovery (No Target).
struct HUDContentView: View {

    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        VStack(spacing: 6) {
            micCalloutView
            pillContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: viewModel.visualState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.micCalloutName)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.visualState {
        case .minimized:
            minimizedView
        case .ready:
            readyView
        case .listeningHeld:
            listeningHeldView
        case .listeningHandsFree:
            listeningHandsFreeView
        case .processing:
            processingView
        case .processingSlow:
            processingSlowView
        case .noTarget:
            noTargetView
        }
    }

    // MARK: - Minimized

    /// Tiny capsule outline — the app is alive and idle.
    private var minimizedView: some View {
        Capsule()
            .strokeBorder(Color.cyan, lineWidth: 2)
            .frame(width: 46, height: 8)
    }

    // MARK: - Ready

    /// Expanded pill with hotkey hint on hover.
    private var readyView: some View {
        HStack(spacing: 4) {
            Text(readyHintPrefix)
                .foregroundColor(.white.opacity(0.8))
            Text(viewModel.shortcuts.holdToRecordKeyName)
                .foregroundColor(.purple.opacity(0.9))
                .fontWeight(.semibold)
            Text(readyHintSuffix)
                .foregroundColor(.white.opacity(0.8))
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pillBackground)
        .overlay(pillBorder)
        .transition(.opacity)
    }

    private var readyHintPrefix: String { "Hold" }
    private var readyHintSuffix: String { "to dictate" }

    // MARK: - Listening (held)

    /// Push-to-talk: waveform dots, no buttons.
    private var listeningHeldView: some View {
        WaveformDotsView()
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(pillBackground)
            .overlay(pillBorder)
            .transition(.opacity)
    }

    // MARK: - Listening (hands-free)

    /// Toggle mode: ✕ cancel, waveform dots, ■ stop.
    private var listeningHandsFreeView: some View {
        HStack(spacing: 16) {
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            WaveformDotsView()
                .frame(maxWidth: .infinity)

            Button(action: { viewModel.onStop?() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(pillBackground)
        .overlay(pillBorder)
        .transition(.opacity)
    }

    // MARK: - Processing (fast path)

    /// STT in flight. Animated indicator, no cancel affordance.
    private var processingView: some View {
        ProcessingDotsView()
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(pillBackground)
            .overlay(pillBorder)
            .transition(.opacity)
    }

    // MARK: - Processing (slow path)

    /// STT taking longer than expected. Reassurance message and ✕ cancel.
    private var processingSlowView: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel processing")

            ProcessingDotsView()
                .frame(width: 40)

            Text("Still working…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pillBackground)
        .overlay(pillBorder)
        .transition(.opacity)
    }

    // MARK: - No Target

    /// Injection failed. Shows paste-shortcut hint and ✕ dismiss.
    private var noTargetView: some View {
        HStack(spacing: 12) {
            Text(viewModel.shortcuts.noTargetHint)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Button(action: { viewModel.onDismiss?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pillBackground)
        .overlay(pillBorder)
        .transition(.opacity)
    }

    // MARK: - Shared pill chrome

    private var pillBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
    }

    private var pillBorder: some View {
        Capsule()
            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
    }

    // MARK: - Mic callout

    /// A small tooltip above the pill showing the active microphone name.
    /// Visible on the first recording after launch and after mic switches.
    @ViewBuilder
    private var micCalloutView: some View {
        if let micName = viewModel.micCalloutName {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                Text(micName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .onTapGesture {
                viewModel.dismissMicCallout()
            }
        }
    }
}

// MARK: - Waveform dots (listening animation)

/// A row of dots that undulate vertically to indicate active listening.
///
/// Uses a canned animation. Live mic level response is a future polish item.
/// When Reduce Motion is enabled, dots pulse opacity instead of moving.
struct WaveformDotsView: View {

    private let dotCount = 7
    private let dotSize: CGFloat = 5

    @State private var isAnimating = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: dotSize, height: dotSize)
                    .modifier(
                        WaveformDotModifier(
                            isAnimating: isAnimating,
                            index: index,
                            reduceMotion: reduceMotion
                        )
                    )
            }
        }
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }
}

/// Apply either vertical offset animation or opacity pulsing to a single
/// waveform dot, depending on the Reduce Motion accessibility setting.
struct WaveformDotModifier: ViewModifier {

    let isAnimating: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(isAnimating ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.08),
                    value: isAnimating
                )
        } else {
            content
                .offset(y: isAnimating ? -amplitude(for: index) : amplitude(for: index))
                .animation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.07),
                    value: isAnimating
                )
        }
    }

    private func amplitude(for index: Int) -> CGFloat {
        // Center dots have larger amplitude for a natural waveform shape.
        let center = 3.0
        let distance = abs(Double(index) - center)
        return CGFloat(6.0 - distance * 1.2)
    }
}

// MARK: - Processing dots (processing animation)

/// An animated indicator visually distinct from the waveform to signal
/// that the app has moved from "listening" to "thinking".
///
/// Dots converge toward center and pulse uniformly. When Reduce Motion is
/// enabled, dots pulse opacity instead.
struct ProcessingDotsView: View {

    private let dotCount = 5
    private let dotSize: CGFloat = 5

    @State private var isAnimating = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        HStack(spacing: isAnimating ? 2 : 6) {
            ForEach(0..<dotCount, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isAnimating ? 0.7 : 1.0)
                    .opacity(reduceMotion ? (isAnimating ? 0.4 : 1.0) : 1.0)
            }
        }
        .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
            value: isAnimating
        )
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }
}
