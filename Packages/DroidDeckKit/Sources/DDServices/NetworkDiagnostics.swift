import Foundation
import DDCore
import DDPlatform
import DDADB

/// Network facts measured on the Mac.
public struct HostNetworkReport: Sendable, Equatable {
    public var defaultInterface: String?
    /// Default route goes through a utun interface (system VPN or VPN app tunnel).
    public var defaultRouteIsTunnel: Bool
    /// VPN services macOS reports as connected (`scutil --nc list`).
    public var connectedVPNServices: [String]
    public var dnsServers: [String]
    public var publicIP: String?
    public var publicIPError: String?

    public var vpnActive: Bool { defaultRouteIsTunnel || !connectedVPNServices.isEmpty }
}

/// Network facts measured inside one Android device.
public struct DeviceNetworkReport: Sendable, Equatable {
    public var serial: String
    public var interfaces: [String]
    public var hasTunnelInterface: Bool
    /// A VPN network is registered with Android's ConnectivityService.
    public var vpnNetworkActive: Bool
    public var vpnOwnerPackage: String?
    public var activeTransports: [String]
    public var dnsServers: [String]
    public var privateDNSMode: String?
    public var installedVPNApps: [String]
    public var canReachInternet: Bool
    public var canResolveNames: Bool
    public var publicIP: String?
    public var publicIPError: String?

    public var vpnActive: Bool { vpnNetworkActive || hasTunnelInterface }
}

public struct NetworkVerdict: Sendable, Equatable {
    public enum Route: String, Sendable {
        case androidVPN = "VPN inside Android"
        case hostVPN = "Through the Mac's VPN"
        case androidAndHostVPN = "Android VPN over the Mac's VPN"
        case direct = "Direct (no VPN detected)"
        case unknown = "Undetermined"
    }

    public var route: Route
    public var statements: [String]
}

public enum NetworkDiagnostics {
    /// Packages of common VPN apps, used only to report what is installed.
    static let knownVPNPackages = [
        "com.nordvpn.android", "com.expressvpn.vpn", "com.surfshark.vpnclient.android", "net.mullvad.mullvadvpn",
        "com.protonvpn.android", "ch.protonvpn.android", "com.privateinternetaccess.android", "com.cloudflare.onedotonedotonedotone",
        "de.blinkt.openvpn", "net.openvpn.openvpn", "com.wireguard.android", "org.torproject.android",
    ]

    // MARK: Host

