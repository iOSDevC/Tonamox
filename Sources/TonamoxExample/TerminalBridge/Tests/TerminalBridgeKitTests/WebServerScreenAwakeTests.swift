import Testing
import TerminalBridgeKit

@Suite struct WebServerScreenAwakeTests {
    @Test func startsOnWhenNothingIsStored() {
        #expect(WebServerScreenAwake.isEnabled(stored: nil))
        #expect(WebServerScreenAwake.defaultEnabled)
    }

    @Test(arguments: [true, false])
    func keepsTheStoredChoice(_ stored: Bool) {
        #expect(WebServerScreenAwake.isEnabled(stored: stored) == stored)
    }

    @Test(arguments: [
        WebServerStatus.starting,
        .listening(url: "http://127.0.0.1:47830", observableByNetwork: false),
        .listening(url: "http://192.168.1.20:47830", observableByNetwork: true),
    ])
    func holdsWhileThePortIsOpenOrOpening(_ status: WebServerStatus) {
        #expect(WebServerScreenAwake.holdsScreen(status: status, enabled: true, inForeground: true))
    }

    @Test(arguments: [
        WebServerStatus.stopped,
        .suspended(.appBackgrounded),
        .suspended(.idle(minutes: 15)),
        .suspended(.interfaceLost("en0")),
        .failed(.portInUse(47830)),
        .failed(.listener("refused")),
    ])
    func releasesWhenNotServing(_ status: WebServerStatus) {
        #expect(!WebServerScreenAwake.holdsScreen(status: status, enabled: true, inForeground: true))
    }

    @Test func releasesWhenTheToggleIsOff() {
        let listening = WebServerStatus.listening(url: "http://127.0.0.1:47830", observableByNetwork: false)
        #expect(!WebServerScreenAwake.holdsScreen(status: listening, enabled: false, inForeground: true))
        #expect(!WebServerScreenAwake.holdsScreen(status: .starting, enabled: false, inForeground: true))
    }

    @Test func releasesInTheBackground() {
        let listening = WebServerStatus.listening(url: "http://127.0.0.1:47830", observableByNetwork: false)
        #expect(!WebServerScreenAwake.holdsScreen(status: listening, enabled: true, inForeground: false))
    }

    @Test func returningToTheForegroundHoldsOnlyAfterThePortReopens() {
        let listening = WebServerStatus.listening(url: "http://127.0.0.1:47830", observableByNetwork: false)
        let steps: [(WebServerStatus, Bool, Bool)] = [
            (listening, true, true),
            (listening, false, false),
            (.suspended(.appBackgrounded), false, false),
            (.suspended(.appBackgrounded), true, false),
            (.starting, true, true),
            (listening, true, true),
        ]
        for (status, inForeground, expected) in steps {
            #expect(WebServerScreenAwake.holdsScreen(status: status, enabled: true, inForeground: inForeground)
                    == expected)
        }
    }

    @Test func copyMatchesTheScreen() {
        #expect(WebServerScreenAwake.toggleTitle == "Mantener la pantalla encendida mientras sirve")
        #expect(WebServerScreenAwake.footer.contains("batería"))
        #expect(WebServerScreenAwake.footer.contains("segundo plano"))
        #expect(WebServerScreenAwake.footer.contains("el puerto se cierra igual"))
    }

    @Test func defaultsKeyIsStable() {
        #expect(WebServerScreenAwake.defaultsKey == "webServer.keepsScreenAwake")
    }
}
