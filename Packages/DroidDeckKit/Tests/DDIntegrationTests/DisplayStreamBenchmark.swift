import Foundation
import Testing
import Darwin
@testable import DDServices
import DDRuntime
import DDEmulatorGRPC

/// Opt in: `DROIDDECK_STREAM_BENCH=<avd name> swift test --filter DisplayStreamBenchmark`, with that device
/// running and its screen animating. Compares in-band gRPC frames with the shared-memory (MMAP) transport.
@Suite("Display stream benchmark", .enabled(if: ProcessInfo.processInfo.environment["DROIDDECK_STREAM_BENCH"] != nil))
struct DisplayStreamBenchmark {
    static func cpuSeconds(pid: Int32) -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        guard ok == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    @Test func sharedMemoryVersusInBand() async throws {
        let name = ProcessInfo.processInfo.environment["DROIDDECK_STREAM_BENCH"]!
        let instance = try #require(EmulatorDiscovery.runningInstances().first { $0.avdName == name || $0.avdDirectory?.lastPathComponent == name + ".avd" })
        let client = EmulatorControllerClient(port: UInt16(try #require(instance.grpcPort)), token: instance.grpcToken)
        for shared in [false, true, false, true] {
            let session = DisplaySession(controller: client)
            let stream = await session.frames(maxWidth: 860, maxHeight: 1920, sharedMemory: shared)
            let selfStart = Self.cpuSeconds(pid: getpid()), emuStart = Self.cpuSeconds(pid: instance.pid)
            let clock = ContinuousClock(), start = clock.now
            var frames = 0
            for await result in stream {
                if case .success = result { frames += 1 }
                if clock.now - start > .seconds(6) { break }
            }
            await session.cancel()
            let elapsed = Double((clock.now - start).components.seconds)
            let me = (Self.cpuSeconds(pid: getpid()) - selfStart) / elapsed * 100
            let emu = (Self.cpuSeconds(pid: instance.pid) - emuStart) / elapsed * 100
            print(String(format: "BENCH %@: %.0f fps, DroidDeck side %.0f%% CPU, emulator %.0f%% CPU",
                         shared ? "shared memory" : "in-band gRPC ", Double(frames) / elapsed, me, emu))
            #expect(frames > 0)
        }
    }
}