    public static func host(runner: ProcessRunner = ProcessRunner(), publicIPHost: String?) async -> HostNetworkReport {
        let route = try? await runner.run(URL(fileURLWithPath: "/sbin/route"), ["-n", "get", "default"], timeout: .seconds(10))
        let interface = route?.stdoutString.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }
            .map { $0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces) }
        let nc = try? await runner.run(URL(fileURLWithPath: "/usr/sbin/scutil"), ["--nc", "list"], timeout: .seconds(10))
        let connected = (nc?.stdoutString ?? "").split(separator: "\n")
            .filter { $0.contains("(Connected)") }
            .compactMap { line -> String? in
                guard let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
                return String(line[line.index(after: open)..<close])
            }
        let dns = try? await runner.run(URL(fileURLWithPath: "/usr/sbin/scutil"), ["--dns"], timeout: .seconds(10))
        var servers: [String] = []
        for line in (dns?.stdoutString ?? "").split(separator: "\n") where line.contains("nameserver[") {
            if let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !servers.contains(value) {
                servers.append(value)
            }
        }
        var report = HostNetworkReport(defaultInterface: interface, defaultRouteIsTunnel: interface?.hasPrefix("utun") ?? false,
                                       connectedVPNServices: connected, dnsServers: Array(servers.prefix(4)))
        if let publicIPHost {
            do {
                report.publicIP = try await hostPublicIP(host: publicIPHost)
            } catch {
                report.publicIPError = error.localizedDescription
            }
        }
        return report
    }

    static func hostPublicIP(host: String) async throws -> String {
        guard let url = URL(string: "https://\(host)") else { throw DroidDeckError(.network, "Invalid service host.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DroidDeckError(.network, "Unexpected response.") }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPAddress(text) else { throw DroidDeckError(.network, "The service did not return an IP address.") }
        return text
    }

    static func isIPAddress(_ text: String) -> Bool {
        let v4 = text.split(separator: ".")
        if v4.count == 4, v4.allSatisfy({ UInt8($0) != nil }) { return true }
        return text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    // MARK: Device

    public static func device(serial: String, adb: ADBClient, publicIPHost: String?) async -> DeviceNetworkReport {
        let links = (try? await adb.shell(serial, "ip -o link show", timeout: .seconds(15), allowFailure: true)) ?? ""
        let interfaces = links.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 2)
            return parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: "@").first : nil
        }
        let connectivity = (try? await adb.shell(serial, "dumpsys connectivity", timeout: .seconds(30), allowFailure: true)) ?? ""
        let parsed = parseConnectivity(connectivity)
        var owner: String?
        if let uid = parsed.vpnOwnerUID {
            let packages = (try? await adb.shell(serial, "cmd package list packages --uid \(uid)", timeout: .seconds(15), allowFailure: true)) ?? ""
            owner = packages.split(separator: "\n").first.flatMap { $0.split(separator: " ").first }
                .map { String($0).replacingOccurrences(of: "package:", with: "") }
        }
        let privateDNS = (try? await adb.shell(serial, "settings get global private_dns_mode", timeout: .seconds(10), allowFailure: true))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = (try? await adb.packages(serial, thirdPartyOnly: true)) ?? []
        let ping = (try? await adb.shell(serial, "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo ok", timeout: .seconds(10), allowFailure: true)) ?? ""
        let resolve = (try? await adb.shell(serial, "ping -c 1 -W 3 dns.google >/dev/null 2>&1 && echo ok", timeout: .seconds(10), allowFailure: true)) ?? ""

        var report = DeviceNetworkReport(
            serial: serial, interfaces: interfaces,
            hasTunnelInterface: interfaces.contains { $0.hasPrefix("tun") || $0.hasPrefix("wg") || $0.hasPrefix("ppp") },
            vpnNetworkActive: parsed.vpnActive, vpnOwnerPackage: owner, activeTransports: parsed.defaultTransports,
            dnsServers: parsed.dnsServers, privateDNSMode: privateDNS == "null" ? "off (default)" : privateDNS,
            installedVPNApps: installed.filter { knownVPNPackages.contains($0) },
            canReachInternet: ping.contains("ok"), canResolveNames: resolve.contains("ok")
        )
        if let publicIPHost {
            // Plain HTTP over toybox nc: no curl/wget on stock images. Only the IP echo service is contacted.
            let command = "printf 'GET / HTTP/1.1\\r\\nHost: \(publicIPHost)\\r\\nConnection: close\\r\\n\\r\\n' | nc -w 8 \(publicIPHost) 80 | tail -1"
            let output = (try? await adb.shell(serial, command, timeout: .seconds(20), allowFailure: true))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isIPAddress(output) { report.publicIP = output } else { report.publicIPError = "No response from \(publicIPHost)" }
        }
        return report
    }

    struct ConnectivitySummary: Equatable {
        var vpnActive = false
        var vpnOwnerUID: String?
        var defaultTransports: [String] = []
        var dnsServers: [String] = []
    }

    /// Parses `dumpsys connectivity`. NetworkAgentInfo lines carry transports, DNS and owner UID.
    static func parseConnectivity(_ text: String) -> ConnectivitySummary {
        var summary = ConnectivitySummary()
        for line in text.split(separator: "\n") where line.contains("NetworkAgentInfo{") {
            let transports = firstMatch(#"Transports: ([A-Z_|]+)"#, in: line)?.split(separator: "|").map(String.init) ?? []
            if transports.contains("VPN") {
                summary.vpnActive = true
                summary.vpnOwnerUID = firstMatch(#"OwnerUid: (\d+)"#, in: line)
            }
            if summary.defaultTransports.isEmpty || transports.contains("VPN") {
                summary.defaultTransports = transports
                if let dns = firstMatch(#"DnsAddresses: \[ ([^\]]*)\]"#, in: line) {
                    summary.dnsServers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "") }
                        .filter { !$0.isEmpty }
                }
            }
        }
        return summary
    }

    private static func firstMatch(_ pattern: String, in line: Substring) -> String? {
        let text = String(line)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Interpretation

    /// States only what was measured. Never claims isolation that was not demonstrated.
    public static func verdict(host: HostNetworkReport, device: DeviceNetworkReport) -> NetworkVerdict {
        var statements: [String] = []
        let route: NetworkVerdict.Route
        switch (device.vpnActive, host.vpnActive) {
        case (true, true): route = .androidAndHostVPN
        case (true, false): route = .androidVPN
        case (false, true): route = .hostVPN
        case (false, false): route = .direct
        }
        if device.vpnActive {
            statements.append("Android reports an active VPN\(device.vpnOwnerPackage.map { " owned by \($0)" } ?? "").")
        } else if !device.installedVPNApps.isEmpty {
            statements.append("\(device.installedVPNApps.joined(separator: ", ")) is installed but no VPN is active inside Android.")
        }
        if host.vpnActive {
            statements.append("The Mac's default route uses \(host.defaultInterface ?? "a tunnel")\(host.connectedVPNServices.isEmpty ? "" : " (\(host.connectedVPNServices.joined(separator: ", ")))"). Emulator traffic is NATed through the Mac, so it passes through this VPN\(device.vpnActive ? " underneath the Android VPN" : "").")
        }
        if let d = device.publicIP, let h = host.publicIP {
            statements.append(d == h
                ? "The device and the Mac currently appear on the internet with the same public IP (\(d))."
                : "The device's public IP (\(d)) differs from the Mac's (\(h)).")
        }
        if !device.canReachInternet { statements.append("The device could not reach 8.8.8.8.") }
        if device.canReachInternet && !device.canResolveNames { statements.append("The device reached the internet but could not resolve names (DNS failure).") }
        if let mode = device.privateDNSMode, mode != "off (default)", mode != "off" {
            statements.append("Android Private DNS is set to \(mode).")
        }
        return NetworkVerdict(route: route, statements: statements)
    }

    /// Compares several devices measured in the same run. Distinct public IPs at the time of the test are
    /// evidence of separate egress, not proof of ongoing isolation (DNS, IPv6 and reconnection can still leak).
    public static func comparison(_ reports: [DeviceNetworkReport]) -> [String] {
        guard reports.count > 1 else { return [] }
        let ips = reports.compactMap(\.publicIP)
        guard ips.count == reports.count else {
            return ["Public IPs could not be measured for every device, so egress separation is unverified."]
        }
        if Set(ips).count == ips.count {
            var lines = ["During this test each device used a different public IP."]
            if !reports.allSatisfy(\.vpnActive) {
                lines.append("Not every device had an Android VPN active; differences may come from the network, not from per-device VPNs.")
            }
            lines.append("This is a point-in-time measurement. Re-test after reconnects; DNS and IPv6 paths are not covered by this check.")
            return lines
        }
        return ["Some devices share a public IP (\(Set(ips.filter { ip in ips.filter { $0 == ip }.count > 1 }).joined(separator: ", "))). Their traffic is not separated."]
    }
}

/// Watches a device's VPN state over time to observe disconnects and reconnects.
public struct VPNStateSample: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var vpnActive: Bool
    public var owner: String?
}

public enum VPNMonitor {
    public static func samples(serial: String, adb: ADBClient, interval: Duration = .seconds(5)) -> AsyncStream<VPNStateSample> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let text = (try? await adb.shell(serial, "dumpsys connectivity", timeout: .seconds(20), allowFailure: true)) ?? ""
                    let summary = NetworkDiagnostics.parseConnectivity(text)
                    continuation.yield(VPNStateSample(date: Date(), vpnActive: summary.vpnActive, owner: summary.vpnOwnerUID))
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
