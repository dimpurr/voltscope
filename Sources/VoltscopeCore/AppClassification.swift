import Foundation

/// Decides whether a process belongs to the "user app" or "system" bucket for
/// UI grouping. The classification is deliberately coarse for v0.5.1 — false
/// positives (an Apple-bundled user app marked system) can be added to the
/// allowlist; false negatives are safer because the user can still see the
/// process in the breakdown.
public enum AppClassification {
    /// Apple bundle IDs that represent end-user apps, not system services.
    /// These bypass the `com.apple.*` heuristic and stay classified as user apps.
    private static let appleUserApps: Set<String> = [
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.AddressBook",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.podcasts",
        "com.apple.News",
        "com.apple.Maps",
        "com.apple.weather",
        "com.apple.iBooksX",
        "com.apple.Photos",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.Preview",
        "com.apple.QuickTimePlayerX",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.apple.iChat",
        "com.apple.MobileSMS",
        "com.apple.FaceTime",
        "com.apple.shortcuts",
        "com.apple.freeform",
        "com.apple.systempreferences",
        "com.apple.findmy",
        "com.apple.iMovieApp",
        "com.apple.garageband10",
        "com.apple.AppStore",
    ]

    public static func isSystem(bundleIdentifier: String?, processName: String, path: String?) -> Bool {
        guard let id = bundleIdentifier else {
            // Bundle-less processes (kernel helpers, daemons launched from /usr/libexec) are system.
            return true
        }
        if appleUserApps.contains(id) { return false }
        return id.hasPrefix("com.apple.")
    }
}
