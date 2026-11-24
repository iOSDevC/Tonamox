import Foundation
import Testing
import TerminalBridgeKit

@Suite struct CumulativeTextDifferTests {
    @Test func cumulativeUpdatesBecomeDeltas() {
        var differ = CumulativeTextDiffer()
        #expect(differ.next("Ho") == .append("Ho"))
        #expect(differ.next("Hola") == .append("la"))
        #expect(differ.next("Hola, mundo") == .append(", mundo"))
    }

    @Test func repeatedAndEmptyUpdatesAppendNothing() {
        var differ = CumulativeTextDiffer()
        #expect(differ.next("") == .append(""))
        #expect(differ.next("ls") == .append("ls"))
        #expect(differ.next("ls") == .append(""))
        #expect(differ.next("") == .append(""))
        #expect(differ.next("ls -la") == .append(" -la"))
    }

    @Test func aCombiningMarkSplitAcrossUpdatesIsKept() {
        var differ = CumulativeTextDiffer()
        var shown = ""
        for update in ["Cafe", "Cafe\u{301}", "Cafe\u{301} listo"] {
            guard case .append(let delta) = differ.next(update) else {
                Issue.record("diverged on \(update)")
                return
            }
            shown += delta
        }
        #expect(shown == "Café listo")
        #expect(shown.unicodeScalars.count == "Cafe\u{301} listo".unicodeScalars.count)
    }

    @Test func aZWJSequenceSplitAcrossUpdatesIsKept() {
        var differ = CumulativeTextDiffer()
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(differ.next("ok \u{1F468}") == .append("ok \u{1F468}"))
        #expect(differ.next("ok \u{1F468}\u{200D}") == .append("\u{200D}"))
        #expect(differ.next("ok " + family) == .append("\u{1F469}\u{200D}\u{1F467}"))
    }

    @Test func aRewrittenPrefixDiverges() {
        var differ = CumulativeTextDiffer()
        _ = differ.next("rm -i a")
        #expect(differ.next("rm -rf a") == .diverged)
    }

    @Test func aShorterNonEmptyUpdateDiverges() {
        var differ = CumulativeTextDiffer()
        _ = differ.next("echo hola")
        #expect(differ.next("echo") == .diverged)
    }
}

@Suite struct CompatibleServerAddressTests {
    private func accepted(_ raw: String) throws -> CompatibleServerAddress {
        try CompatibleServerAddress.parse(raw).get()
    }

    private func refusal(_ raw: String) -> ServerAddressRefusal? {
        if case .failure(let refusal) = CompatibleServerAddress.parse(raw) { return refusal }
        return nil
    }

    @Test func plainHTTPToPrivateAndLoopbackLiteralsIsLocal() throws {
        for raw in ["http://192.168.1.20:8080/v1", "http://10.0.0.5/v1", "http://172.16.0.1/v1",
                    "http://172.31.255.254/v1", "http://169.254.1.1/v1", "http://127.0.0.1:8080/v1",
                    "http://[::1]:8080/v1", "http://[fd12:3456::1]/v1", "http://[fe80::1]/v1",
                    "  http://192.168.1.20:8080/v1\n"] {
            let address = try accepted(raw)
            #expect(address.isLocalNetwork, "\(raw)")
        }
        #expect(try accepted("http://192.168.1.20:8080/v1").url.absoluteString == "http://192.168.1.20:8080/v1")
    }

    @Test func plainHTTPOutsidePrivateLiteralsIsRefused() {
        for raw in ["http://example.com/v1", "http://mac.local:8080/v1", "http://localhost:8080/v1",
                    "http://172.32.0.1/v1", "http://100.64.0.1/v1", "http://8.8.8.8/v1", "http://[2001:db8::1]/v1"] {
            #expect(refusal(raw) == .plainHTTPOutsideLocalNetwork, "\(raw)")
        }
    }

    @Test func httpsToANameIsAcceptedAndCountsAsInternet() throws {
        #expect(try accepted("https://api.example.com/v1").isLocalNetwork == false)
        #expect(try accepted("https://mac.local/v1").isLocalNetwork == false)
        #expect(try accepted("https://192.168.1.20/v1").isLocalNetwork)
    }

