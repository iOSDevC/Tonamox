import Foundation
import TonamoxCore

/// `tonamox bench` — measure which engine runs a model fastest on this Mac: in-process GGUF (llama.cpp) and MLX
/// models, and local llama-server / Ollama / Magnitude servers. Tables or JSON go to stdout, progress to stderr.
extension TonamoxCLI {

    static let benchUsage = """
        usage: tonamox bench [--gguf <path | catalog id | URL>]... [--mlx <catalog id | repo id>]...
                             [--server ollama|llama-server|magnitude[:<model>]]... [--all-servers]
                             [--workload chat|code|long|all] [--runs N] [--temperature T] [--max-tokens N] [--json]

        Candidates run one at a time: in-process models first (--gguf, then --mlx), then servers. Each workload gets
        one warm-up run, left out of the table, and N measured runs (default 3) at temperature T (default 0). An
        in-process model is loaded for its own turn and released before the next; a catalog model that is not on disk
        is downloaded first, which the runs' timings leave out but the load and cold-start times include. --server
        without a model takes the server's first model that runs on this machine (Ollama cloud tags are skipped);
        --all-servers adds every running server that way. --mlx takes catalog models only, not a local folder.
        Ctrl-C stops the run and prints the partial report. Exit status: 0; 1 when no engine produced a measured
        run; 2 for usage errors; 130 after Ctrl-C.

        """

    static func runBench(_ args: [String]) async throws {
        if args.contains("--help") || args.contains("-h") {
            print(benchUsage, terminator: "")
            return
        }
        let request: BenchRequest
        let report: BenchmarkReport
        do {
            request = try BenchRequest(args)
            let candidates = try await benchCandidates(for: request)
            let benchmark = EngineBenchmark(candidates: candidates, workloads: request.workloads,
                                            settings: request.settings)
            report = await runInterruptibly(benchmark)
        } catch let usage as CLIUsageError {
            err("tonamox bench: \(usage.message)\n" + benchUsage)
            exit(2)
        }
        if request.json {
            print(try benchJSON(report))
        } else {
            printBenchReport(report)
        }
        if report.wasCancelled { exit(130) }
        guard report.hasMeasuredRuns else {
            err("tonamox bench: no engine produced a measured run.\n")
            exit(1)
        }
    }

