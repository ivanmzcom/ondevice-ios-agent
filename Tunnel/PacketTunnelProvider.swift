// Based on the loopback tunnel technique of LocalDevVPN / StosVPN
// (Copyright (c) 2025 SideStore Team, StosVPN License; consulted at
// https://github.com/seomin0610/LocalDevVPN @ 8a97427). See
// ../licenses/LocalDevVPN-StosVPN.txt and ../THIRD_PARTY_NOTICES.md.

import NetworkExtension
import os

/// On-device loopback tunnel: routes only `peer/32` into the utun and reflects
/// it back (IPv4Reflector). No remote server, no default route, no DNS.
/// Started only by the host app's explicit Start button (no on-demand rules).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let ifaceKey = "ifaceIP", peerKey = "peerIP"
    static let defaultIface = "10.7.1.1", defaultPeer = "10.7.0.1"

    private let log = Logger(subsystem: "dev.spike.unifiedagent", category: "tunnel")
    private var iface: UInt32 = 0, peer: UInt32 = 0
    private var running = false
    private var dropped = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let ifaceString = config[Self.ifaceKey] as? String ?? Self.defaultIface
        let peerString = config[Self.peerKey] as? String ?? Self.defaultPeer
        guard let iface = IPv4Reflector.address(ifaceString), let peer = IPv4Reflector.address(peerString),
              iface != peer else {
            return completionHandler(NEVPNError(.configurationInvalid))
        }
        self.iface = iface
        self.peer = peer

        let ipv4 = NEIPv4Settings(addresses: [ifaceString], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peerString, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerString)  // display only
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                return completionHandler(error)
            }
            self.running = true
            self.readLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        log.info("stopTunnel reason=\(reason.rawValue, privacy: .public) dropped=\(self.dropped, privacy: .public)")
        completionHandler()
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }
            var out: [Data] = [], outProtocols: [NSNumber] = []
            for (packet, proto) in zip(packets, protocols) where proto.int32Value == AF_INET {
                var p = packet
                if IPv4Reflector.reflect(&p, iface: self.iface, peer: self.peer) == .reflected {
                    out.append(p)
                    outProtocols.append(proto)
                }
            }
            self.dropped += packets.count - out.count
            if !out.isEmpty { self.packetFlow.writePackets(out, withProtocols: outProtocols) }
            self.readLoop()
        }
    }
}
