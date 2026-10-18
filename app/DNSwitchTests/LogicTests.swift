// Pure-logic tests (docs/12 §6 S03). This bundle compiles the App's non-UI
// sources directly and has NO test host: running it never launches DNSwitch,
// never registers or heals the launchd service, and never opens the engine
// socket. In this process Bundle.main is the test runner, so String(localized:)
// returns the key itself — the error-text tests assert on keys, and a separate
// test checks those keys exist in both Localizable.strings files (read from the
// source tree via #filePath, so run the bundle where it was built).
// ServiceManager() reads SMAppService's status once (read-only, an XPC round
// trip that finds nothing for this process); AppModel() writes its one-time
// migration key into the test runner's own defaults domain.
import ServiceManagement
import XCTest

final class BuildVersionTests: XCTestCase {
    func testParsesMarketingAndBuild() {
        let v = BuildVersion("0.18 (18)")
        XCTAssertEqual(v?.marketing, [0, 18])
        XCTAssertEqual(v?.build, 18)
        XCTAssertEqual(BuildVersion("0.18")?.build, nil)
        XCTAssertEqual(BuildVersion(" 1.2.3 (45) ")?.marketing, [1, 2, 3])
    }

    func testRejectsGarbage() {
        for s in ["dev", "", "0.18 (x)", "0..18", "0.18 ()", "v0.18", "0.18 (18", "0.18-beta"] {
            XCTAssertNil(BuildVersion(s), s)
        }
    }

    func testIsAtLeast() {
        let v18 = BuildVersion("0.18 (18)")!
        XCTAssertTrue(BuildVersion("0.18 (18)")!.isAtLeast(v18))
        XCTAssertTrue(BuildVersion("0.19 (19)")!.isAtLeast(v18))
        XCTAssertFalse(BuildVersion("0.17 (17)")!.isAtLeast(v18))
        // Build numbers win when both sides have one.
        XCTAssertTrue(BuildVersion("0.18 (20)")!.isAtLeast(BuildVersion("0.19 (19)")!))
        // Otherwise marketing segments, a missing one counting as 0.
        XCTAssertTrue(BuildVersion("0.18")!.isAtLeast(BuildVersion("0.18.0")!))
        XCTAssertTrue(BuildVersion("0.18.1")!.isAtLeast(BuildVersion("0.18")!))
        XCTAssertFalse(BuildVersion("0.9")!.isAtLeast(BuildVersion("0.18")!))
    }
}

@MainActor
final class ModelPredicateTests: XCTestCase {
    private func state(enabled: Bool = true, provider: String = "nextdns", proto: String = "doh",
                       id: String? = nil, version: String? = "0.18 (18)", restoreOwed: Bool? = nil) -> EngineState {
        EngineState(enabled: enabled, provider: provider, proto: proto, id: id, device: nil, upstream: "u",
                    listening: true, pinned: enabled, engineVersion: version, dnsproxyVersion: "v0.85.0",
                    restoreOwed: restoreOwed)
    }

    func testEngineSupportsControlD() {
        let m = AppModel()
        m.connected = false
        XCTAssertTrue(engineSupportsControlD(m), "nothing greyed while unreachable")
        m.connected = true
        for (v, want) in [("0.18 (18)", true), ("0.19 (19)", true), ("0.17 (17)", false), ("dev", false)] {
            m.state = state(version: v)
            XCTAssertEqual(engineSupportsControlD(m), want, v)
        }
        m.state = state(version: nil)
        XCTAssertFalse(engineSupportsControlD(m), "no version reported = too old")
    }

    func testEngineReportsRestore() {
        let m = AppModel()
        for (v, want) in [("0.15 (15)", true), ("0.18 (18)", true), ("0.14 (14)", false), ("dev", false)] {
            m.state = state(version: v)
            XCTAssertEqual(engineReportsRestore(m), want, v)
        }
        m.state = nil
        XCTAssertFalse(engineReportsRestore(m))
    }

    func testEncryptionActiveTruthTable() {
        let m = AppModel()
        let s = ServiceManager()
        for enabled in [false, true] {
            for connected in [false, true] {
                for svc in [SMStatusForTest.enabled, .notRegistered] {
                    for stalled in [false, true] {
                        m.state = state(enabled: enabled)
                        m.connected = connected
                        m.stalled = stalled
                        s.status = svc.status
                        let want = enabled && (connected || (svc == .enabled && !stalled))
                        XCTAssertEqual(encryptionActive(m, s), want,
                                       "enabled=\(enabled) connected=\(connected) service=\(svc) stalled=\(stalled)")
                    }
                }
            }
        }
        m.state = nil
        m.connected = true
        XCTAssertFalse(encryptionActive(m, s), "no state yet = off")
    }

    func testSelectProviderFallsBackToDoH() {
        let m = AppModel()
        m.selectedProto = .doq
        m.selectProvider("google")
        XCTAssertEqual(m.selectedProvider, "google")
        XCTAssertEqual(m.selectedProto, .doh, "Google has no DoQ")
        m.selectedProto = .doh3
        m.selectProvider("cloudflare")
        XCTAssertEqual(m.selectedProto, .doh3, "a supported protocol is kept")
        m.selectedProto = .doq
        m.selectProvider("nextdns")
        XCTAssertEqual(m.selectedProto, .doq)
    }
}

