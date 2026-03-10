import SwiftUI
import VoiceKit

/// The pill-shaped HUD overlay rendered with SwiftUI.
///
/// Uses a single morphing pill anchored at the bottom of a ZStack. The pill
/// continuously animates its width, height, fill, and border between states.
/// Content layers cross-fade on top with opacity transitions. The tooltip
/// and mic callout float above the pill via offset, avoiding VStack layout
/// shifts that cause downward expansion.
///
/// The parent `HUDOverlayWindow` uses a fixed frame that never resizes or
/// moves during state transitions. All visual size changes are handled here
/// with SwiftUI animations, eliminating the AppKit/SwiftUI animation
/// conflict that caused content to "fly" during transitions.
struct HUDContentView: View {

    @ObservedObject var viewModel: HUDViewModel

    // MARK: - Dimensions per state

    private var pillWidth: CGFloat {
        switch viewModel.visualState {
        case .minimized:
            return 46
        case .ready:
            return 80
        case .listeningHeld:
            return 80
        case .listeningHandsFree:
            return 140
        case .processingCollapsing:
            return 46
        case .processingSlow:
            return 180
        case .noTarget:
            return 260
        case .sessionExpired:
            return 200
        }
    }

    private var pillHeight: CGFloat {
        switch viewModel.visualState {
        case .minimized:
            return 8
        case .ready:
            return 10
        case .processingCollapsing:
            return 8
        case .listeningHeld, .listeningHandsFree,
            .processingSlow, .noTarget, .sessionExpired:
            return 32
        }
    }

    private var pillFillOpacity: Double {
        switch viewModel.visualState {
        case .minimized, .processingCollapsing:
            return 0.3
        case .ready, .listeningHeld, .listeningHandsFree,
            .processingSlow, .noTarget, .sessionExpired:
            return 0.5
        }
    }

    private var pillBorderOpacity: Double {
        switch viewModel.visualState {
        case .minimized, .processingCollapsing:
            return 0.45
        case .ready, .listeningHeld, .listeningHandsFree,
            .processingSlow, .noTarget, .sessionExpired:
            return 0.7
        }
    }

    private var pillBorderWidth: CGFloat {
        return 2
    }

    /// Whether the pill is in a full active state (not minimized/ready).
    private var isActive: Bool {
        switch viewModel.visualState {
        case .minimized, .ready, .processingCollapsing:
            return false
        case .listeningHeld, .listeningHandsFree,
            .processingSlow, .noTarget, .sessionExpired:
            return true
        }
    }

    // MARK: - Body

