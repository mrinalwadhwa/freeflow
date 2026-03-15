import Foundation

/// Cached trial status from the Autonomy orchestrator.
///
/// Updated periodically by polling `GET /api/freeflow/status`. The app
/// uses this to show trial indicators in the menu bar and to detect
/// trial expiry.
public struct TrialState: Sendable, Equatable {
    /// Whether the user is currently on a trial plan.
    public let isTrial: Bool

    /// Days remaining in the trial. Zero when trial has expired or
    /// user is on a paid plan.
    public let daysRemaining: Int

    /// Whether the user has a credit card on file. When true during
    /// trial, the transition to paid will be automatic.
    public let hasCreditCard: Bool

    /// Whether the trial has expired (user_state is trial_expired).
    /// When true, the zone has been deleted and dictation is unavailable.
    public let isExpired: Bool

    /// Human-readable summary for the menu bar.
    ///
    /// Returns nil when no trial indicator should be shown (user has
    /// a card on file, or is not on trial).
    public var menuLabel: String? {
        // Don't show trial indicator if user has a card — the transition
        // to paid will be seamless and they don't need to worry about it.
        if hasCreditCard { return nil }

        if isExpired {
            return "Trial expired"
        }

        if !isTrial { return nil }

        switch daysRemaining {
        case 0:
            return "Trial ends today"
        case 1:
            return "Trial ends tomorrow"
        default:
            return "\(daysRemaining) days left in free trial"
        }
    }

    /// Whether the trial status is urgent (3 days or fewer remaining,
    /// no card on file). When true, the menu bar should show the
    /// "Add credit card…" action item.
    public var isUrgent: Bool {
        if hasCreditCard { return false }
        if isExpired { return true }
        return isTrial && daysRemaining <= 3
    }
}

/// Poll the Autonomy orchestrator for trial status.
///
/// Creates an `AutonomyClient` from the Keychain-stored Autonomy token
/// and polls `GET /api/freeflow/status` on a schedule. Caches the
/// result as a `TrialState` and delivers updates via `AsyncStream`.
///
/// Polling frequency adapts to urgency:
///   - Normal trial (>3 days remaining): every 6 hours
///   - Urgent trial (≤3 days remaining): every 1 hour
///   - Trial expired: stops polling (terminal state)
///
/// Only polls for admin users (those with an Autonomy token). Guests
/// have no trial and this service does nothing for them.
public final class TrialStatusService: @unchecked Sendable {

    private let keychain: KeychainService
    private var pollingTask: Task<Void, Never>?
    private let lock = NSLock()

    /// The most recently fetched trial state.
    private var _current: TrialState?
    public var current: TrialState? {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    private var continuations: [UUID: AsyncStream<TrialState>.Continuation] = [:]

    /// Stream of trial state updates. Each new value is delivered when
    /// the state changes (or on first successful poll).
    public var stateStream: AsyncStream<TrialState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.lock.lock()
            self.continuations[id] = continuation
            // Deliver current state immediately if available.
            if let current = self._current {
                continuation.yield(current)
            }
            self.lock.unlock()

            continuation.onTermination = { _ in
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    /// Start periodic polling. Safe to call multiple times.
    public func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let state = await self.checkNow()

                // Determine next poll interval based on urgency.
                let interval: UInt64
                if let state, state.isExpired {
                    // Terminal state — no need to keep polling.
                    break
                } else if let state, state.isUrgent {
                    interval = 1 * 60 * 60 * 1_000_000_000  // 1 hour
                } else {
                    interval = 6 * 60 * 60 * 1_000_000_000  // 6 hours
                }

                // Allow cancellation during sleep.
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
            }
        }
    }

    /// Stop polling.
    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Fetch the current trial state from the orchestrator.
    ///
    /// Updates the cached `current` value and notifies stream
    /// subscribers if the state changed. Returns nil if there is no
    /// Autonomy token (guest users) or the request fails.
    @discardableResult
    public func checkNow() async -> TrialState? {
        guard let token = keychain.autonomyToken() else {
            return nil
        }

        let client = AutonomyClient(token: token)

        do {
            let status = try await client.status()

            let state = TrialState(
                isTrial: status.trial ?? false,
                daysRemaining: status.trialDaysRemaining ?? 0,
                hasCreditCard: status.hasCreditCard ?? false,
                isExpired: false
            )

            updateState(state)
            return state
        } catch AutonomyError.trialExpired {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: true
            )
            updateState(state)
            return state
        } catch {
            #if DEBUG
                Log.debug("[TrialStatusService] Status check failed: \(error)")
            #endif
            return nil
        }
    }

    private func updateState(_ newState: TrialState) {
        lock.lock()
        let changed = _current != newState
        _current = newState
        let continuations = self.continuations
        lock.unlock()

        if changed {
            for (_, continuation) in continuations {
                continuation.yield(newState)
            }
        }
    }
}
