import Foundation

/// The loopback technique LocalDevVPN uses (SideStore StosVPN/LocalDevVPN,
/// `TunnelProv/PacketTunnelProvider.swift` @ 8a97427; StosVPN License, see
/// ../THIRD_PARTY_NOTICES.md): only the peer /32 is routed into the utun, and
/// each IPv4 packet read from it is written back with source and destination
/// swapped. A connection to `peer:62078` from `iface` re-enters the stack as
/// `peer -> iface`, i.e. addressed to this device's own tunnel interface,
/// where lockdownd accepts it; replies take the same path back. Swapping the
/// two address words leaves the IPv4 header checksum and the TCP/UDP
/// pseudo-header checksums valid (one's-complement sums are order-independent).
///
/// Independently written. Unlike upstream, anything that is not exactly
/// `iface -> peer` IPv4 is not reflected (the caller drops it), so the tunnel
/// cannot be used to inject traffic with arbitrary addresses.
enum IPv4Reflector {
    enum Verdict: Equatable { case reflected, notIPv4, malformed, foreignAddresses }

    /// Swaps source/destination in place when `packet` is a well-formed IPv4
    /// packet from `iface` to `peer` (both network-order dotted quads as UInt32).
    static func reflect(_ packet: inout Data, iface: UInt32, peer: UInt32) -> Verdict {
        guard packet.count >= 20 else { return .malformed }
        let base = packet.startIndex
        let vihl = packet[base]
        guard vihl >> 4 == 4 else { return .notIPv4 }
        let headerLength = Int(vihl & 0x0f) * 4
        let totalLength = Int(packet[base + 2]) << 8 | Int(packet[base + 3])
        guard headerLength >= 20, totalLength >= headerLength, packet.count >= totalLength else { return .malformed }
        guard word(packet, base + 12) == iface, word(packet, base + 16) == peer else { return .foreignAddresses }
        for i in 0..<4 { packet.swapAt(base + 12 + i, base + 16 + i) }
        return .reflected
    }

    /// "a.b.c.d" -> big-endian word, nil if not a dotted quad.
    static func address(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 << 8 | UInt32($1!) }
    }

    private static func word(_ d: Data, _ i: Data.Index) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}