    /// Runs `benchmark`. The first Ctrl-C cancels it, so the partial report still prints; a second one quits.
    static func runInterruptibly(_ benchmark: EngineBenchmark) async -> BenchmarkReport {
        let work = Task { await benchmark.run(onEvent: printBenchEvent) }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            let note = "\nCancelling: the report will be partial (Ctrl-C again quits).\n"
            FileHandle.standardError.write(Data(note.utf8))
            work.cancel()
            signal(SIGINT, SIG_DFL)
        }
        interrupt.resume()
        let report = await work.value
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)
        return report
    }

    // MARK: - Candidates

    static func benchCandidates(for request: BenchRequest) async throws -> [BenchmarkCandidate] {
        var candidates = try request.ggufArguments.map { try inProcessCandidate(gguf: $0) }
        candidates += try request.mlxArguments.map { try inProcessCandidate(mlx: $0) }
        if !request.servers.isEmpty || request.allServers {
            candidates += await serverCandidates(request.servers, addingAllRunning: request.allServers)
        }
        guard !candidates.isEmpty else {
            throw CLIUsageError("No engine to benchmark: pass --gguf, --mlx, --server or --all-servers"
                                + " (requested servers that are not running are skipped).")
        }
        return candidates
    }

    static func inProcessCandidate(gguf argument: String) throws -> BenchmarkCandidate {
        let model = try ReceiptReader.model(for: argument)
        guard model.format == .gguf else { throw CLIUsageError("\(argument) is not a GGUF model; use --mlx.") }
        if let file = model.localFileURL, !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            throw CLIUsageError("No GGUF file at \(file.path(percentEncoded: false)).")
        }
        noteDownload(model)
        return .inProcess(model)
    }

    static func inProcessCandidate(mlx argument: String) throws -> BenchmarkCandidate {
        let registry = ModelRegistry.shared
        guard let model = registry.model(id: argument) ?? registry.model(repoID: argument) else {
            throw CLIUsageError("\(argument) is not a catalog model id or repo id. --mlx loads catalog models only "
                                + "(`tonamox models check <repo> --entry` prints an entry for one that is not).")
        }
        guard model.format == .mlx else { throw CLIUsageError("\(argument) is not an MLX model; use --gguf.") }
        noteDownload(model)
        return .inProcess(model)
    }

    static func noteDownload(_ model: Model) {
        guard !model.isDownloaded else { return }
        // A model built from a URL has no catalog size.
        let size = model.approximateSizeMB > 0 ? "about \(model.approximateSizeMB) MB" : "size unknown"
        err("\(model.displayName) is not on disk: it downloads before its runs (\(size); the runs' timings leave "
            + "it out, loadSeconds includes it).\n")
    }

    /// Requested servers that are not running, or lack the model, are skipped with a note on stderr.
    static func serverCandidates(_ requested: [BenchServer], addingAllRunning: Bool) async -> [BenchmarkCandidate] {
        let statuses = await LocalProviderDetector.detectAll()
        var wanted = requested
        if addingAllRunning {
            let named = Set(requested.map(\.kind))
            wanted += statuses.filter { $0.isAvailable && !named.contains($0.kind) }.map { benchServer($0.kind) }
        }
        var seen: Set<String> = []
        var candidates: [BenchmarkCandidate] = []
        for server in wanted {
            guard let match = resolve(server, in: statuses),
                  seen.insert("\(match.status.kind.rawValue)|\(match.model.name)").inserted else { continue }
            candidates.append(.server(match.status, model: match.model))
        }
        return candidates
    }

    static func benchServer(_ kind: LocalProviderKind) -> BenchServer {
        BenchServer(kind: kind, model: nil)
    }

    static func resolve(_ server: BenchServer, in statuses: [LocalProviderStatus])
        -> (status: LocalProviderStatus, model: LocalProviderModel)? {
        let name = server.kind.displayName
        guard let status = statuses.first(where: { $0.kind == server.kind }), status.reachable else {
            err("Skipping \(name): not running at its default address.\n")
            return nil
        }
        guard let wanted = server.model else {
            guard let model = status.models.first(where: \.runsLocally) else {
                err("Skipping \(name): it lists no model that runs on this machine.\n")
                return nil
            }
            return (status, model)
        }
        guard let model = status.models.first(where: { $0.name == wanted }) else {
            err("Skipping \(name): it does not list \(wanted).\n")
            return nil
        }
        guard model.runsLocally else {
            err("Skipping \(name) \(wanted): it runs on \(model.remoteHost ?? "a remote host"), not this machine.\n")
            return nil
        }
        return (status, model)
    }

    // MARK: - Progress

    static func printBenchEvent(_ event: BenchmarkEvent) {
        switch event {
        case .loading(_, let label):
            err("Loading \(label)…\n")
        case .running(let progress):
            err("  \(progress.summary)\n")
        case .workloadFinished(_, let result):
            if let failure = result.failure { err("  \(result.workloadID) failed: \(failure)\n") }
        case .candidateFinished(let result):
            if let loadError = result.loadError { err("  \(result.label) did not load: \(loadError)\n") }
        }
    }

    // MARK: - Output

    static func benchJSON(_ report: BenchmarkReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    static func printBenchReport(_ report: BenchmarkReport) {
        for workload in report.workloads {
            printBenchTable(report, workload: workload)
            printBenchNotes(report, workloadID: workload.id)
        }
        printColdStarts(report)
        if report.hasMeasuredRuns { printBenchLegend(report) }
        if report.wasCancelled { print("\nCancelled: the report is partial.") }
    }

    static func printBenchTable(_ report: BenchmarkReport, workload: BenchmarkWorkload) {
        let settings = report.settings
        let maxTokens = settings.maxTokensOverride ?? workload.maxTokens
        print("\n\(workload.title) (\(workload.id)) — max \(maxTokens) tokens, \(settings.measuredRuns) runs, "
              + "temperature \(fixed(Double(settings.temperature), digits: 1))")
        printTable([benchHeader] + report.candidates.compactMap { benchRow($0, workloadID: workload.id) })
    }

    static let benchHeader = ["ENGINE", "MODEL", "TTFT s", "PREFILL tok/s", "DECODE tok/s", "TOKENS",
                              "PROVENANCE", "FOOTPRINT", "RESIDENT", "OUTPUT MATCH"]

    static func benchRow(_ candidate: BenchmarkCandidateResult, workloadID: String) -> [String]? {
        guard let result = candidate.result(for: workloadID), !result.runs.isEmpty else { return nil }
        let timing = candidate.timing == .clientSide ? ", client-timed" : ""
        let prefill = metricText(result.prefillTokensPerSecond, digits: 0, range: false)
        let approximate = result.prefillTokensPerSecond != nil && !candidate.hasExactPrefill(in: workloadID)
        let before = candidate.memoryBeforeLoad
        return [
            candidate.id,
            modelText(candidate.weights),
            metricText(result.timeToFirstToken, digits: 2, range: true),
            approximate ? "≈" + prefill : prefill,
            metricText(result.decodeTokensPerSecond, digits: 1, range: true),
            metricText(result.generatedTokens, digits: 0, range: false),
            (result.source?.rawValue ?? "—") + timing,
            memoryText(result.peakMemory?.footprintBytes, before: before?.footprintBytes),
            memoryText(result.peakMemory?.residentBytes, before: before?.residentBytes),
            result.agreement.label,
        ]
    }

    /// The peak with its growth over the process before the model loaded, e.g. `3.21 GB (+2.60)`.
    static func memoryText(_ peak: Int?, before: Int?) -> String {
        guard let peak else { return "—" }
        let total = "\(fixed(Double(peak) / 1_073_741_824)) GB"
        guard let before else { return total }
        let growth = Double(peak - before) / 1_073_741_824
        return "\(total) (\(growth < 0 ? "" : "+")\(fixed(growth)))"
    }

    static func modelText(_ weights: BenchmarkModelIdentity) -> String {
        guard let quantization = weights.quantization,
              !weights.name.lowercased().contains(quantization.lowercased()) else { return weights.name }
        return "\(weights.name) (\(quantization))"
    }

    /// The median, with the min–max range when asked and the runs differ at the shown precision.
    static func metricText(_ metric: BenchmarkMetric?, digits: Int, range: Bool) -> String {
        guard let metric else { return "—" }
        let median = fixed(metric.median, digits: digits)
        let low = fixed(metric.minimum, digits: digits), high = fixed(metric.maximum, digits: digits)
        return range && low != high ? "\(median) (\(low)–\(high))" : median
    }

    static func printTable(_ rows: [[String]]) {
        let widths = rows.reduce(into: [Int](repeating: 0, count: benchHeader.count)) { widths, row in
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        for row in rows {
            print(paddedRow(row, widths: widths))
        }
    }

    static func paddedRow(_ row: [String], widths: [Int]) -> String {
        row.enumerated()
            .map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Load plus the first run's time to first token, for every candidate that has one.
    static func printColdStarts(_ report: BenchmarkReport) {
        let lines = report.candidates.compactMap { candidate -> String? in
            guard let cold = candidate.coldTimeToFirstToken else { return nil }
            let parts = candidate.loadSeconds.map { " (load \(fixed($0)) s + first token \(fixed(cold - $0)) s)" }
            return "  \(candidate.id): \(fixed(cold)) s" + (parts ?? "")
        }
        guard !lines.isEmpty else { return }
        print("\nCold start to first token (the warm-up run; a server's includes loading the model only if it had "
              + "not loaded it yet):")
        lines.forEach { print($0) }
    }

    static func printBenchLegend(_ report: BenchmarkReport) {
        print("""

            TTFT is the figure to compare across engines. ≈ PREFILL is prompt tokens over the time to first token \
            (llama.cpp in process: an estimated count; servers: timed by tonamox, HTTP included); only MLX times \
            prefill itself.
            """)
        guard report.candidates.contains(where: { $0.timing == .inProcess }) else { return }
        print("""
            FOOTPRINT (phys_footprint) and RESIDENT (resident_size) are the tonamox process's peaks during the \
            measured runs, with their growth over the process before the model loaded; servers run in their own \
            process. llama.cpp maps GGUF weights from the file: RESIDENT counts them, FOOTPRINT does not. MLX copies \
            its weights into memory that FOOTPRINT counts. Memory is not directly comparable between the two.
            """)
    }

    static func printBenchNotes(_ report: BenchmarkReport, workloadID: String) {
        for candidate in report.candidates {
            if let loadError = candidate.loadError {
                print("  ! \(candidate.id): did not load: \(loadError)")
            } else if let failure = candidate.result(for: workloadID)?.failure {
                print("  ! \(candidate.id): \(failure)")
            }
        }
        var fastest: [String] = []
        if let decode = report.fastestDecode(in: workloadID),
           let speed = decode.result(for: workloadID)?.decodeTokensPerSecond?.median {
            fastest.append("Fastest decode: \(decode.id) (\(fixed(speed, digits: 1)) tok/s)")
        }
        if let first = report.fastestTimeToFirstToken(in: workloadID),
           let seconds = first.result(for: workloadID)?.timeToFirstToken?.median {
            fastest.append("Fastest TTFT: \(first.id) (\(fixed(seconds)) s)")
        }
        if !fastest.isEmpty { print(fastest.joined(separator: " · ")) }
        if report.modelsDiffer(in: workloadID) {
            print("Note: the engines ran different models or quantizations, or Tonamox could not confirm they match; "
                  + "speed and output match compare more than the engine.")
        }
        let truncated = report.promptTruncationSuspects(in: workloadID)
        if !truncated.isEmpty {
            print("Note: \(truncated.joined(separator: ", ")) reported far fewer prompt tokens than the others; "
                  + "the server may have cut the prompt to fit its context (Ollama: num_ctx).")
        }
    }
}

// MARK: - Arguments

/// A `--server` value: `ollama`, `llama-server` or `magnitude`, optionally `:<model>`.
struct BenchServer {
    let kind: LocalProviderKind
    let model: String?
}

/// `tonamox bench`'s parsed arguments.
struct BenchRequest {
    let ggufArguments: [String]
    let mlxArguments: [String]
    let servers: [BenchServer]
    let allServers: Bool
    let workloads: [BenchmarkWorkload]
    let settings: BenchmarkSettings
    let json: Bool

    init(_ args: [String]) throws {
        let parsed = try CLIArguments(
            args,
            options: ["--gguf", "--mlx", "--server", "--workload", "--runs", "--temperature", "--max-tokens"],
            flags: ["--all-servers", "--json"])
        if let stray = parsed.positionals.first { throw CLIUsageError("unexpected argument \(stray)") }
        ggufArguments = parsed.values("--gguf")
        mlxArguments = parsed.values("--mlx")
        servers = try parsed.values("--server").map(Self.server)
        allServers = parsed.has("--all-servers")
        json = parsed.has("--json")
        workloads = try Self.workloads(parsed.value("--workload") ?? "all")

        let runs = try parsed.int("--runs") ?? 3
        guard (1...100).contains(runs) else { throw CLIUsageError("--runs expects 1…100.") }
        let temperature = try parsed.double("--temperature") ?? 0
        guard (0...2).contains(temperature) else { throw CLIUsageError("--temperature expects 0…2.") }
        let maxTokens = try parsed.int("--max-tokens")
        if let maxTokens, maxTokens < 1 { throw CLIUsageError("--max-tokens expects a positive integer.") }
        settings = BenchmarkSettings(measuredRuns: runs, temperature: Float(temperature), maxTokensOverride: maxTokens)
    }

    static func server(_ value: String) throws -> BenchServer {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let kind: LocalProviderKind
        switch parts.first?.lowercased() {
        case "ollama": kind = .ollama
        case "llama-server", "llamaserver": kind = .llamaServer
        case "magnitude": kind = .magnitude
        default: throw CLIUsageError("--server expects ollama, llama-server or magnitude, got \(value).")
        }
        let model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return BenchServer(kind: kind, model: model)
    }

    static func workloads(_ value: String) throws -> [BenchmarkWorkload] {
        switch value.lowercased() {
        case "all": return BenchmarkWorkload.all
        case "chat": return [.chat]
        case "code": return [.code]
        case "long": return [.longDocument]
        default: throw CLIUsageError("--workload expects chat, code, long or all, got \(value).")
        }
    }
}
