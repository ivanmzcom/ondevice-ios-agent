// SYNTHETIC host test for Tunnel/IPv4Reflector.swift (no NetworkExtension, no device).
// swiftc ../Tunnel/IPv4Reflector.swift main.swift -o <scratch>/reflector && <scratch>/reflector
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

func checksum(_ d: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for i in stride(from: 0, to: d.count, by: 2) { sum += UInt32(d[i]) << 8 | UInt32(i + 1 < d.count ? d[i + 1] : 0) }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

let iface = IPv4Reflector.address("10.7.1.1")!, peer = IPv4Reflector.address("10.7.0.1")!
// 20-byte IPv4 header + 20-byte TCP SYN to port 62078, iface -> peer.
var header: [UInt8] = [0x45, 0, 0, 40, 0x12, 0x34, 0x40, 0, 64, 6, 0, 0, 10, 7, 1, 1, 10, 7, 0, 1]
let c = checksum(header)
header[10] = UInt8(c >> 8); header[11] = UInt8(c & 0xff)
let tcp: [UInt8] = [0xc3, 0x50, 0xf2, 0x7e] + [UInt8](repeating: 0, count: 16)
var packet = Data(header + tcp)

check(IPv4Reflector.address("10.7.0.1") == 0x0a07_0001, "dotted quad parses big-endian")
check(IPv4Reflector.address("10.7.0") == nil && IPv4Reflector.address("10.7.0.256") == nil, "bad addresses rejected")
check(IPv4Reflector.reflect(&packet, iface: iface, peer: peer) == .reflected, "iface->peer packet is reflected")
check(Array(packet[12..<16]) == [10, 7, 0, 1] && Array(packet[16..<20]) == [10, 7, 1, 1], "source/destination swapped")
check(checksum(Array(packet[0..<20])) == 0, "IPv4 header checksum still valid after swap")
check(Array(packet[20...]) == tcp, "payload untouched")
check(IPv4Reflector.reflect(&packet, iface: iface, peer: peer) == .foreignAddresses, "reflected packet is not reflected again")

var foreign = Data(header + tcp); foreign[19] = 9
check(IPv4Reflector.reflect(&foreign, iface: iface, peer: peer) == .foreignAddresses, "other destination not reflected")
var v6 = Data([0x60] + [UInt8](repeating: 0, count: 39))
check(IPv4Reflector.reflect(&v6, iface: iface, peer: peer) == .notIPv4, "IPv6 not reflected")
var short = Data(header.prefix(12))
check(IPv4Reflector.reflect(&short, iface: iface, peer: peer) == .malformed, "truncated header rejected")
var lying = Data(header + tcp); lying[3] = 200
check(IPv4Reflector.reflect(&lying, iface: iface, peer: peer) == .malformed, "total length beyond buffer rejected")
var sliced = Data([0xff] + header + tcp).dropFirst()  // non-zero startIndex
check(IPv4Reflector.reflect(&sliced, iface: iface, peer: peer) == .reflected, "works on a Data slice")

print(failures == 0 ? "ALL PASSED (synthetic)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
