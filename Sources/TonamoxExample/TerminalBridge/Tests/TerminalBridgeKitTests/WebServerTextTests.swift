import Foundation
import Testing
import TerminalBridgeKit

@Suite struct WebServerPortTests {
    @Test(arguments: ["47830", " 8080 ", "1024", "65535"])
    func acceptsPortsInRange(_ text: String) throws {
        let expected = UInt16(text.trimmingCharacters(in: .whitespaces))
        #expect(try WebServerPort.validate(text).get() == expected)
    }

    @Test func refusesEmptyText() {
        #expect(WebServerPort.validate("  ") == .failure(.empty))
    }

    @Test(arguments: ["80a", "-1", "+8080", "8 080", "٤٧٨٣٠", "4.5"])
    func refusesNonDigits(_ text: String) {
        #expect(WebServerPort.validate(text) == .failure(.notANumber))
    }

    @Test(arguments: ["0", "80", "1023", "65536", "99999", "000000047830", "12345678901234567890"])
    func refusesOutOfRange(_ text: String) {
        #expect(WebServerPort.validate(text) == .failure(.outOfRange))
    }

    @Test func messagesNameTheRange() {
        #expect(WebServerPortRefusal.outOfRange.message.contains("1024"))
        #expect(WebServerPortRefusal.outOfRange.message.contains("65535"))
        #expect(WebServerPortRefusal.empty.message.contains("47830"))
    }
}

@Suite struct WebServerInterfaceKindTests {
    @Test func titlesArePlainSpanish() {
        #expect(WebServerInterfaceKind.wifi.title == "Wi-Fi")
        #expect(WebServerInterfaceKind.personalHotspot.title == "Punto de acceso personal")
        #expect(WebServerInterfaceKind.wired.title == "Cable (USB o Ethernet)")
        #expect(WebServerInterfaceKind.other.title == "Otra red local")
    }

    @Test func rowNamesAddressAndInterface() {
        #expect(WebServerInterfaceKind.wifi.rowTitle(address: "192.168.1.5", interfaceName: "en0")
            == "Wi-Fi: 192.168.1.5 (en0)")
    }

    @Test(arguments: [WebServerInterfaceKind.wifi, .personalHotspot, .wired, .other])
    func everyNetworkWarningSaysItIsNotEncrypted(_ kind: WebServerInterfaceKind) {
        #expect(kind.networkWarning.hasPrefix("Sin cifrado:"))
        #expect(kind.networkWarning.contains("conversación"))
    }

    @Test func peerLockExplanationNamesTheButton() {
        #expect(WebServerInterfaceKind.peerLockExplanation.contains("«Permitir otro equipo»"))
    }
}

@Suite struct WebServerStatusTests {
    @Test func listeningOnLoopbackDoesNotWarn() {
        let status = WebServerStatus.listening(url: "http://127.0.0.1:47830", observableByNetwork: false)
        #expect(status.title == "Escuchando")
        #expect(!status.detail.contains("no está cifrada"))
        #expect(status.isActive)
        #expect(!status.isProblem)
    }

    @Test func listeningOnANetworkWarns() {
        let status = WebServerStatus.listening(url: "http://192.168.1.5:47830", observableByNetwork: true)
        #expect(status.detail.contains("no está cifrada"))
    }

    @Test func portInUseNamesThePort() {
        let status = WebServerStatus.failed(.portInUse(47830))
        #expect(status.title == "No pudo arrancar")
        #expect(status.detail.contains("47830"))
        #expect(status.isProblem)
        #expect(!status.isActive)
    }

    @Test func listenerFailureHidesTheSystemText() {
        #expect(!WebServerStatus.describe(.listener("POSIXErrorCode(rawValue: 48)")).contains("POSIX"))
    }

    @Test func interfaceReasonsNameTheInterface() {
        #expect(WebServerStatus.describe(.interfaceLost("en0")).contains("en0"))
        #expect(WebServerStatus.describe(.interfaceUnavailable("bridge100")).contains("bridge100"))
    }

