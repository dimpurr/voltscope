import AppKit
import SwiftUI

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String?, bundleId: String?) -> NSImage? {
        let key = path ?? bundleId ?? ""
        if key.isEmpty { return nil }
        if let cached = cache[key] { return cached }

        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            cache[key] = icon
            return icon
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            cache[key] = icon
            return icon
        }
        return nil
    }
}

struct AppIconView: View {
    let path: String?
    let bundleId: String?
    var size: CGFloat = 16

    var body: some View {
        if let icon = AppIconCache.shared.icon(forPath: path, bundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(.tertiary)
        }
    }
}
