import Foundation
import DDCore
import DDPlatform
import DDADB

/// Makes a device lighter for running a few apps: disables preinstalled apps the user doesn't
/// need and turns off UI animations. Everything is reversible; nothing is uninstalled.
/// Verified on Android 14 Google APIs images: `pm disable-user --user 0` and global animation
/// scales are both permitted to the adb shell on user builds.
public enum DeviceStreamlining {
    public struct OptionalApp: Sendable, Identifiable, Hashable {
        public var id: String { package }
        public var package: String
        public var name: String
        /// Selected by default when streamlining.
        public var recommended: Bool
        public var note: String?
    }

    /// Preinstalled consumer apps that are safe to disable. System components (Play Store,
    /// Play services, WebView, launcher, keyboard, Settings, SystemUI, Files) are never listed.
    public static let optionalApps: [OptionalApp] = [
        OptionalApp(package: "com.google.android.youtube", name: "YouTube", recommended: true),
        OptionalApp(package: "com.google.android.apps.youtube.music", name: "YouTube Music", recommended: true),
        OptionalApp(package: "com.google.android.gm", name: "Gmail", recommended: true),
        OptionalApp(package: "com.google.android.apps.maps", name: "Google Maps", recommended: true),
        OptionalApp(package: "com.google.android.apps.docs", name: "Google Drive", recommended: true),
        OptionalApp(package: "com.google.android.apps.tachyon", name: "Google Meet", recommended: true),
        OptionalApp(package: "com.google.android.calendar", name: "Google Calendar", recommended: true),
        OptionalApp(package: "com.google.android.apps.messaging", name: "Messages", recommended: true),
        OptionalApp(package: "com.android.chrome", name: "Chrome", recommended: true,
                    note: "Web pages inside apps keep working: they use Android System WebView."),
        OptionalApp(package: "com.google.android.googlequicksearchbox", name: "Google app", recommended: true,
                    note: "Removes the home-screen search bar's background activity."),
        OptionalApp(package: "com.google.android.deskclock", name: "Clock", recommended: false),
        OptionalApp(package: "com.google.android.apps.photos", name: "Google Photos", recommended: false,
                    note: "Keep it if you want a gallery app for shared-folder photos and videos."),
        OptionalApp(package: "com.android.camera2", name: "Camera", recommended: false),
        OptionalApp(package: "com.google.android.dialer", name: "Phone", recommended: false),
        OptionalApp(package: "com.google.android.contacts", name: "Contacts", recommended: false),
    ]

    public struct State: Sendable, Equatable {
        public var installed: Set<String>
        public var disabled: Set<String>
        public var animationsOff: Bool
        public var thirdPartyApps: [String]
    }

    static let animationKeys = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]

    public static func state(serial: String, adb: ADBClient) async throws -> State {
        let all = try await adb.shell(serial, "pm list packages", timeout: .seconds(30))
        let disabled = try await adb.shell(serial, "pm list packages -d", timeout: .seconds(30))
        func set(_ text: String) -> Set<String> {
            Set(text.split(separator: "\n").compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil })
        }
        let scales = try await adb.shell(serial, animationKeys.map { "settings get global \($0)" }.joined(separator: "; "), timeout: .seconds(15))
        let off = scales.split(separator: "\n").allSatisfy { Double($0.trimmingCharacters(in: .whitespaces)) == 0 }
        return State(installed: set(all), disabled: set(disabled), animationsOff: off,
                     thirdPartyApps: (try? await adb.packages(serial, thirdPartyOnly: true)) ?? [])
    }

    /// Disables the given packages and optionally turns animations off. Returns per-package failures.
    @discardableResult
    public static func apply(serial: String, adb: ADBClient, disable packages: [String], animationsOff: Bool) async throws -> [String] {
        var failures: [String] = []
        for package in packages {
            let output = (try? await adb.shell(serial, "pm disable-user --user 0 \(ShellQuote.quote(package))", timeout: .seconds(30), allowFailure: true)) ?? ""
            if !output.contains("disabled") { failures.append(package) }
        }
        if animationsOff {
            try await adb.shell(serial, animationKeys.map { "settings put global \($0) 0" }.joined(separator: "; "), timeout: .seconds(15))
        }
        log.info("streamline", "\(serial): disabled \(packages.count - failures.count) apps, animations off: \(animationsOff)")
        return failures
    }

    /// Re-enables DroidDeck's optional apps and restores normal animations.
    public static func restore(serial: String, adb: ADBClient) async throws {
        let state = try await state(serial: serial, adb: adb)
        for app in optionalApps where state.disabled.contains(app.package) {
            _ = try? await adb.shell(serial, "pm enable \(ShellQuote.quote(app.package))", timeout: .seconds(30), allowFailure: true)
        }
        try await adb.shell(serial, animationKeys.map { "settings put global \($0) 1" }.joined(separator: "; "), timeout: .seconds(15))
    }
}
