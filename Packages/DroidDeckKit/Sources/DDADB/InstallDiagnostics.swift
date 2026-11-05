import Foundation
import DDCore
import DDPlatform

/// Translates package-manager failure codes into explanations and recovery steps.
public enum InstallFailure {
    public static func diagnose(output: String) -> DroidDeckError {
        let code = output.range(of: #"(INSTALL_[A-Z_]+)"#, options: .regularExpression).map { String(output[$0]) }
        let detail = Redactor.redact(output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let code else {
            return DroidDeckError(.installFailed, "The app could not be installed.", detail: detail)
        }
        let (message, recovery) = explanation(for: code)
        return DroidDeckError(.installFailed, message, recovery: recovery, detail: "\(code)\n\(detail)")
    }

    static func explanation(for code: String) -> (String, String?) {
        switch code {
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            return ("The app's native code does not support this device's CPU architecture.",
                    "Use a build that includes arm64-v8a libraries (Apple Silicon) or x86_64 (Intel).")
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            return ("The device does not have enough free storage.", "Uninstall apps, or increase internal storage and wipe data.")
        case "INSTALL_FAILED_VERSION_DOWNGRADE":
            return ("A newer version of this app is already installed.", "Enable \"Allow downgrade\" or uninstall the existing app first.")
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE":
            return ("The installed app was signed with a different certificate.", "Uninstall the existing app, then install again.")
        case "INSTALL_FAILED_OLDER_SDK":
            return ("The app requires a newer Android version than this device runs.", "Create a device with a newer system image.")
        case "INSTALL_FAILED_DEPRECATED_SDK_VERSION":
            return ("Android 14 and later block apps that target very old SDK versions.",
                    "Enable \"Bypass low target SDK block\" if you trust this app.")
        case "INSTALL_FAILED_TEST_ONLY":
            return ("This is a test-only build.", "Enable \"Allow test packages\".")
        case "INSTALL_FAILED_ALREADY_EXISTS":
            return ("The app is already installed.", "Enable \"Replace existing\".")
        case "INSTALL_FAILED_MISSING_SPLIT":
            return ("This app is delivered as split APKs and a required split is missing.",
                    "Select the base APK and all of its split APKs together.")
        case "INSTALL_FAILED_DUPLICATE_PERMISSION":
            return ("Another installed app already defines one of this app's permissions.", "Uninstall the conflicting app.")
        case "INSTALL_FAILED_CONFLICTING_PROVIDER":
            return ("Another installed app already uses one of this app's content provider authorities.", "Uninstall the conflicting app.")
        case "INSTALL_FAILED_VERIFICATION_FAILURE", "INSTALL_FAILED_VERIFICATION_TIMEOUT":
            return ("Package verification (Google Play Protect) rejected or timed out on the app.",
                    "Review the Play Protect prompt on the device.")
        case "INSTALL_FAILED_USER_RESTRICTED":
            return ("Installing apps over USB/ADB is restricted on this device.", "Allow installs via USB in Developer options.")
        case "INSTALL_FAILED_INVALID_APK", "INSTALL_PARSE_FAILED_NOT_APK", "INSTALL_PARSE_FAILED_UNEXPECTED_EXCEPTION":
            return ("The file is not a valid APK or is corrupted.", "Download the APK again.")
        case "INSTALL_PARSE_FAILED_NO_CERTIFICATES", "INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES":
            return ("The APK is not signed correctly.", "Sign the APK (apksigner) before installing.")
        case "INSTALL_FAILED_ABORTED":
            return ("The installation was cancelled on the device.", nil)
        default:
            return ("The app could not be installed (\(code)).", nil)
        }
    }
}

/// Facts read from an APK with aapt2, used for pre-install compatibility checks.
public struct APKInfo: Sendable, Equatable {
    public var packageName: String
    public var versionName: String?
    public var versionCode: String?
    public var label: String?
    public var minSDK: Int?
    public var targetSDK: Int?
    public var nativeABIs: [String]
    public var isSplit: Bool

    /// Parses `aapt2 dump badging` output.
    public static func parse(badging text: String) -> APKInfo? {
        func attribute(_ name: String, in line: Substring) -> String? {
            guard let range = line.range(of: "\(name)='") else { return nil }
            let rest = line[range.upperBound...]
            return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
        }
        var info: APKInfo?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("package:") {
                guard let name = attribute("name", in: line) else { continue }
                info = APKInfo(packageName: name, versionName: attribute("versionName", in: line),
                               versionCode: attribute("versionCode", in: line), label: nil, minSDK: nil,
                               targetSDK: nil, nativeABIs: [], isSplit: attribute("split", in: line) != nil)
            } else if line.hasPrefix("sdkVersion:'") || line.hasPrefix("minSdkVersion:'") {
                info?.minSDK = Int(line.split(separator: "'").dropFirst().first ?? "")
            } else if line.hasPrefix("targetSdkVersion:'") {
                info?.targetSDK = Int(line.split(separator: "'").dropFirst().first ?? "")
            } else if line.hasPrefix("application-label:'") {
                info?.label = line.split(separator: "'").dropFirst().first.map(String.init)
            } else if line.hasPrefix("native-code:") {
                info?.nativeABIs = line.dropFirst("native-code:".count)
                    .split(separator: "'").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return info
    }

    /// Problems that will make installation fail on a device with the given API level and ABI list.
    public func compatibilityProblems(deviceAPI: Int?, deviceABIs: [String]) -> [String] {
        var problems: [String] = []
        if let minSDK, let deviceAPI, minSDK > deviceAPI {
            problems.append("Requires Android API \(minSDK); the device runs API \(deviceAPI).")
        }
        if !nativeABIs.isEmpty, !deviceABIs.isEmpty, Set(nativeABIs).isDisjoint(with: deviceABIs) {
            problems.append("Contains native code only for \(nativeABIs.joined(separator: ", ")); the device supports \(deviceABIs.joined(separator: ", ")).")
        }
        return problems
    }

    public static func inspect(apk: URL, aapt2: URL, runner: ProcessRunner) async throws -> APKInfo {
        let result = try await runner.run(aapt2, ["dump", "badging", apk.path], timeout: .seconds(60))
        guard let info = parse(badging: result.stdoutString) else {
            throw DroidDeckError(.installFailed, "\(apk.lastPathComponent) could not be read as an APK.", detail: result.diagnosticOutput)
        }
        return info
    }
}
