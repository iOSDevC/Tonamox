#if os(macOS)
import Foundation
import Testing
@testable import TerminalBridgeHelper
import TerminalBridgeKit

@Suite struct HelperOptionsTests {
    @Test func parsesRunWithEveryOption() throws {
        let command = try HelperOptions.parse([
            "run", "--simulator", "--port", "40001", "--session", "tnx-e2e", "--window", "0",
            "--prompt-regex", "%$", "--config", "/tmp/a b/config.json", "--journal", "/tmp/a b/writes.log", "--verbose",
        ])
        var expected = RunOptions(mode: .simulator)
        expected.port = 40001
        expected.target = TargetOptions(session: "tnx-e2e", window: "0", promptRegex: "%$")
        expected.configURL = URL(filePath: "/tmp/a b/config.json")
        expected.journalURL = URL(filePath: "/tmp/a b/writes.log")
        expected.verbose = true
        #expect(command == .run(expected))
    }

    @Test func runDefaults() throws {
        guard case .run(let options) = try HelperOptions.parse(["run", "--device", "00008150-001A2B3C4D5E6F7A"]) else {
            Issue.record("expected run")
            return
        }
        #expect(options.mode == .device(udid: "00008150-001A2B3C4D5E6F7A"))
        #expect(options.port == 47821)
        #expect(options.target == TargetOptions(session: "tonamox", window: "0", promptRegex: nil))
        #expect(options.configURL == nil)
        #expect(options.journalURL == nil)
    }

    @Test func parsesPairUnpairStatusAndDoctor() throws {
        #expect(try HelperOptions.parse(["pair", "--new", "--config", "/x/c.json"]) == .pair(.generate, configURL: URL(filePath: "/x/c.json")))
        #expect(try HelperOptions.parse(["pair", "--code", "abcd-efgh"]) == .pair(.code("abcd-efgh"), configURL: nil))
        #expect(try HelperOptions.parse(["pair", "--stdin"]) == .pair(.standardInput, configURL: nil))
        #expect(try HelperOptions.parse(["unpair"]) == .unpair(configURL: nil))
        var doctor = StatusOptions()
        doctor.target = TargetOptions(session: "tnx-a")
        #expect(try HelperOptions.parse(["doctor", "--session", "tnx-a"]) == .doctor(doctor))
        guard case .status(let status) = try HelperOptions.parse(["status", "--usb", "--journal", "/j.log"]) else {
            Issue.record("expected status")
            return
        }
        #expect(status.listUSBDevices)
        #expect(status.journalURL == URL(filePath: "/j.log"))
        #expect(try HelperOptions.parse([]) == .help)
        #expect(try HelperOptions.parse(["--version"]) == .version)
    }

    @Test(arguments: [
        ["run"],
        ["run", "--simulator", "--device", "00008150-001A2B3C4D5E6F7A"],
        ["run", "--simulator", "--session", "bad name"],
        ["run", "--simulator", "--session", "tonamox;rm"],
        ["run", "--simulator", "--session", String(repeating: "a", count: 33)],
        ["run", "--simulator", "--window", String(repeating: "w", count: 17)],
        ["run", "--simulator", "--window", "="],
        ["run", "--simulator", "--window", "1"],
        ["doctor", "--usb"],
        ["doctor", "--journal"],
        ["run", "--simulator", "--port", "0"],
        ["run", "--simulator", "--port", "70000"],
        ["run", "--simulator", "--prompt-regex", "(["],
        ["run", "--device", "not-a-udid!"],
        ["run", "--simulator", "--session"],
        ["pair"],
        ["pair", "--new", "--stdin"],
        ["unpair", "--force"],
        ["frobnicate"],
    ])
    func rejectsInvalidArguments(_ arguments: [String]) {
        #expect(throws: HelperOptionsError.self) { try HelperOptions.parse(arguments) }
    }

    @Test func everySubcommandAcceptsTheSameStateFiles() throws {
        let files = ["--config", "/tmp/a b/c.json", "--journal", "/tmp/a b/w.log"]
        let config = URL(filePath: "/tmp/a b/c.json")
        let journal = URL(filePath: "/tmp/a b/w.log")
        #expect(try HelperOptions.parse(["pair", "--new"] + files) == .pair(.generate, configURL: config))
        #expect(try HelperOptions.parse(["unpair"] + files) == .unpair(configURL: config))
        guard case .doctor(let doctor) = try HelperOptions.parse(["doctor"] + files),
              case .status(let status) = try HelperOptions.parse(["status"] + files),
              case .run(let run) = try HelperOptions.parse(["run", "--simulator"] + files)
        else {
            Issue.record("expected doctor, status and run")
            return
        }
        #expect(doctor.configURL == config && doctor.journalURL == journal)
        #expect(status.configURL == config && status.journalURL == journal)
        #expect(run.configURL == config && run.journalURL == journal)
        #expect(HelperOptions.usage.contains("Todos los subcomandos aceptan --config y --journal"))
    }