    @Test func backgroundSuspensionStaysActiveButIdleDoesNot() {
        #expect(WebServerStatus.suspended(.appBackgrounded).isActive)
        #expect(!WebServerStatus.suspended(.idle(minutes: 15)).isActive)
        #expect(!WebServerStatus.suspended(.interfaceLost("en0")).isActive)
        #expect(WebServerStatus.suspended(.idle(minutes: 15)).isProblem)
    }

    @Test func stoppedSaysItNeverStartsByItself() {
        #expect(WebServerStatus.stopped.detail.contains("no vuelve a arrancar solo"))
        #expect(!WebServerStatus.stopped.isActive)
    }
}

@Suite struct WebServerCountdownTests {
    @Test(arguments: [(120, "2:00"), (119, "1:59"), (61, "1:01"), (9, "0:09"), (0, "0:00"), (-5, "0:00")])
    func formatsMinutesAndSeconds(_ seconds: Int, _ expected: String) {
        #expect(WebServerCountdown.format(secondsLeft: seconds) == expected)
    }

    @Test func secondsLeftRoundsUpAndNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(WebServerCountdown.secondsLeft(until: now.addingTimeInterval(119.2), now: now) == 120)
        #expect(WebServerCountdown.secondsLeft(until: now.addingTimeInterval(-3), now: now) == 0)
    }
}

@Suite struct APIKeyLabelTests {
    @Test func foldsAccentsAndCollapsesSpaces() {
        #expect(APIKeyLabel.sanitize("  Mac   del   diseñador ") == .success("Mac del disenador"))
    }

    @Test func dropsControlsBidiAndSymbols() {
        #expect(APIKeyLabel.sanitize("edi\u{202E}tor\u{0007}; rm -rf /") == .success("editor rm -rf"))
    }

    @Test func keepsDotsUnderscoresAndDashes() {
        #expect(APIKeyLabel.sanitize("vs_code-1.2") == .success("vs_code-1.2"))
    }

    @Test func capsTheLengthWithoutATrailingSpace() throws {
        let label = try APIKeyLabel.sanitize(String(repeating: "a", count: 39) + " bcd").get()
        #expect(label == String(repeating: "a", count: 39))
        #expect(try APIKeyLabel.sanitize(String(repeating: "x", count: 100)).get().count == APIKeyLabel.maxLength)
    }

    @Test(arguments: ["", "   ", "\u{200B}\u{202E}", "🔑🔑"])
    func refusesEmptyResults(_ text: String) {
        #expect(APIKeyLabel.sanitize(text) == .failure(.empty))
    }
}

@Suite struct APIKeyInstructionsTests {
    @Test func linesKeepTheKeyOutOfArguments() {
        let lines = APIKeyInstructions(baseURL: "http://192.168.1.5:47830/")
        #expect(lines.saveLine == "(umask 077; pbpaste > ~/.tonamox-key)")
        #expect(lines.testLine == #"curl -sS -H @"$HOME/.tonamox-key" http://192.168.1.5:47830/v1/models"#)
        #expect(lines.openAIBaseURL == "http://192.168.1.5:47830/v1")
        #expect(!lines.testLine.contains("Bearer"))
    }
}

@Suite struct ServedModelNameTests {
    @Test(arguments: [("Qwen3 1.7B (GGUF)", "qwen3-1.7b-gguf"), ("Llama-3.2 3B Q4_K_M", "llama-3.2-3b-q4_k_m"),
                      ("Modelo pequeño", "modelo-pequeno"), ("  ..Árbol..  ", "arbol"), ("🔑", "modelo-local"),
                      ("a/b%20c?d", "a-b-20c-d")])
    func makesURLSafeIDs(_ title: String, _ expected: String) {
        #expect(ServedModelName.id(from: title) == expected)
    }

    @Test func capsTheLength() {
        #expect(ServedModelName.id(from: String(repeating: "x", count: 200)).count == ServedModelName.maxLength)
    }
}
