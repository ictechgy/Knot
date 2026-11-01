import Foundation
import Testing
@testable import KnotNativeCore

@Test func shortCodeCryptoBridgeProvidesMutualConfirmation() throws {
    let slot = Data(repeating: 0x35, count: 16), number = Data("01234567".utf8)
    let client = try PairingCryptoSession(server: false, password: number, slot: slot)
    let server = try PairingCryptoSession(server: true, password: number, slot: slot)
    defer { client.close(); server.close() }
    #expect(client.message.count == 32 && server.message.count == 32)
    try client.process(server.message); try server.process(client.message)
    let confirmation = Data("fresh synthetic client confirmation".utf8)
    let sealed = try client.seal(kind: 3, plaintext: confirmation)
    #expect(try server.open(kind: 3, sealed: sealed) == confirmation)
    let offer = Data(repeating: 0x5a, count: 3072)
    let envelope = try server.seal(kind: 4, plaintext: offer)
    #expect(try client.open(kind: 4, sealed: envelope) == offer)
    #expect(throws: NativeFailure.malformed) { try client.open(kind: 4, sealed: envelope) }
}

@Test func shortCodeCryptoBridgeRejectsWrongNumberAndClosedContext() throws {
    let slot = Data(repeating: 0x23, count: 16)
    let client = try PairingCryptoSession(server: false, password: Data("01234567".utf8), slot: slot)
    let server = try PairingCryptoSession(server: true, password: Data("01234568".utf8), slot: slot)
    defer { client.close(); server.close() }
    try client.process(server.message); try server.process(client.message)
    let sealed = try client.seal(kind: 3, plaintext: Data("fresh synthetic proof".utf8))
    #expect(throws: NativeFailure.malformed) { try server.open(kind: 3, sealed: sealed) }
    #expect(throws: NativeFailure.malformed) { try server.process(client.message) }
    client.close(); client.close()
    #expect(throws: NativeFailure.malformed) { try client.process(server.message) }
}
