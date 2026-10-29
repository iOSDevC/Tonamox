import Foundation
import os

// MARK: - BenchmarkPrompt

/// What one run sends: a workload's prompts with the run marker in front of the system prompt.
struct BenchmarkPrompt: Sendable, Hashable {
    let system: String
    let user: String
    let maxTokens: Int

    /// `slot` counts the warm-up runs first. The marker comes first so a prompt cache diverges right after the chat
    /// template's opening.
    static func make(for workload: BenchmarkWorkload, slot: Int, nonce: String, maxTokens: Int) -> BenchmarkPrompt {
        BenchmarkPrompt(system: runMarker(workloadID: workload.id, slot: slot, nonce: nonce) + workload.systemPrompt,
                        user: workload.userPrompt, maxTokens: maxTokens)
    }

    /// ``runMarker(workloadID:slot:nonce:)`` with placeholders, for ``BenchmarkReport/runMarkerFormat``.
    static let runMarkerFormat = "[run {slot} {workload} {nonce}]\n"

    static func runMarker(workloadID: String, slot: Int, nonce: String) -> String {
        "[run \(slot) \(workloadID) \(nonce)]\n"
    }
}

// MARK: - Measuring runs

extension EngineBenchmark {

    /// One streamed generation of an in-process model. Timings and counts come from ``Tonamox/lastGenerationStats``;
    /// if it is missing, the run is timed here and its counts estimated.
    @MainActor
    static func measureInProcessRun(_ instance: Tonamox, prompt: BenchmarkPrompt) async throws -> BenchmarkRun {
        var clock = DeltaClock()
        for try await piece in instance.stream(prompt.user, systemPrompt: prompt.system, maxTokens: prompt.maxTokens) {
            try Task.checkCancellation()
            clock.record(piece)
        }
        try Task.checkCancellation()
        guard let stats = instance.lastGenerationStats else { return clock.run(usage: nil, prompt: prompt) }
        return BenchmarkRun(stats: stats, output: clock.text)
    }

    /// One streamed request to a server, timed client-side: time to first token from the request to the first
    /// non-empty delta, decode from the first delta to the last, reasoning deltas included in both. Counts come from
    /// the server's usage event when it sends one, otherwise from text length.
    nonisolated static func measureServerRun(
        provider: any RemoteLLMProvider, modelID: String, prompt: BenchmarkPrompt, temperature: Float
    ) async throws -> BenchmarkRun {
        let request = RemoteRequest(
            model: modelID, system: prompt.system, messages: [["role": "user", "content": prompt.user]],
            maxTokens: prompt.maxTokens, temperature: temperature)
        var clock = DeltaClock()
        var usage: TokenUsage?
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .token(let text): clock.record(text)
            case .reasoning(let text): clock.record(text, isReasoning: true)
            case .usage(let reported): usage = reported
            }
        }
        try Task.checkCancellation()
        return clock.run(usage: usage, prompt: prompt)
    }
}

// MARK: - DeltaClock

/// Times a stream of text deltas with a monotonic clock.
struct DeltaClock {
    private let start = ContinuousClock.now
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var answer = ""
    private var thinking = ""

    /// Empty deltas (role-only or finish chunks) are ignored. Reasoning deltas are timed like answer deltas: a
    /// server's usage counts their tokens, and in-process stats time them too.
    mutating func record(_ delta: String, isReasoning: Bool = false) {
        guard !delta.isEmpty else { return }
        let now = ContinuousClock.now
        if first == nil { first = now }
        last = now
        if isReasoning { thinking += delta } else { answer += delta }
    }

    /// The answer, after any reasoning wrapped in `<think>…</think>` as in-process engines stream it.
    var text: String {
        thinking.isEmpty ? answer : "<think>" + thinking + "</think>" + answer
    }

    /// A stream without text reports its whole duration as time to first token.
    func run(usage: TokenUsage?, prompt: BenchmarkPrompt) -> BenchmarkRun {
        let firstDelta = first ?? ContinuousClock.now
        return Self.run(
            timeToFirstToken: GenerationStats.seconds(firstDelta - start),
            decodeTime: last.map { GenerationStats.seconds($0 - firstDelta) } ?? 0,
            output: text, usage: usage, prompt: prompt)
    }

    /// Server-reported counts make the run ``GenerationStats/Provenance/runtime``; without them both counts are
    /// UTF-8 bytes ÷ 4 (the prompt's without its chat template) and the run is
    /// ``GenerationStats/Provenance/estimated``.
    static func run(
        timeToFirstToken: TimeInterval, decodeTime: TimeInterval, output: String, usage: TokenUsage?,
        prompt: BenchmarkPrompt
    ) -> BenchmarkRun {
        BenchmarkRun(
            timeToFirstToken: timeToFirstToken, promptTime: timeToFirstToken, decodeTime: decodeTime,
            promptTokens: usage?.inputTokens ?? GenerationStats.estimatedTokens(in: prompt.system + "\n" + prompt.user),
            generatedTokens: usage?.outputTokens ?? GenerationStats.estimatedTokens(in: output),
            source: usage == nil ? .estimated : .runtime, output: output)
    }
}

// MARK: - MemorySampler

/// Tracks this process's peak memory (``BenchmarkMemory``), polled off the main actor so a busy generation is still
/// sampled.
final class MemorySampler: Sendable {
    struct Readings {
        var overall: BenchmarkMemory?
        var window: BenchmarkMemory?
        var isWindowOpen = false
    }

    private let peaks = OSAllocatedUnfairLock(initialState: Readings())

    func record() {
        guard let sample = BenchmarkMemory.current() else { return }
        peaks.withLock { state in
            state.overall = sample.peak(with: state.overall)
            if state.isWindowOpen { state.window = sample.peak(with: state.window) }
        }
    }

    /// Polls every `interval` until the returned task is cancelled.
    func startPolling(every interval: Duration = .milliseconds(50)) -> Task<Void, Never> {
        record()
        return Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                record()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Opens a window for ``endWindow()``.
    func beginWindow() {
        peaks.withLock { state in
            state.window = nil
            state.isWindowOpen = true
        }
        record()
    }

    /// The peak since ``beginWindow()``, and closes the window; `nil` when none is open.
    func endWindow() -> BenchmarkMemory? {
        record()
        return peaks.withLock { state in
            defer {
                state.window = nil
                state.isWindowOpen = false
            }
            return state.window
        }
    }

    var overallPeak: BenchmarkMemory? {
        record()
        return peaks.withLock { $0.overall }
    }
}