    @Test func malformedAddressesAreRefused() {
        #expect(refusal("") == .empty)
        #expect(refusal("   ") == .empty)
        #expect(refusal("ftp://192.168.1.20/v1") == .unsupportedScheme)
        #expect(refusal("file:///etc/passwd") == .unsupportedScheme)
        #expect(refusal("192.168.1.20:8080") != nil)
        #expect(refusal("http://") == .missingHost)
        #expect(refusal("http://user:secret@192.168.1.20/v1") == .containsCredentials)
        #expect(refusal("http://192.168.1.20/v1?key=1") == .containsQueryOrFragment)
        #expect(refusal("http://192.168.1.20/v1#x") == .containsQueryOrFragment)
    }

    @Test func hostLabelNamesHostAndPort() throws {
        #expect(try accepted("http://192.168.1.20:8080/v1").hostLabel == "192.168.1.20:8080")
        #expect(try accepted("https://api.example.com/v1").hostLabel == "api.example.com")
        #expect(try accepted("http://[fe80::1]:8080/v1").hostLabel == "[fe80::1]:8080")
    }

    @Test func originFillsTheDefaultPortAndIgnoresThePath() throws {
        #expect(try accepted("http://192.168.1.20/v1").origin == "http://192.168.1.20:80")
        #expect(try accepted("https://API.example.com/v1").origin == "https://api.example.com:443")
        #expect(try accepted("https://api.example.com:443/other").origin
                == accepted("https://api.example.com/v1").origin)
        #expect(try accepted("http://192.168.1.20:8080/v1").origin != accepted("http://192.168.1.21:8080/v1").origin)
        #expect(try accepted("http://192.168.1.20/v1").origin != accepted("https://192.168.1.20/v1").origin)
    }

    @Test func everyRefusalHasASpanishMessage() {
        let all: [ServerAddressRefusal] = [.empty, .invalid, .unsupportedScheme, .missingHost, .containsCredentials,
                                           .containsQueryOrFragment, .plainHTTPOutsideLocalNetwork]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(ServerAddressRefusal.plainHTTPOutsideLocalNetwork.message.contains("https://"))
    }
}

@Suite struct RemoteEngineReadinessTests {
    @Test func blockersComeInTheOrderTheUserFixesThem() {
        #expect(RemoteEngineReadiness.blocker(modeIsOff: true, isCloud: true, cloudAllowed: false, hasKey: false,
                                              isConfigured: false)?.contains("«Off»") == true)
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: false,
                                              isConfigured: false)?.contains("Configura el servidor") == true)
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: false,
                                              isConfigured: true)?.contains("Falta la clave") == true)
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: true, cloudAllowed: false, hasKey: true,
                                              isConfigured: true)?.contains("Allow cloud providers") == true)
    }

    @Test func readyEnginesHaveNoBlocker() {
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: true, cloudAllowed: true, hasKey: true,
                                              isConfigured: true) == nil)
        #expect(RemoteEngineReadiness.blocker(modeIsOff: false, isCloud: false, cloudAllowed: false, hasKey: false,
                                              isConfigured: true) == nil)
    }
}

@Suite struct RemoteTurnDisclosureTests {
    @Test func pastedOutputIsNamedWithItsSize() {
        let lines = RemoteTurnDisclosure.lines(pastedOutputBytes: 812, isCloud: true)
        #expect(lines.contains("Este mensaje incluye salida de terminal pegada (812 bytes), enviada como datos entre delimitadores."))
        #expect(!lines.contains("Este mensaje no incluye salida de terminal pegada."))
    }

    @Test func aPlainTurnSaysItHasNoPastedOutput() {
        let lines = RemoteTurnDisclosure.lines(pastedOutputBytes: nil, isCloud: false)
        #expect(lines.contains("Este mensaje no incluye salida de terminal pegada."))
        #expect(lines.first == "Va a un servidor de tu red local; no se comprobó que sea tuyo.")
    }

    @Test func aKeptCapturedCommandIsNamed() {
        let with = RemoteTurnDisclosure.lines(pastedOutputBytes: 40, isCloud: true, includesCapturedCommand: true)
        #expect(with.contains { $0.contains("Incluye la última orden capturada.") })
        let without = RemoteTurnDisclosure.lines(pastedOutputBytes: 40, isCloud: true)
        #expect(!without.joined().contains("orden capturada"))
    }

    @Test func everyTurnStatesScopeSecretsAndThatRepliesOnlyPropose() {
        for bytes in [nil, 10] as [Int?] {
            for cloud in [true, false] {
                let text = RemoteTurnDisclosure.lines(pastedOutputBytes: bytes, isCloud: cloud).joined(separator: "\n")
                #expect(text.contains("ni el historial ni otras órdenes"))
                #expect(text.contains("secretos de tu terminal"))
                #expect(text.contains("La respuesta solo propone órdenes"))
            }
        }
    }
}
