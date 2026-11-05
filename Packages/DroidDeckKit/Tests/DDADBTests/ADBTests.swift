import Foundation
import Testing
@testable import DDADB
import DDCore

@Suite("adb parsing")
struct ADBParsingTests {
    @Test("Real `adb devices -l` output with a third-party emulator on emulator-5554")
    func devices() {
        let text = """
        List of devices attached
        emulator-5554          device product:23116PN5BC model:23116PN5BC device:23116PN5BC transport_id:3
        emulator-5680          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:4
        192.168.1.20:5555      unauthorized transport_id:5

        """
        let devices = ADBClient.parseDevices(text)
        #expect(devices.count == 3)
        #expect(devices[1].serial == "emulator-5680" && devices[1].consolePort == 5680)
        #expect(devices[1].model == "sdk_gphone64_arm64")
        #expect(devices[2].state == .unauthorized && devices[2].isNetworkDevice)
    }

    @Test("track-devices messages split correctly across arbitrary chunk boundaries")
    func trackDevices() {
        let first = "emulator-5554\tdevice product:x model:y\n"
        let second = ""
        let stream = String(format: "%04x", first.utf8.count) + first + String(format: "%04x", second.utf8.count) + second
        var parser = TrackDevicesParser()
        let bytes = Array(stream.utf8)
        var messages: [String] = []
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            messages += parser.feed(Data(bytes[chunk..<min(chunk + 7, bytes.count)]))
        }
        #expect(messages == [first, second])
        #expect(ADBClient.parseDevices(messages[0]).first?.serial == "emulator-5554")
        #expect(ADBClient.parseDevices(messages[1]).isEmpty)
    }

    @Test func consoleReplies() {
        #expect(ADBClient.consoleBody("ddprobe\r\nOK\r\n") == "ddprobe")
        #expect(ADBClient.consoleBody("/tmp/a.avd\nOK") == "/tmp/a.avd")
        #expect(ADBClient.consoleBody("OK\n") == "")
    }

    @Test func shellQuoting() {
        #expect(ShellQuote.quote("/sdcard/My Photos/it's.jpg") == #"'/sdcard/My Photos/it'\''s.jpg'"#)
        #expect(ShellQuote.quote("$(rm -rf /)") == "'$(rm -rf /)'")
    }

    @Test func remoteListing() {
        let text = """
        total 24
        drwxrws--- 4 u0_a160 media_rw 3452 2026-10-28 12:27 .
        drwxrws--- 4 u0_a160 media_rw 3452 2026-10-28 12:27 ..
        -rw-rw---- 1 u0_a160 media_rw   75 2026-10-28 12:27 my photo.png
        drwxrws--- 2 u0_a160 media_rw 3452 2026-10-28 12:30 Album
        lrwxrwxrwx 1 root    root       21 2026-10-28 12:30 link -> /storage/self/primary
        """
        let files = RemoteFile.parseListing(text, directory: "/sdcard/Pictures")
        #expect(files.map(\.name) == ["Album", "link", "my photo.png"])
        #expect(files[0].isDirectory && files[1].isSymlink)
        #expect(files[2].path == "/sdcard/Pictures/my photo.png" && files[2].size == 75)
    }

    @Test func logcatThreadtime() throws {
        let entry = try #require(LogcatEntry.parse("10-28 12:27:01.123  1234  5678 W ActivityManager: Slow operation: took 300ms"))
        #expect(entry.pid == 1234 && entry.tid == 5678)
        #expect(entry.priority == .warning)
        #expect(entry.tag == "ActivityManager")
        #expect(entry.message == "Slow operation: took 300ms")
        #expect(LogcatEntry.parse("--------- beginning of main") == nil)
    }
}

@Suite("Install diagnostics")
struct InstallDiagnosticsTests {
    @Test(arguments: [
        ("adb: failed to install app.apk: Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]", "CPU architecture"),
        ("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.x signatures do not match]", "different certificate"),
        ("Failure [INSTALL_FAILED_DEPRECATED_SDK_VERSION: App package must target at least SDK version 23]", "very old SDK"),
        ("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]", "newer version"),
    ])
    func knownCodes(output: String, phrase: String) {
        let error = InstallFailure.diagnose(output: output)
        #expect(error.kind == .installFailed)
        #expect(error.message.contains(phrase))
        #expect(error.recovery != nil)
    }

    @Test func apkBadging() throws {
        let text = """
        package: name='com.example.app' versionCode='42' versionName='1.4.2' platformBuildVersionName='14'
        sdkVersion:'26'
        targetSdkVersion:'34'
        application-label:'Example'
        native-code: 'armeabi-v7a' 'x86'
        """
        let info = try #require(APKInfo.parse(badging: text))
        #expect(info.packageName == "com.example.app" && info.versionName == "1.4.2")
        #expect(info.minSDK == 26 && info.targetSDK == 34 && info.label == "Example")
        #expect(info.nativeABIs == ["armeabi-v7a", "x86"])
        let problems = info.compatibilityProblems(deviceAPI: 24, deviceABIs: ["arm64-v8a"])
        #expect(problems.count == 2)
        #expect(info.compatibilityProblems(deviceAPI: 34, deviceABIs: ["arm64-v8a", "armeabi-v7a"]).isEmpty)
    }
}
