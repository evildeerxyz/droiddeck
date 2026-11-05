import Foundation
import Testing
@testable import DDPlatform
import DDCore

@Suite("Redaction")
struct RedactionTests {
    @Test func discoveryFileTokens() {
        let text = "grpc.port=8754\ngrpc.token=abc+/def==\navd.name=ddprobe"
        let redacted = Redactor.redact(text)
        #expect(!redacted.contains("abc+/def"))
        #expect(redacted.contains("grpc.port=8754"))
        #expect(redacted.contains("grpc.token=<redacted>"))
    }

    @Test("gRPC errors that echo the bearer token are scrubbed")
    func bearerEcho() {
        let message = "UNAUTHENTICATED: The token `Bearer anl98wdfM7z+TpU/LSQJVP29Mw==` is invalid"
        #expect(!Redactor.redact(message).contains("anl98"))
    }

    @Test func jwtAndBase64JSONArguments() {
        let cmd = "MuMu --a eyJiYXNlIjoyNDg3NDYxMTU2MTY1NDEsInNpZ24iOiJjNzlkYWE3 --index 0"
        #expect(!Redactor.redact(cmd).contains("eyJiYXNl"))
        let jwt = "token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl"
        #expect(!Redactor.redact(jwt).contains("c2lnbmF0dXJl"))
    }

    @Test func keyValueSecrets() {
        #expect(Redactor.redact("password=hunter2 user=me") == "password=<redacted> user=me")
        #expect(Redactor.redact("\"api_key\": \"sk-123\"").contains("<redacted>"))
        #expect(Redactor.redact("auth 12345abc") == "auth <redacted>")
    }

    @Test func exportLevelRemovesPersonalData() {
        let text = "account someone@example.com at \(NSHomeDirectory())/.android"
        let exported = Redactor.redact(text, level: .export)
        #expect(!exported.contains("someone@example.com"))
        #expect(exported.contains("~/.android"))
        #expect(Redactor.redact(text).contains("someone@example.com"))
    }
}

@Suite("INI files")
struct INITests {
    @Test("Values keep '=' characters, e.g. base64 padding")
    func firstEqualsOnly() {
        let ini = INIFile(text: "grpc.token=abc==\nkey = spaced value ")
        #expect(ini["grpc.token"] == "abc==")
        #expect(ini["key"] == "spaced value")
    }

    @Test func preservesUnknownKeysCommentsAndOrder() {
        var ini = INIFile(text: "# comment\nhw.ramSize=2G\nunknown.key=keep\n\nhw.cpu.ncore=4\n")
        ini["hw.ramSize"] = "8192M"
        ini["hw.gpu.mode"] = "host"
        ini["hw.cpu.ncore"] = nil
        #expect(ini.text == "# comment\nhw.ramSize=8192M\nunknown.key=keep\n\nhw.gpu.mode=host\n")
    }

    @Test func booleans() {
        let ini = INIFile(text: "a=yes\nb=no\nc=true\nd=maybe")
        #expect(ini.bool("a") == true)
        #expect(ini.bool("b") == false)
        #expect(ini.bool("c") == true)
        #expect(ini.bool("d") == nil)
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
    }

    @Test func passesStandardInput() async throws {
        let result = try await runner.run(URL(fileURLWithPath: "/bin/cat"), [], input: Data("no\n".utf8))
        #expect(result.stdoutString == "no\n")
    }

    @Test func timesOut() async throws {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: .milliseconds(300))
        }
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = await task.result
        #expect(clock.now - start < .seconds(3))
    }

    @Test func reportsMissingExecutables() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        }
    }

    @Test func streamsLines() async throws {
        var lines: [ProcessOutputEvent] = []
        for try await event in runner.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'a\\nb'; echo c >&2"]) {
            lines.append(event)
        }
        #expect(lines.contains(.stdout("a")))
        #expect(lines.contains(.stdout("b")))
        #expect(lines.contains(.stderr("c")))
        #expect(lines.last == .exited(0))
    }

    @Test func environmentOverrides() async throws {
        let result = try await runner.with(environment: ["DD_TEST": "42"])
            .run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $DD_TEST"])
        #expect(result.stdoutString == "42\n")
    }
}

@Suite("Host and ports")
struct HostTests {
    @Test func hostFactsAreSane() {
        let host = HostEnvironment.current()
        #expect(host.physicalMemory.value > 1024)
        #expect(host.logicalCPUs >= 1)
        #if arch(arm64)
        #expect(host.architecture == .arm64)
        #expect(!host.isTranslated)
        #else
        // An Intel build running on Apple Silicon (Rosetta) must still report the real hardware,
        // so DroidDeck offers arm64 images, which are the only ones that run accelerated here.
        if HostEnvironment.sysctlInt("hw.optional.arm64") == 1 {
            #expect(host.architecture == .arm64)
            #expect(host.isTranslated)
        } else {
            #expect(host.architecture == .x86_64)
        }
        #endif
    }

    @Test func memorySnapshot() {
        let snapshot = HostMemorySnapshot.sample()
        #expect(snapshot.total > 0)
        #expect(snapshot.used > 0 && snapshot.used <= snapshot.total)
    }

    @Test func processMetricsForSelf() async throws {
        let sampler = ProcessMetricsSampler()
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try #require(sampler.sample(pid: pid))
        #expect(first.footprintBytes > 0)
        #expect(first.cpuPercent == nil)
        var x = 0.0
        for i in 0..<2_000_000 { x += sqrt(Double(i)) }
        #expect(x > 0)
        let second = try #require(sampler.sample(pid: pid))
        #expect((second.cpuPercent ?? -1) >= 0)
        #expect(sampler.sample(pid: 999_999) == nil)
    }

    @Test func occupiedPortsAreNotFree() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(!PortAllocator.isFree(port))
    }

    @Test func consolePortsAreEvenPairs() throws {
        let pair = try #require(PortAllocator.consolePortPair(excluding: []))
        #expect(pair.console % 2 == 0)
        #expect(pair.adb == pair.console + 1)
        #expect((5554...5682).contains(pair.console))
    }
}

@Suite("Safe file operations")
struct FileOpsTests {
    @Test func refusesToDeleteOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dd-root-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appending(path: "dd-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        #expect(throws: DroidDeckError.self) {
            try SafeFileOperations.remove(root.appending(path: "../\(outside.lastPathComponent)"), within: root, useTrash: false)
        }
        #expect(throws: DroidDeckError.self) {
            try SafeFileOperations.remove(root, within: root, useTrash: false)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let inner = root.appending(path: "inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try SafeFileOperations.remove(inner, within: root, useTrash: false)
        #expect(!FileManager.default.fileExists(atPath: inner.path))
    }
}
