// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

func runSetupExchangeChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }; count += 1
    }
    let prefix: [UInt8] = [0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32]
    let client = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    let server = "ssh-ed25519 " + Data(prefix + Array(repeating: UInt8(2), count: 32)).base64EncodedString()
    let request = try SetupExchange.request(clientPublicKey: client + " synthetic", addresses: ["192.168.1.10", "100.80.10.20"])
    let encoded = try SetupExchange.encode(request)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    try expect(object["kind"] as? String == "deskbridge.mac-setup", "setup kind")
    try expect(object.count == 5 && object["clientPublicKey"] as? String == client, "public-only request")
    try expect(UUID(uuidString: request.requestID) != nil, "unique request identifier")
    for addresses in [[], ["8.8.8.8"], ["192.168.1.10", "192.168.1.10"], Array(repeating: "192.168.1.10", count: 9)] {
        do { _ = try SetupExchange.request(clientPublicKey: client, addresses: addresses); throw CheckFailure(message: "bad setup addresses") }
        catch is CheckFailure { throw CheckFailure(message: "bad setup addresses accepted") }
        catch { count += 1 }
    }
    for key in ["ssh-rsa AAAA", "ssh-ed25519 AAAA", client + "\nInjected", "-----BEGIN PRIVATE KEY-----"] {
        do { _ = try SetupExchange.request(clientPublicKey: key, addresses: ["10.0.0.1"]); throw CheckFailure(message: "bad client key") }
        catch is CheckFailure { throw CheckFailure(message: "bad client key accepted") }
        catch { count += 1 }
    }
    let reply: [String: Any] = ["kind":"deskbridge.windows-connection", "version":1, "requestID":request.requestID,
        "clientPublicKey":client, "address":"100.80.10.30", "port":22, "username":"deskbridge-transfer", "serverPublicKey":server]
    let data = try JSONSerialization.data(withJSONObject: reply)
    let preview = try SetupExchange.preview(data, clientPublicKey: client)
    try expect(preview.reply.address == "100.80.10.30" && preview.fingerprint.hasPrefix("SHA256:"), "validated preview")
    do { _ = try SetupExchange.preview(data, clientPublicKey: server); throw CheckFailure(message: "wrong Mac key accepted") }
    catch SetupExchange.Failure.wrongClient { count += 1 }
    for (key, value) in [("version",2 as Any),("kind","other" as Any),("requestID","invalid" as Any),
                         ("address","8.8.8.8" as Any),("address"," 10.0.0.1" as Any),("port",2222 as Any),
                         ("username","administrator" as Any),("serverPublicKey","ssh-ed25519 AAAA" as Any),
                         ("command","whoami" as Any)] {
        var invalid = reply; invalid[key] = value
        do { _ = try SetupExchange.preview(JSONSerialization.data(withJSONObject: invalid), clientPublicKey: client); throw CheckFailure(message: "bad reply " + key) }
        catch is CheckFailure { throw CheckFailure(message: "bad reply accepted " + key) }
        catch { count += 1 }
    }
    var missing = reply; missing.removeValue(forKey: "clientPublicKey")
    do { _ = try SetupExchange.preview(JSONSerialization.data(withJSONObject: missing), clientPublicKey: client); throw CheckFailure(message: "missing field") }
    catch is CheckFailure { throw CheckFailure(message: "missing field accepted") }
    catch { count += 1 }
    do { _ = try SetupExchange.preview(Data(repeating: 32, count: 16_385), clientPublicKey: client); throw CheckFailure(message: "oversized reply") }
    catch SetupExchange.Failure.invalid { count += 1 }
    let eligible = (1...10).map { "10.0.0.\($0)" }
    let suggestions = SetupExchange.suggestAddresses(eligible + ["10.0.0.1", "169.254.1.2", "8.8.8.8", "pc.local", "::1"])
    try expect(suggestions.addresses.count == 8 && suggestions.omittedCount == 2, "automatic suggestions fit the export address limit")
    try expect(SetupExchange.suggestAddresses(Array(eligible.reversed())) == suggestions, "suggestion choice is deterministic")
    try expect(suggestions.addresses == Array(eligible.prefix(8)), "numeric octets are sorted before the cap")
    let crowded = eligible + ["100.80.10.20", "172.16.1.20", "192.168.1.20"]
    let diverse = SetupExchange.suggestAddresses(crowded)
    try expect(Set(["100.80.10.20", "172.16.1.20", "192.168.1.20"]).isSubset(of: Set(diverse.addresses)) && diverse.addresses.count == 8 && diverse.omittedCount == 5, "one VPN range cannot exclude LAN and Tailscale suggestions")
    try expect(SetupExchange.suggestAddresses(Array(crowded.reversed())) == diverse, "range selection is independent of interface order")
    try expect(SetupExchange.suggestAddresses([]).addresses.isEmpty, "empty network has no invented address")
    try expect(SetupExchange.suggestAddresses(["169.254.1.2", "8.8.8.8", "pc.local", "::1"]).addresses.isEmpty, "automatic suggestions exclude unusable/private-policy exceptions")
    try expect(SetupExchange.suggestAddresses(["100.80.10.20"]).addresses == ["100.80.10.20"], "one Tailscale address is retained")
    try expect(SetupExchange.suggestAddresses(Array(eligible.prefix(8))).omittedCount == 0, "exactly eight suggestions need no omission")
    _ = try SetupExchange.request(clientPublicKey: client, addresses: suggestions.addresses)
    count += 1
    // Manual advanced link-local entry retains the existing explicit policy.
    _ = try SetupExchange.request(clientPublicKey: client, addresses: ["169.254.1.2"])
    count += 1
    do { _ = try SetupExchange.request(clientPublicKey: client, addresses: eligible); throw CheckFailure(message: "address count error missing") }
    catch SetupExchange.Failure.addressCount { count += 1 }
    do { _ = try SetupExchange.request(clientPublicKey: client, addresses: ["192.168.1.20", "192.168.1.20"]); throw CheckFailure(message: "duplicate address guidance missing") }
    catch SetupExchange.Failure.duplicateAddress { count += 1 }
    do { _ = try SetupExchange.canonicalKey("ssh-rsa synthetic"); throw CheckFailure(message: "Mac key error missing") }
    catch SetupExchange.Failure.invalidClientKey { count += 1 }
    return count
}
