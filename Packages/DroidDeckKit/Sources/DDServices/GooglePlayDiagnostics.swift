import Foundation
import DDCore
import DDPlatform
import DDADB

/// Measures the conditions that commonly break Google sign-in on Play Store emulator images.
/// It reports facts; it does not alter how the device identifies itself to Google.
public enum GooglePlayDiagnostics {
    public struct Finding: Sendable, Identifiable, Equatable {
        public enum Status: Sendable, Equatable { case ok, warning, problem, info }
        public enum Fix: Sendable, Equatable { case enableAutomaticTime, waitForUpdates, createPlayDevice }
        public var id: String { title }
        public var status: Status
        public var title: String
        public var detail: String
        public var fix: Fix?
    }

    /// True when `pm path com.android.vending` points at the real Play Store. Google APIs images ship
    /// the same package name as a licensing stub (LicenseChecker.apk), which is not the Play Store.
    static func isPlayStore(pmPathOutput: String) -> Bool {
        pmPathOutput.split(separator: "\n").contains { line in
            line.hasPrefix("package:") && !line.contains("LicenseChecker")
                && (line.contains("Phonesky") || line.contains("Vending") || line.contains("/data/app/"))
        }
    }

    public static func run(serial: String, adb: ADBClient, imageHasPlay: Bool, startedAt: Date?) async -> [Finding] {
        var findings: [Finding] = []
        let vending = (try? await adb.shell(serial, "pm path com.android.vending", timeout: .seconds(15), allowFailure: true)) ?? ""
        guard isPlayStore(pmPathOutput: vending) else {
            findings.append(Finding(
                status: .problem, title: "Google Play Store is not on this device",
                detail: imageHasPlay
                    ? "The image should include Google Play but the Play Store package is missing."
                    : "This device uses a Google APIs image, which never includes the Play Store. It cannot be added to an existing device; create a device from a Google Play image.",
                fix: imageHasPlay ? nil : .createPlayDevice))
            return findings
        }
        findings.append(Finding(status: .ok, title: "Google Play Store is installed", detail: await version(of: "com.android.vending", serial: serial, adb: adb)))
        findings.append(Finding(status: .ok, title: "Google Play services", detail: await version(of: "com.google.android.gms", serial: serial, adb: adb)))

        // Clock: Google sign-in fails when the device time is far off.
        if let deviceEpoch = Double(((try? await adb.shell(serial, "date +%s", timeout: .seconds(10), allowFailure: true)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)) {
            let skew = abs(deviceEpoch - Date().timeIntervalSince1970)
            let autoTime = ((try? await adb.shell(serial, "settings get global auto_time", timeout: .seconds(10), allowFailure: true)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if skew > 120 {
                findings.append(Finding(status: .problem, title: "Device clock is off by \(Int(skew / 60)) minutes",
                                        detail: "Google rejects sign-in when the device time is wrong.", fix: .enableAutomaticTime))
            } else {
                findings.append(Finding(status: .ok, title: "Device clock is correct",
                                        detail: "Within \(Int(skew)) s of this Mac\(autoTime == "1" ? " · automatic time on" : "").",
                                        fix: autoTime == "1" ? nil : .enableAutomaticTime))
            }
        }

        // Network: DNS and HTTPS reachability of Google's account servers.
        let dns = (try? await adb.shell(serial, "ping -c 1 -W 3 accounts.google.com >/dev/null 2>&1 && echo ok", timeout: .seconds(10), allowFailure: true)) ?? ""
        let https = (try? await adb.shell(serial, "echo | nc -w 6 accounts.google.com 443 >/dev/null 2>&1 && echo ok", timeout: .seconds(12), allowFailure: true)) ?? ""
        if https.contains("ok") {
            findings.append(Finding(status: .ok, title: "accounts.google.com is reachable", detail: "HTTPS connection succeeded from inside Android."))
        } else {
            findings.append(Finding(status: .problem, title: "accounts.google.com is not reachable",
                                    detail: dns.contains("ok") ? "The name resolves but HTTPS (port 443) fails. A VPN, proxy or firewall may be blocking it."
                                                               : "The name does not resolve. Check the device's network and DNS in the Network tab."))
        }

        // Fresh devices update Play services in the background; sign-in can bounce until that finishes.
        // Host-side start time is used because Quick Boot restores the guest's uptime counter.
        if let startedAt, Date().timeIntervalSince(startedAt) < 240 {
            findings.append(Finding(status: .info, title: "Device started \(Int(Date().timeIntervalSince(startedAt))) s ago",
                                    detail: "Right after boot, Google Play services finishes updating in the background. If sign-in returns to the previous screen, wait a few minutes and try again.",
                                    fix: .waitForUpdates))
        }

        let accounts = (try? await adb.shell(serial, "dumpsys account | grep -c 'Account {'", timeout: .seconds(15), allowFailure: true))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        findings.append(Finding(status: .info, title: "Accounts on device: \(accounts)", detail: "Counted from Android's account service; names are not shown."))

        // Recent account errors, with personal data removed.
        let log = (try? await adb.shell(serial, "logcat -d -t 4000 -v brief GLSUser:W Auth:W AccountManagerService:W GoogleAuthUtil:W *:S",
                                         timeout: .seconds(20), allowFailure: true)) ?? ""
        let errors = log.split(separator: "\n").map(String.init).filter { $0.hasPrefix("W/") || $0.hasPrefix("E/") }.suffix(6)
        if !errors.isEmpty {
            findings.append(Finding(status: .warning, title: "Recent sign-in errors in the device log",
                                    detail: Redactor.redact(errors.joined(separator: "\n"), level: .export)))
        }
        return findings
    }

    static func version(of package: String, serial: String, adb: ADBClient) async -> String {
        let output = (try? await adb.shell(serial, "dumpsys package \(ShellQuote.quote(package)) | grep -m1 versionName", timeout: .seconds(20), allowFailure: true)) ?? ""
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "versionName=", with: "")
        return value.isEmpty ? "Version unknown" : "Version \(value)"
    }

    /// Turns on network-provided time (a global setting the adb shell may change).
    public static func enableAutomaticTime(serial: String, adb: ADBClient) async throws {
        try await adb.shell(serial, "settings put global auto_time 1", timeout: .seconds(10))
    }
}