    /// The pill is the sole layout participant, bottom-anchored in the
    /// window frame. The tooltip and mic callout are overlays that float
    /// above the pill without affecting its position. The overlay uses
    /// `.alignmentGuide(.bottom)` to place its bottom edge at the pill's
    /// top edge, then a negative Y offset adds the gap.
    var body: some View {
        morphingPill
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    micCalloutView

                    if viewModel.visualState == .ready {
                        readyHintTooltip
                            .transition(.opacity)
                    }
                }
                .fixedSize()
                // The overlay's bottom is aligned with the outer frame's
                // bottom. Shift it up by the pill height + 12px gap so
                // the tooltip sits above the pill.
                .offset(y: -(pillHeight + 12))
            }
            .animation(
                viewModel.visualState == .minimized
                    || viewModel.visualState == .processingCollapsing
                    ? .easeOut(duration: 0.15)
                    : .spring(response: 0.18, dampingFraction: 0.82, blendDuration: 0),
                value: viewModel.visualState
            )
            .animation(.easeInOut(duration: 0.25), value: viewModel.micCalloutName)
    }

    // MARK: - Morphing pill

    /// A single pill that morphs its size, fill, and border between all
    /// states. Anchored at the bottom of the ZStack so it always grows
    /// upward.
    private var morphingPill: some View {
        ZStack {
            // Background: solid black fill for all states.
            Capsule()
                .fill(Color.black.opacity(pillFillOpacity))

            // Border.
            Capsule()
                .strokeBorder(
                    Color.white.opacity(pillBorderOpacity),
                    lineWidth: pillBorderWidth
                )

            // Active state content cross-fades inside the pill.
            if isActive {
                activeContent
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(Capsule())
    }

    // MARK: - Active content (inside the pill)

    @ViewBuilder
    private var activeContent: some View {
        switch viewModel.visualState {
        case .minimized, .ready, .processingCollapsing:
            EmptyView()
        case .listeningHeld:
            listeningHeldContent
                .transition(.opacity)
        case .listeningHandsFree:
            listeningHandsFreeContent
                .transition(.opacity)
        case .processingSlow:
            processingSlowContent
                .transition(.opacity)
        case .noTarget:
            noTargetContent
                .transition(.opacity)
        case .sessionExpired:
            sessionExpiredContent
                .transition(.opacity)
        }
    }

    // MARK: - Ready hint tooltip

    /// A floating label above the capsule showing the hotkey hint.
    private var readyHintTooltip: some View {
        HStack(spacing: 4) {
            Text("Click or hold")
                .foregroundColor(.white.opacity(0.8))
            Text(viewModel.shortcuts.holdToRecordKeyName)
                .foregroundColor(.orange.opacity(0.85))
                .fontWeight(.semibold)
            Text("to start dictating")
                .foregroundColor(.white.opacity(0.8))
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
        )
    }

    // MARK: - Listening (held)

    /// Push-to-talk: waveform bars, no buttons.
    private var listeningHeldContent: some View {
        WaveformBarsView(audioLevel: viewModel.audioLevel)
            .padding(.horizontal, 16)
    }

    // MARK: - Listening (hands-free)

    /// Toggle mode: cancel, waveform bars, stop.
    private var listeningHandsFreeContent: some View {
        HStack(spacing: 10) {
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            WaveformBarsView(audioLevel: viewModel.audioLevel)
                .frame(maxWidth: .infinity)

            Button(action: { viewModel.onStop?() }) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 10, height: 10)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Processing (slow path)

    /// STT taking longer than expected. Reassurance message and cancel.
    private var processingSlowContent: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel processing")

            BreathingBarView(maxWidth: 28)
                .frame(width: 28)
                .clipped()

            Text("Still working\u{2026}")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
    }

    // MARK: - No Target

    /// Injection failed. Shows paste-shortcut hint and dismiss.
    private var noTargetContent: some View {
        HStack(spacing: 8) {
            Text(viewModel.shortcuts.noTargetHint)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Button(action: { viewModel.onDismiss?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Session Expired

    /// Session token was rejected. Brief message before recovery flow takes over.
    private var sessionExpiredContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange.opacity(0.9))

            Text("Session expired")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
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

// MARK: - Waveform bars (listening animation)

/// A row of rounded bars driven by live audio input level.
///
/// Each bar's height is proportional to `audioLevel` (0.0 to 1.0), with
/// center bars scaled taller for a natural waveform envelope. A small
/// idle animation keeps the bars gently moving when audio is silent so
/// the HUD never looks frozen.
///
/// When Reduce Motion is enabled, bars pulse opacity instead of changing height.
struct WaveformBarsView: View {

    /// Current audio input level from the mic (0.0 to 1.0).
    var audioLevel: Float

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 16

    /// Per-bar random-ish offsets so they don't all look identical at the
    /// same audio level. Seeded, not truly random.
    private let barJitter: [Float] = [0.0, 0.15, -0.1, 0.2, -0.05]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let scale = amplitudeScale(for: index)
                // Cap at 0.8 so jitter always differentiates bar heights,
                // even at loud volumes. Bars never all pin at max together.
                let capped = min(Float(audioLevel), 0.8)
                let jittered = min(max(capped + barJitter[index], 0), 1)
                let barHeight = minHeight + (maxHeight - minHeight) * CGFloat(jittered) * scale
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: barWidth, height: max(barHeight, minHeight))
            }
        }
        .animation(.interpolatingSpring(stiffness: 300, damping: 20), value: audioLevel)
    }

    /// Center bars get a larger share of the max height.
    private func amplitudeScale(for index: Int) -> CGFloat {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center)
        let maxDistance = center
        return CGFloat(1.0 - (distance / maxDistance) * 0.4)
    }
}

// MARK: - Breathing bar (processing animation)

/// A single horizontal bar that gently pulses its width and opacity to
/// signal that the app is processing (thinking), not listening.
///
/// Visually distinct from the waveform bars: one continuous shape instead
/// of discrete bars, with a slow calm rhythm instead of reactive movement.
/// When Reduce Motion is enabled, only opacity pulses.
struct BreathingBarView: View {

    /// Maximum width the bar animates to. Callers can pass a smaller value
    /// so the bar stays within tight pill layouts (e.g. slow-processing).
    var maxWidth: CGFloat = 40

    private let barHeight: CGFloat = 3
    private let minWidth: CGFloat = 16

    @State private var isAnimating = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        RoundedRectangle(cornerRadius: barHeight / 2)
            .fill(Color.white.opacity(isAnimating ? 0.9 : 0.4))
            .frame(
                width: reduceMotion ? maxWidth : (isAnimating ? maxWidth : minWidth),
                height: barHeight
            )
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
            .onDisappear { isAnimating = false }
    }
}
