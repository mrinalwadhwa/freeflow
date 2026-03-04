import Foundation
import Testing

@testable import VoiceKit

@Suite("Injection error descriptions")
struct InjectionErrorTests {

    @Test("noFocusedElement error has a description")
    func noFocusedElementDescription() {
        let error = AppTextInjector.InjectionError.noFocusedElement
        #expect(error.description.contains("focused"))
    }

    @Test("allStrategiesFailed error includes the app bundle ID")
    func allStrategiesFailedDescription() {
        let error = AppTextInjector.InjectionError.allStrategiesFailed(
            bundleID: "com.example.TestApp"
        )
        #expect(error.description.contains("com.example.TestApp"))
    }

    @Test("accessibilityNotGranted error has a description")
    func accessibilityNotGrantedDescription() {
        let error = AppTextInjector.InjectionError.accessibilityNotGranted
        #expect(error.description.contains("ccessibility"))
    }

    @Test("All error cases are distinct")
    func errorCasesDistinct() {
        let a = AppTextInjector.InjectionError.noFocusedElement
        let b = AppTextInjector.InjectionError.accessibilityNotGranted
        let c = AppTextInjector.InjectionError.allStrategiesFailed(bundleID: "com.test")

        #expect(a.description != b.description)
        #expect(a.description != c.description)
        #expect(b.description != c.description)
    }
}