/// SMAppService.Status values the truth table uses, named for readable failures.
enum SMStatusForTest: CustomStringConvertible {
    case enabled, notRegistered
    var status: SMAppService.Status { self == .enabled ? .enabled : .notRegistered }
    var description: String { self == .enabled ? "enabled" : "notRegistered" }
}

@MainActor
final class DescribeErrorTests: XCTestCase {
    private func d(_ code: String, field: String? = nil) -> String {
        AppModel.describe(EngineError(code: code, msg: "m"), field: field)
    }

    func testCodesMapToKeys() {
        XCTAssertEqual(d("upstream_unreachable"), "error.unreachable")
        XCTAssertEqual(d("upstream_unreachable", field: "F"), "error.unreachableCheckField")
        XCTAssertEqual(d("invalid_id"), "error.invalidID")
        XCTAssertEqual(d("invalid_id", field: "F"), "error.invalidField")
        XCTAssertEqual(d("invalid_device"), "error.invalidDevice")
        XCTAssertEqual(d("unsupported_protocol"), "menu.provider.needsEngineRestart")
        XCTAssertEqual(d("unknown_provider"), "menu.provider.needsEngineRestart")
        XCTAssertEqual(d("closing"), "error.engineRestarting")
        XCTAssertEqual(d("something_new"), "error.generic", "unknown codes fall back to the generic text")
    }

    func testKeysExistInBothLanguages() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DNSwitch")
        for lang in ["en", "zh-Hans"] {
            let text = try String(contentsOf: app.appendingPathComponent("\(lang).lproj/Localizable.strings"), encoding: .utf8)
            for key in ["error.unreachable", "error.unreachableCheckField", "error.invalidID", "error.invalidField",
                        "error.invalidDevice", "menu.provider.needsEngineRestart", "error.engineRestarting", "error.generic"] {
                XCTAssertTrue(text.contains("\"\(key)\""), "\(key) missing in \(lang)")
            }
        }
    }
}

final class LoopbackTests: XCTestCase {
    func testLoopbackListing() {
        XCTAssertTrue(SystemDNSProbe.isLoopbackListing("127.0.0.1\n"))
        XCTAssertTrue(SystemDNSProbe.isLoopbackListing("127.0.0.1\n::1\n"))
        XCTAssertTrue(SystemDNSProbe.isLoopbackListing("127.53.0.1"))
        XCTAssertFalse(SystemDNSProbe.isLoopbackListing("127.0.0.1\n8.8.8.8\n"), "mixed is not pinned")
        XCTAssertFalse(SystemDNSProbe.isLoopbackListing("There aren't any DNS Servers set on Wi-Fi.\n"), "DHCP is not loopback")
        XCTAssertFalse(SystemDNSProbe.isLoopbackListing(""))
        XCTAssertFalse(SystemDNSProbe.isLoopbackListing("192.168.1.1"))
    }
}

final class EngineStateDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> EngineResponse {
        try JSONDecoder().decode(EngineResponse.self, from: Data(json.utf8))
    }

    func testOldEngineWithoutRestoreOwed() throws {
        // Engines before 0.15 never send restoreOwed; the poll must not fail.
        let r = try decode(#"{"v":1,"ok":true,"state":{"enabled":true,"provider":"google","protocol":"doh","upstream":"u","listening":true,"pinned":true}}"#)
        XCTAssertNil(r.state?.restoreOwed)
        XCTAssertNil(r.state?.engineVersion)
        XCTAssertEqual(r.state?.proto, "doh")
    }

    func testExtraFieldsAreIgnored() throws {
        let r = try decode(#"{"v":1,"ok":true,"future":1,"state":{"enabled":false,"provider":"controld","protocol":"doq","upstream":"u","listening":true,"pinned":false,"restoreOwed":true,"engineVersion":"0.19 (19)","dnsproxyVersion":"v0.86.0","newThing":[1,2]}}"#)
        XCTAssertEqual(r.state?.restoreOwed, true)
        XCTAssertEqual(r.state?.engineVersion, "0.19 (19)")
    }

    func testErrorReply() throws {
        let r = try decode(#"{"v":1,"ok":false,"error":{"code":"invalid_id","msg":"x"}}"#)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "invalid_id")
    }

    func testVersion2StillDecodesSoTheAppCanRejectIt() throws {
        // The version check happens after decoding (engineIncompatible), so a
        // v=2 reply must decode rather than throw.
        let r = try decode(#"{"v":2,"ok":true}"#)
        XCTAssertEqual(r.v, 2)
        XCTAssertNil(r.state)
    }

    func testRequestUsesProtocolKey() throws {
        var req = EngineRequest(cmd: "switch")
        req.provider = "nextdns"
        req.proto = "doh3"
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        XCTAssertEqual(obj?["protocol"] as? String, "doh3")
        XCTAssertNil(obj?["proto"])
        XCTAssertEqual(obj?["v"] as? Int, 1)
    }
}
