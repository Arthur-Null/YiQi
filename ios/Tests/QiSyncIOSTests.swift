import CryptoKit
import Foundation
import XCTest

// C2, C3, C5, C7: iOS 端加密协议、临时密码密钥交换、服务器地址解析与输入方式状态测试。
final class QiSyncIOSTests: XCTestCase {
    func testServerURLNormalization() {
        XCTAssertEqual(QiPairing.serverURL("yiqi.example.com")?.absoluteString, "wss://yiqi.example.com/v1/ws")
        XCTAssertEqual(QiPairing.serverURL("https://yiqi.example.com")?.absoluteString, "wss://yiqi.example.com/v1/ws")
        XCTAssertEqual(QiPairing.serverURL("http://127.0.0.1:8080")?.absoluteString, "ws://127.0.0.1:8080/v1/ws")
        XCTAssertNil(QiPairing.serverURL("   "))
    }

    func testClipSealAndOpenLongText() throws {
        let url = try XCTUnwrap(QiPairing.serverURL("yiqi.example.com"))
        let k = QiKey(server: url)
        let parsed = try XCTUnwrap(QiKey(pairCode: k.pairCode))
        XCTAssertEqual(parsed.authToken, k.authToken)
        XCTAssertEqual(parsed.verifier, k.verifier)

        let longText = String(repeating: "单网页长文本与敏感信息 sk-secret-key-999。\n", count: 400)
        let clip = QiClip(id: "c1", from: "mac", ts: 123456, text: longText)
        let sealed = try k.seal(clip)
        XCTAssertFalse(sealed.contains("sk-secret-key"))
        let opened = try parsed.open(sealed)
        XCTAssertEqual(opened, clip)

        let foreign = QiKey(server: url)
        XCTAssertThrowsError(try foreign.open(sealed))
    }

    func testJoinKeyExchangeWithCode() throws {
        let url = try XCTUnwrap(QiPairing.serverURL("yiqi.example.com"))
        let groupKey = QiKey(server: url)
        let joiner = P256.KeyAgreement.PrivateKey()
        let peerB64 = joiner.publicKey.x963Representation.base64EncodedString()
        let reply = try QiPairing.sealGroupKey(peer: peerB64, code: "482910", key: groupKey)

        let recovered = try QiPairing.openGroupKey(priv: joiner, reply: reply, code: "482910")
        XCTAssertEqual(recovered, groupKey.raw)
        XCTAssertThrowsError(try QiPairing.openGroupKey(priv: joiner, reply: reply, code: "000000"))
    }

    func testSchemeAndHotkeyPersistence() {
        QiStore.requestScheme(.quanpin)
        XCTAssertEqual(QiStore.scheme, .quanpin)
        QiStore.requestScheme(.flypy)
        XCTAssertEqual(QiStore.scheme, .flypy)

        let hk = QiHotkey(rime: ["Control+Alt+k"], label: "Ctrl + Alt + K")
        QiStore.setHotkey(hk)
        XCTAssertEqual(QiStore.hotkey, hk)
        QiStore.setHotkey(QiStore.defaultHotkey)
    }
}