    @Test func windowZeroIsStillAccepted() throws {
        guard case .run(let options) = try HelperOptions.parse(["run", "--simulator", "--window", "0"]) else {
            Issue.record("expected run")
            return
        }
        #expect(options.target.window == "0")
        #expect(!HelperOptions.usage.contains("--window"))
    }
}

@Suite struct HelperCLITests {
    private struct Captured {
        let io: HelperIO
        let out: LineSink
        let err: LineSink
    }

    private func capture(input: String? = nil) -> Captured {
        let out = LineSink()
        let err = LineSink()
        let io = HelperIO(out: out.append, err: err.append, readLine: { _ in input })
        return Captured(io: io, out: out, err: err)
    }

    @Test func pairNewStoresTheSecretAndPrintsItsCode() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("Application Support/config.json")
        let console = capture()

        let code = await HelperCLI.main(["pair", "--new", "--config", config.path(percentEncoded: false)], io: console.io)

        #expect(code == HelperExitCode.success)
        #expect(fileMode(config) == 0o600)
        let stored = try HelperConfigStore(fileURL: config).loadPaired()
        let printed = try #require(console.out.lines.first { $0.hasPrefix("Código de emparejamiento: ") })
        let parsed = try PairingCode(parsing: String(printed.dropFirst("Código de emparejamiento: ".count)))
        #expect(parsed.secret == stored.secret)
        #expect(console.out.joined.contains("Huella: \(parsed.fingerprint)"))
    }

    @Test func pairFromStdinAndFromArgument() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("config.json").path(percentEncoded: false)
        let known = try PairingCode(secret: Data((0..<20).map { UInt8($0) }))

        let piped = capture(input: known.formatted.lowercased())
        #expect(await HelperCLI.main(["pair", "--stdin", "--config", config], io: piped.io) == HelperExitCode.success)
        #expect(piped.out.joined.contains("Huella: SJMQ-HVBB"))
        #expect(!piped.out.joined.contains(known.formatted))
        let helperID = try HelperConfigStore(fileURL: URL(filePath: config)).loadPaired().helperID

        let argument = capture()
        #expect(await HelperCLI.main(["pair", "--code", known.compact, "--config", config], io: argument.io) == HelperExitCode.success)
        #expect(try HelperConfigStore(fileURL: URL(filePath: config)).loadPaired().helperID == helperID)
    }

    @Test func mistypedCodeIsAConfigurationError() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("config.json")
        var code = Array(try PairingCode(secret: Data((0..<20).map { UInt8($0) })).compact)
        code[3] = code[3] == "A" ? "B" : "A"
        let console = capture()
        let exit = await HelperCLI.main(["pair", "--code", String(code), "--config", config.path(percentEncoded: false)], io: console.io)
        #expect(exit == HelperExitCode.configuration)
        #expect(console.err.joined.contains("mal copiado"))
        #expect(fileMode(config) == nil)
    }

    @Test func unpairThenRunRefusesWithoutPairing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("config.json").path(percentEncoded: false)
        let journal = directory.file("writes.log").path(percentEncoded: false)
        #expect(await HelperCLI.main(["pair", "--new", "--config", config], io: capture().io) == HelperExitCode.success)
        let unpair = capture()
        #expect(await HelperCLI.main(["unpair", "--config", config], io: unpair.io) == HelperExitCode.success)
        #expect(unpair.out.joined.contains("Emparejamiento borrado"))

        let run = capture()
        let exit = await HelperCLI.main(["run", "--simulator", "--config", config, "--journal", journal], io: run.io)
        #expect(exit == HelperExitCode.configuration)
        #expect(run.err.joined.contains("tonamox-bridge pair"))
        #expect(fileMode(directory.file("writes.log")) == nil)
    }

    @Test func runRefusesAnInsecureConfig() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("config.json")
        #expect(await HelperCLI.main(["pair", "--new", "--config", config.path(percentEncoded: false)], io: capture().io) == 0)
        chmod(config.path(percentEncoded: false), 0o640)
        let run = capture()
        let exit = await HelperCLI.main(
            ["run", "--simulator", "--config", config.path(percentEncoded: false), "--journal", directory.file("w.log").path(percentEncoded: false)],
            io: run.io
        )
        #expect(exit == HelperExitCode.configuration)
        #expect(run.err.joined.contains("chmod 600"))
    }

    /// Needs /usr/bin/screen 4.00.03 for `screen -v`; nothing is typed and no session is used.
    @Test(arguments: ["doctor", "status", "run"])
    func anInvalidSavedPromptRegexIsAConfigurationError(_ subcommand: String) async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("Application Support/config.json")
        var saved = HelperConfig(promptRegex: "(")
        saved.pair(with: PairingCode.generate())
        try HelperConfigStore(fileURL: config).save(saved)
        let console = capture()
        var arguments = [subcommand, "--config", config.path(percentEncoded: false)]
        arguments += ["--journal", directory.file("Logs/writes.log").path(percentEncoded: false)]
        if subcommand == "run" { arguments.insert("--simulator", at: 1) }

        let exit = await HelperCLI.main(arguments, io: console.io)

        #expect(exit == HelperExitCode.configuration)
        #expect(console.err.joined.contains("no es válida"))
        #expect(fileMode(directory.file("Logs/writes.log")) == nil)
    }

    @Test func doctorReportsAnInsecureConfigInsteadOfIgnoringIt() async throws {
        let directory = TemporaryDirectory()
        defer { directory.remove() }
        let config = directory.file("config.json")
        #expect(await HelperCLI.main(["pair", "--new", "--config", config.path(percentEncoded: false)], io: capture().io) == 0)
        chmod(config.path(percentEncoded: false), 0o644)
        let console = capture()
        let exit = await HelperCLI.main(["doctor", "--config", config.path(percentEncoded: false)], io: console.io)
        #expect(exit == HelperExitCode.configuration)
        #expect(console.err.joined.contains("chmod 600"))
    }

    @Test func usageErrorsExitWith64() async {
        let console = capture()
        #expect(await HelperCLI.main(["run", "--simulator", "--window", "a b"], io: console.io) == HelperExitCode.usage)
        #expect(console.err.joined.contains("Uso:"))
    }
}
#endif

