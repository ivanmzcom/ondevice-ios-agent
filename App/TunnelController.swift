import Foundation
import NetworkExtension

/// Explicit, user-triggered management of this app's own packet-tunnel
/// configuration. Safe default: nothing is installed or started on launch, and
/// on-demand is always off.
@MainActor final class TunnelController: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError = ""

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    static var providerBundleID: String { (Bundle.main.bundleIdentifier ?? "dev.spike.unifiedagent.app") + ".tunnel" }

    var statusText: String {
        switch status {
        case .invalid: installed ? "invalid" : "not installed"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    /// Reads existing preferences only; never creates or starts anything.
    func refresh() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
            }
            installed = manager != nil
            observe()
        } catch {
            fail("load preferences", error)
        }
    }

    /// Saves the configuration (iOS asks the user to allow adding a VPN).
    func install() async {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "\(PacketTunnelKeys.defaultPeer) (on-device loopback)"
        proto.providerConfiguration = [PacketTunnelKeys.iface: PacketTunnelKeys.defaultIface,
                                       PacketTunnelKeys.peer: PacketTunnelKeys.defaultPeer]
        m.protocolConfiguration = proto
        m.localizedDescription = "Unified Agent loopback"
        m.isEnabled = true
        m.isOnDemandEnabled = false
        do {
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            manager = m
            installed = true
            lastError = ""
            observe()
        } catch {
            fail("save configuration", error)
        }
    }

    func start() {
        guard let manager else { return lastError = "install the configuration first" }
        do {
            try manager.connection.startVPNTunnel()
            lastError = ""
        } catch {
            fail("start", error)
        }
    }

    func stop() { manager?.connection.stopVPNTunnel() }

    func remove() async {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        do {
            try await manager.removeFromPreferences()
            self.manager = nil
            installed = false
            status = .invalid
        } catch {
            fail("remove", error)
        }
    }

    private func observe() {
        status = manager?.connection.status ?? .invalid
        guard observer == nil, let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.statusChanged() }
        }
    }

    private func statusChanged() async {
        guard let connection = manager?.connection else { return }
        status = connection.status
        guard status == .disconnected else { return }
        do {
            try await connection.fetchLastDisconnectError()  // the async form throws the last error, if any
        } catch {
            fail("tunnel stopped", error)
        }
    }

    private func fail(_ what: String, _ error: Error) {
        let e = error as NSError
        lastError = "\(what): \(e.localizedDescription) (\(e.domain) \(e.code))"
    }
}

/// Keys shared with Tunnel/PacketTunnelProvider.swift (separate module).
enum PacketTunnelKeys {
    static let iface = "ifaceIP", peer = "peerIP"
    static let defaultIface = "10.7.1.1", defaultPeer = "10.7.0.1"
}
