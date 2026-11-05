import Foundation
import DDCore
import DDPlatform

/// Reads the Android Emulator's discovery files. Each running emulator writes
/// `pid_<pid>.ini` with its AVD, console/adb/gRPC ports and gRPC token
/// (verified with emulator 36.6.11 on macOS; the console's `avd discoverypath`
/// reports the same directory).
public enum EmulatorDiscovery {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/TemporaryItems/avd/running")
    }

    public static func discoveryFile(pid: Int32) -> URL {
        directory.appending(path: "pid_\(pid).ini")
    }

    /// Running instances with a live process. Stale files from crashed emulators are ignored.
    public static func runningInstances(launchedPIDs: Set<Int32> = []) -> [RunningInstance] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> RunningInstance? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("pid_"), let pid = Int32(name.dropFirst(4)), ProcessLiveness.isAlive(pid),
                  let ini = try? INIFile(contentsOf: url) else { return nil }
            return instance(from: ini, pid: pid, launchedByDroidDeck: launchedPIDs.contains(pid))
        }
        .sorted { $0.consolePort < $1.consolePort }
    }

    static func instance(from ini: INIFile, pid: Int32, launchedByDroidDeck: Bool) -> RunningInstance? {
        guard let avdName = ini["avd.name"], let console = ini["port.serial"].flatMap(Int.init) else { return nil }
        let cmdline = ini["cmdline"] ?? ""
        let mode: DisplayMode
        if cmdline.contains("\"-no-window\"") || cmdline.contains(" -no-window") {
            mode = .headless
        } else if cmdline.contains("-qt-hide-window") {
            mode = .embedded
        } else {
            mode = .externalWindow
        }
        return RunningInstance(
            pid: pid,
            avdName: avdName,
            avdDirectory: ini["avd.dir"].map { URL(fileURLWithPath: $0) },
            consolePort: console,
            adbPort: ini["port.adb"].flatMap(Int.init) ?? console + 1,
            grpcPort: ini["grpc.port"].flatMap(Int.init),
            grpcToken: ini["grpc.token"],
            displayMode: mode,
            launchedByDroidDeck: launchedByDroidDeck,
            emulatorVersion: ini["emulator.version"],
            startedAt: (try? FileManager.default.attributesOfItem(atPath: discoveryFile(pid: pid).path))?[.creationDate] as? Date
        )
    }
}

/// Explains emulator launch failures from its log output.
public enum EmulatorLaunchDiagnosis {
    /// True when the emulator tried to restore a Quick Boot snapshot and couldn't (e.g. "Missing section
    /// footer for …/goldfish_address_space" then "Failed to load snapshot"). It then runs a half-restored
    /// machine that hangs or segfaults. A device without a snapshot yet logs "Failed to load snapshot" too,
    /// after "does not have the requested snapshot"; that is a normal first boot.
    public static func quickBootSnapshotFailed(log: String) -> Bool {
        (log.contains("Failed to load snapshot") || log.contains("while loading VM state"))
            && !log.contains("does not have the requested snapshot")
    }

    public static func diagnose(log: String, exitCode: Int32?) -> DroidDeckError {
        let tail = Redactor.redact(String(log.suffix(6000)))
        let rules: [(String, String, String?)] = [
            ("unknown skin name", "The device's frame (skin) setting points to a skin the emulator cannot find.",
             "Use \"Repair frame setting\" in the device overview, or turn off the device frame."),
            ("cannot model more than", "The configured RAM exceeds what the emulator can provide on this Mac.",
             "Lower RAM to 31 GB or less in the device settings."),
            ("Unknown AVD name", "The emulator could not find this device.", "Refresh the device list; the AVD may have been moved or deleted."),
            ("Running multiple emulators with the same AVD", "This device is already running in another emulator.",
             "Stop the other instance first."),
            ("another emulator instance", "This device is already running in another emulator.", "Stop the other instance first."),
            ("HVF error", "macOS Hypervisor.framework refused to start the virtual machine.",
             "Quit other virtualization apps, then try again. Restart the Mac if the problem persists."),
            ("hv_vm_create", "macOS Hypervisor.framework refused to start the virtual machine.",
             "Quit other virtualization apps, then try again."),
            ("Not enough space", "There is not enough disk space to start this device.", "Free disk space and try again."),
            ("Cannot find AVD system path", "The device's system image is missing.", "Reinstall the system image in System Images."),
            ("Could not open", "The emulator could not open one of the device's files.", "Check the emulator log for the file name."),
            ("address already in use", "A required network port is already in use.", "Try starting the device again."),
        ]
        for (needle, message, recovery) in rules where log.localizedCaseInsensitiveContains(needle) {
            return DroidDeckError(.launchFailed, message, recovery: recovery, detail: tail)
        }
        let fatal = log.split(separator: "\n").last { $0.contains("FATAL") || $0.contains("ERROR") || $0.contains("PANIC") }
        let message = fatal.map { "The emulator exited: \(Redactor.redact(String($0)).trimmingCharacters(in: .whitespaces))" }
            ?? "The emulator exited unexpectedly\(exitCode.map { " (status \($0))" } ?? "")."
        return DroidDeckError(.launchFailed, message, recovery: "Open the emulator log in Diagnostics for details.", detail: tail)
    }
}