#if os(macOS)
@Suite struct ScratchDirectoriesTests {
    private func makeDirectory(_ parent: TemporaryDirectory, _ name: String, files: [String] = []) throws -> URL {
        let directory = parent.location.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(atPath: directory.path(percentEncoded: false), withIntermediateDirectories: true)
        files.forEach { file in
            FileManager.default.createFile(
                atPath: directory.appending(path: file, directoryHint: .notDirectory).path(percentEncoded: false),
                contents: Data("screen".utf8)
            )
        }
        return directory
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func sweepsOnlyStaleScratchDirectoriesOfDeadHelpers() throws {
        let parent = TemporaryDirectory("tonamox sweep")
        defer { parent.remove() }
        let alive: Int32 = 4242
        let dead = try makeDirectory(parent, "tonamox-bridge.999991.AbCdEf", files: ["hc-1.txt", "hc-2.txt"])
        let deadWithOther = try makeDirectory(parent, "tonamox-bridge.999992.QwErTy", files: ["hc-3.txt", "notes.txt"])
        let running = try makeDirectory(parent, "tonamox-bridge.\(alive).ZxCvBn", files: ["hc-4.txt"])
        let legacyEmpty = try makeDirectory(parent, "tonamox-bridge.wjQIgE")
        let legacyBusy = try makeDirectory(parent, "tonamox-bridge.PoIuYt", files: ["hc-5.txt"])
        let unrelated = try makeDirectory(parent, "other-tool.999993.AbCdEf")
        let target = try makeDirectory(parent, "elsewhere", files: ["hc-6.txt"])
        let link = parent.location.appending(path: "tonamox-bridge.999994.LiNkEd", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: target.path(percentEncoded: false)
        )

        let removed = ScratchDirectories.sweepStale(in: parent.location) { $0 == alive }

        #expect(removed == ["tonamox-bridge.999991.AbCdEf", "tonamox-bridge.wjQIgE"])
        #expect(!exists(dead) && !exists(legacyEmpty))
        #expect(exists(deadWithOther))
        #expect(!exists(deadWithOther.appending(path: "hc-3.txt", directoryHint: .notDirectory)))
        #expect(exists(running.appending(path: "hc-4.txt", directoryHint: .notDirectory)))
        #expect(exists(legacyBusy) && exists(unrelated))
        #expect(exists(target.appending(path: "hc-6.txt", directoryHint: .notDirectory)))
    }

    @Test func newScratchDirectoriesCarryThePidAndArePrivate() throws {
        let parent = TemporaryDirectory("tonamox scratch")
        defer { parent.remove() }
        let made = try HelperCLI.makeScratchDirectory(in: parent.location)
        #expect(ScratchDirectories.owner(of: made.lastPathComponent) == .process(getpid()))
        #expect(fileMode(made) == 0o700)
        #expect(ScratchDirectories.owner(of: "tonamox-bridge.abcdef") == .unknown)
        #expect(ScratchDirectories.owner(of: "tonamox-bridge.12.abc") == nil)
        #expect(ScratchDirectories.owner(of: "tonamox-bridgex.12.abcdef") == nil)
    }
}
#endif
