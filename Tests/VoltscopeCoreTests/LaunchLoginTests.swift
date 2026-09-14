import XCTest
@testable import VoltscopeCore

final class LaunchLoginTests: XCTestCase {
    func testOnboardingShowsOnlyForUnprocessedNonEnabledInstall() {
        XCTAssertEqual(
            LoginItemPolicy.onboardingDecision(onboardingHandled: false, status: .notRegistered),
            .showWelcome
        )
        XCTAssertEqual(
            LoginItemPolicy.onboardingDecision(onboardingHandled: false, status: .requiresApproval),
            .showWelcome
        )
        XCTAssertEqual(
            LoginItemPolicy.onboardingDecision(onboardingHandled: true, status: .notRegistered),
            .skip
        )
        XCTAssertEqual(
            LoginItemPolicy.onboardingDecision(onboardingHandled: false, status: .enabled),
            .skip
        )
    }

    func testEligibilityAcceptsSystemAndUserApplicationsOnly() {
        XCTAssertEqual(
            LoginItemPolicy.eligibility(
                bundlePath: "/Applications/Voltscope.app",
                homePath: "/Users/alice"
            ),
            .allowed
        )
        XCTAssertEqual(
            LoginItemPolicy.eligibility(
                bundlePath: "/Users/alice/Applications/Voltscope.app",
                homePath: "/Users/alice"
            ),
            .allowed
        )
        XCTAssertEqual(
            LoginItemPolicy.eligibility(
                bundlePath: "/Users/alice/Downloads/Voltscope.app",
                homePath: "/Users/alice"
            ),
            .moveToApplications
        )
        XCTAssertEqual(
            LoginItemPolicy.eligibility(
                bundlePath: "/ApplicationsPreview/Voltscope.app",
                homePath: "/Users/alice"
            ),
            .moveToApplications
        )
    }
}
