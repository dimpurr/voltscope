import Foundation

/// The small, platform-independent part of login-item behavior. The app maps
/// `SMAppService.Status` into this enum and keeps the UI and tests independent
/// from the system registration API.
public enum LoginItemStatusKind: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case error
}

public enum LoginItemOnboardingDecision: Equatable, Sendable {
    case showWelcome
    case skip
}

public enum LoginItemEligibility: Equatable, Sendable {
    case allowed
    case moveToApplications
}

public enum LoginItemPolicy {
    /// A registered main app is already being kept alive at login. This is
    /// also the safe fallback for a first launch whose registration predates
    /// the onboarding flag, so login launches never steal focus with Welcome.
    public static func onboardingDecision(
        onboardingHandled: Bool,
        status: LoginItemStatusKind
    ) -> LoginItemOnboardingDecision {
        guard !onboardingHandled, status != .enabled else { return .skip }
        return .showWelcome
    }

    /// Only an app inside an Applications directory has a stable path that
    /// macOS can use for a main-app login item. This deliberately rejects
    /// Downloads, mounted DMGs, build products, and source checkouts.
    public static func eligibility(bundlePath: String, homePath: String) -> LoginItemEligibility {
        let normalizedBundle = URL(fileURLWithPath: bundlePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let normalizedHome = URL(fileURLWithPath: homePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let systemApplications = "/Applications/"
        let userApplications = normalizedHome.hasSuffix("/")
            ? normalizedHome + "Applications/"
            : normalizedHome + "/Applications/"

        if normalizedBundle.hasPrefix(systemApplications) || normalizedBundle.hasPrefix(userApplications) {
            return .allowed
        }
        return .moveToApplications
    }
}
