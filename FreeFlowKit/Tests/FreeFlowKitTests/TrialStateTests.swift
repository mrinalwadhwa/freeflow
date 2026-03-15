import Testing

@testable import FreeFlowKit

@Suite("TrialState")
struct TrialStateTests {

    // MARK: - menuLabel

    @Suite("menuLabel")
    struct MenuLabelTests {

        @Test("Returns nil when user has credit card on file")
        func hasCreditCard() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 10,
                hasCreditCard: true,
                isExpired: false
            )
            #expect(state.menuLabel == nil)
        }

        @Test("Returns nil when user has credit card even if expired")
        func hasCreditCardExpired() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: true,
                isExpired: true
            )
            #expect(state.menuLabel == nil)
        }

        @Test("Returns nil when not on trial and not expired")
        func activeNotTrial() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == nil)
        }

        @Test("Shows 'Trial expired' when expired without card")
        func expired() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: true
            )
            #expect(state.menuLabel == "Trial expired")
        }

        @Test("Shows 'Trial ends today' at zero days remaining")
        func zeroDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == "Trial ends today")
        }

        @Test("Shows 'Trial ends tomorrow' at one day remaining")
        func oneDay() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 1,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == "Trial ends tomorrow")
        }

        @Test("Shows days remaining for 2+ days")
        func multipleDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 11,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == "11 days left in free trial")
        }

        @Test("Shows days remaining at boundary of 2 days")
        func twoDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 2,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == "2 days left in free trial")
        }

        @Test("Shows days remaining at 14 days")
        func fullTrial() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 14,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.menuLabel == "14 days left in free trial")
        }
    }

    // MARK: - isUrgent

    @Suite("isUrgent")
    struct IsUrgentTests {

        @Test("Not urgent when user has credit card")
        func hasCreditCard() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 1,
                hasCreditCard: true,
                isExpired: false
            )
            #expect(!state.isUrgent)
        }

        @Test("Not urgent when user has credit card and expired")
        func hasCreditCardExpired() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: true,
                isExpired: true
            )
            #expect(!state.isUrgent)
        }

        @Test("Urgent when expired without card")
        func expired() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: true
            )
            #expect(state.isUrgent)
        }

        @Test("Not urgent at 4 days remaining without card")
        func fourDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 4,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(!state.isUrgent)
        }

        @Test("Urgent at 3 days remaining without card")
        func threeDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 3,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.isUrgent)
        }

        @Test("Urgent at 2 days remaining without card")
        func twoDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 2,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.isUrgent)
        }

        @Test("Urgent at 1 day remaining without card")
        func oneDay() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 1,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.isUrgent)
        }

        @Test("Urgent at 0 days remaining without card")
        func zeroDays() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(state.isUrgent)
        }

        @Test("Not urgent at 14 days remaining without card")
        func fullTrial() {
            let state = TrialState(
                isTrial: true,
                daysRemaining: 14,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(!state.isUrgent)
        }

        @Test("Not urgent when not on trial and not expired")
        func activeNotTrial() {
            let state = TrialState(
                isTrial: false,
                daysRemaining: 0,
                hasCreditCard: false,
                isExpired: false
            )
            #expect(!state.isUrgent)
        }
    }

    // MARK: - Equatable

    @Suite("Equatable")
    struct EquatableTests {

        @Test("Equal states are equal")
        func equal() {
            let a = TrialState(
                isTrial: true, daysRemaining: 7, hasCreditCard: false, isExpired: false)
            let b = TrialState(
                isTrial: true, daysRemaining: 7, hasCreditCard: false, isExpired: false)
            #expect(a == b)
        }

        @Test("Different daysRemaining are not equal")
        func differentDays() {
            let a = TrialState(
                isTrial: true, daysRemaining: 7, hasCreditCard: false, isExpired: false)
            let b = TrialState(
                isTrial: true, daysRemaining: 6, hasCreditCard: false, isExpired: false)
            #expect(a != b)
        }

        @Test("Different hasCreditCard are not equal")
        func differentCard() {
            let a = TrialState(
                isTrial: true, daysRemaining: 7, hasCreditCard: false, isExpired: false)
            let b = TrialState(
                isTrial: true, daysRemaining: 7, hasCreditCard: true, isExpired: false)
            #expect(a != b)
        }

        @Test("Different isExpired are not equal")
        func differentExpired() {
            let a = TrialState(
                isTrial: false, daysRemaining: 0, hasCreditCard: false, isExpired: false)
            let b = TrialState(
                isTrial: false, daysRemaining: 0, hasCreditCard: false, isExpired: true)
            #expect(a != b)
        }
    }
}
