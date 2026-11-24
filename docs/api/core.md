---
layout: docs
title: TonamoxCore
parent: API Reference
nav_order: 1
description: "TonamoxCore API reference — Tonamox, ModelManager, ConversationStore, HardwareAnalyzer."
---

# TonamoxCore
{: .no_toc }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Tonamox

The main entry point. All methods are `@MainActor`.

### Factory Methods

```swift
// Load a text-generation model
static func text(
    _ model: Model = .qwen3_1_7b,
    temperature: Float? = nil,            // nil: backend default; 0 is greedy
    topP: Float? = nil,                   // nil: backend default; 0 < topP <= 1
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> Tonamox

// Load a vision model
static func vision(
    _ model: Model = .qwen35_0_8b,
    temperature: Float? = nil,
    topP: Float? = nil,
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> Tonamox

// Load an OCR/document-specialized model
static func specialized(
    _ model: Model = .fastVLM_0_5b_fp16,
    temperature: Float? = nil,
    topP: Float? = nil,
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> Tonamox
```

`temperature` and `topP` hold for the instance's lifetime and behave as in
[`ModelManager.load`](#loading); an out-of-range value throws `ModelConfigurationError` before loading.

The factories download MLX weights on first use but not GGUF files: an uncached GGUF throws *GGUF file not
found*. They also skip `ModelManager`'s cache and memory guard. Use `ModelManager.shared.load(_:)`, which
downloads, caches and applies the guard, or fetch the file first with [`ModelDownloads`](#modeldownloads).

### One-Liners

```swift
// Static chat — loads the model on each call, returns the reply
static func chat(
    _ prompt: String,
    model: Model = .qwen3_1_7b,
    systemPrompt: String? = nil,
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> String

// Static chat that stores the exchange; conversationID nil creates a new conversation
@discardableResult
static func chat(
    _ prompt: String,
    in conversationID: UUID? = nil,
    model: Model = .qwen3_1_7b,
    systemPrompt: String? = nil,
    store: ConversationStore = .shared,
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> (reply: String, conversationID: UUID)

// Static receipt/document extraction
static func extractDocument(
    _ image: PlatformImage,
    model: Model = .fastVLM_0_5b_fp16,
    onProgress: @escaping @MainActor (String) -> Void = { _ in }
) async throws -> String

// Parse DocTags output from Granite Docling
static func parseDocTags(_ raw: String) -> String
```

### Instance Methods

```swift
// Text generation (constraint: GGUF on llama.cpp only, see below)
func chat(_ prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024,
          constraint: GenerationConstraint? = nil) async throws -> String
func stream(_ prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024,
            constraint: GenerationConstraint? = nil) -> AsyncThrowingStream<String, Error>
// Awaitable stream: returns only after the backend stopped, cancellation included (for GenerationTurnstile.run)
func generate(_ prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024,
              onPiece: @escaping @MainActor (String) -> Void) async throws

// Vision (image nil = text-only)
func analyze(_ prompt: String, image: PlatformImage? = nil, maxTokens: Int = 800) async throws -> String
func streamVision(_ prompt: String, image: PlatformImage? = nil, maxTokens: Int = 800) -> AsyncThrowingStream<String, Error>
func extractDocument(_ image: PlatformImage, maxTokens: Int? = nil) async throws -> String   // nil: 2048 for DocTags models, else 600

// Multi-turn with conversation history
func chat(_ prompt: String, in conversationID: UUID, systemPrompt: String? = nil, maxTokens: Int = 1024,
          maxContextTokens: Int = 3072, store: ConversationStore = .shared) async throws -> String
func stream(_ prompt: String, in conversationID: UUID, systemPrompt: String? = nil, maxTokens: Int = 1024,
            maxContextTokens: Int = 3072, store: ConversationStore = .shared) -> AsyncThrowingStream<String, Error>
// Stopping iteration cancels the generation; what it produced is stored as the reply (see below).
```

When the consumer of `stream(_:in:)` stops early, the generation is cancelled and the conversation is settled as
for a `GenerationInterrupted`: the text generated until then becomes the assistant turn, and the user turn is removed
when there was none. Stopping means cancelling the task that iterates, or leaving the loop once nothing else holds
the stream: a stream kept in a variable or property is cancelled only when it is released, so stop one by cancelling
its task. These writes land after the loop has ended, so `chat(_:in:)` and `stream(_:in:)` on the same instance wait
for the previous `stream(_:in:)` to finish, a stopped one included, before they store their prompt. Streams consumed
outside history (`stream`, `streamVision`) store nothing and cancel their decode the same way.

On a GGUF instance with tools (`ModelManager.load(_:tools:)`, an `TonamoxProfile` with tools) whose call format runs on
LocalLLMClient's `LlamaClient` (for example Llama 3.1's or Mistral's), stopping cuts the reply and, in history, stores
it at once, but llama.cpp keeps decoding until the end of generation or a full context window, and the next turn on
that instance waits for it. With `<tool_call>` JSON templates (Qwen2.5's, and templates without tool support) the
decode stops as without tools: after at most one more token, or when a running prefill ends; see
[Multi-turn conversations]({{ '/guide/backends' | relative_url }}#multi-turn-conversations-gguf).

### Constrained Generation

```swift
public enum GenerationConstraint: Sendable, Equatable {
    case json                                          // a JSON object (LocalLLMClient's json.gbnf)
    case grammar(gbnf: String, root: String = "root")  // any GBNF grammar
}

public enum GenerationConstraintError: LocalizedError, Equatable {
    case unsupportedBackend(BackendKind)   // .mlx, .layerStreaming or .remote
    case invalidGrammar(root: String)      // blank, or rejected by llama.cpp
}
```

```swift
let json = try await llm.chat("Return a JSON object with name and age for: Ana, 31.",
                              maxTokens: 128, constraint: .json)
let verdict = try await llm.chat("Is 4 even? Answer yes or no.", maxTokens: 8,
                                 constraint: .grammar(gbnf: #"root ::= "yes" | "no""#))
```

Only `chat(_:systemPrompt:maxTokens:constraint:)` and `stream(_:systemPrompt:maxTokens:constraint:)` take a
constraint. Each constrained call runs on its own short-lived llama.cpp client; see
[Constrained generation]({{ '/guide/backends' | relative_url }}#constrained-generation-gguf-only) for why, what it
costs, and the limits.

{: .warning }
> Only `LlamaCppBackend` enforces a constraint. An MLX, layer-streaming or remote backend throws
> `GenerationConstraintError.unsupportedBackend` instead of answering unconstrained. `maxTokens` or a full context
> window still cuts the output, and a cut JSON object does not parse. A cancelled constrained call throws
> `CancellationError`.

### Tool calling (GGUF and MLX)

An instance loaded with tools (`ModelManager.shared.load(_:tools:)` with a GGUF model or an MLX text model) runs the
calls the model makes and feeds their results back. `toolLoop` sets how many rounds a turn may run and what a
failing tool does:

```swift
var toolLoop: ToolLoopOptions                         // read when a turn starts; no effect without tools
var onToolEvent: (@MainActor (ToolEvent) -> Void)?    // read when a turn starts; no effect without tools
var lastToolTurn: ToolTurnSummary? { get }            // nil without tools, before the first turn, after one that
                                                      // threw, and after a constrained call

public struct ToolLoopOptions: Sendable, Equatable {
    static let defaultMaxToolRounds = 1
    static let `default`: ToolLoopOptions
    var maxToolRounds: Int                // rounds per turn; negative counts as 0, and 0 runs none
    var toolErrors: ToolErrorHandling
    init(maxToolRounds: Int = ToolLoopOptions.defaultMaxToolRounds, toolErrors: ToolErrorHandling = .reportToModel)
}

public enum ToolErrorHandling: Sendable, Equatable {
    case reportToModel                    // the model receives {"error": "…"} and the turn goes on (default)
    case failTurn                         // the turn throws the error
}

public struct ToolInvocation: Sendable, Equatable, Identifiable {
    let id: String                        // the parser's call id; a UUID when the model gave none
    let round: Int                        // 1-based; for a skipped call, the round that did not run
    let name: String
    let arguments: String                 // the arguments JSON
}

public struct ToolCallResult: Sendable, Equatable {
    let call: ToolInvocation
    let output: String                    // exactly what the model received
    let isError: Bool
}

public enum ToolEvent: Sendable, Equatable {
    case started(ToolInvocation)
    case finished(ToolCallResult)
    case roundLimitReached(skipped: [ToolInvocation])
}

public struct ToolTurnSummary: Sendable, Equatable {
    let rounds: Int                       // at most maxToolRounds
    let results: [ToolCallResult]         // every call that ran, in order
    let skipped: [ToolInvocation]         // non-empty only when maxToolRounds ended the loop
}
```

```swift
let llm = try await ModelManager.shared.load(.llama3_1_8b_gguf, tools: [WeatherTool()])
llm.toolLoop = ToolLoopOptions(maxToolRounds: 3)
llm.onToolEvent = { event in
    switch event {
    case .started(let call): print("calling \(call.name) \(call.arguments)")
    case .finished(let result): print(result.isError ? "failed: \(result.output)" : "got \(result.output)")
    case .roundLimitReached(let skipped): print("not run: \(skipped.map(\.name))")
    }
}
let answer = try await llm.chat("What should I wear in Lima today?")
print(llm.lastToolTurn?.rounds ?? 0)
```

- A **round** is every call in one reply. The calls run one after another, in the order the model wrote them and
  off the main actor; then the model replies again over the whole conversation, its calls and their results
  included.
- The turn ends at a reply that asks for no tools, at a cut reply (`maxTokens`, which every round of the turn
  shares, or cancellation), or at a reply that asks for tools after `maxToolRounds` rounds. Those last calls do not
  run: `.roundLimitReached(skipped:)` fires and `lastToolTurn.skipped` lists them. The default, 1, runs as many
  rounds as before `ToolLoopOptions` existed.
- Every `.started` is followed by its `.finished` unless the turn throws. Events arrive on the main actor, in order,
  but not ordered relative to the streamed text.
- With `.reportToModel` a failing call becomes the result `{"error": "…"}` with `isError` set: the tool's own error
  description, the argument that did not decode (for example `Invalid arguments for tool "tap": x: expected Int`),
  or an unknown name with the tools that exist. With `.failTurn` the turn throws after `.finished`: the tool's own
  error, LocalLLMClient's `ToolError.argumentDecodingFailed`, or `LLMError.invalidParameter` for an unknown tool.
  A tool that throws `CancellationError` ends the turn with it under either setting.
- Output reaches the model as JSON with sorted keys and unescaped slashes. A value JSON cannot hold (a `Date`, a
  custom type, NaN) falls back to `key: value` pairs sorted by key.
- `ModelManager` never caches an instance with tools, so these settings belong to that instance alone. In a session,
  `TonamoxProfile.toolLoop`, `TonamoxSession.onToolEvent` and `TonamoxSession.lastToolTurn` do the same (see
  [TonamoxSession](#aurasession)).

{: .warning }
> Tools on an MLX vision or document model, or on any MLX model in the iOS Simulator, throw
> `ModelConfigurationError.toolsUnsupported(.mlx)`. On GGUF, models asked to write
> calls as `<tool_call>` JSON (Qwen2.5's template, and any template without tool support) run on Tonamox's own
> parser: every call in a reply runs, and a round's reply joins the conversation as the model wrote it. On a template
> that renders tool turns natively (Qwen2.5's) the next reply then decodes only what the round added while another
> round may run, and the reply after the last allowed round prefills the whole conversation; on a template without
> tool support each round's results join the reply's assistant turn, so every round prefills the whole conversation.
> Other formats run on LocalLLMClient's parser, which keeps only the first call per tool name in one reply, and every
> round prefills the whole conversation again. A tool's output is not capped: a large one makes the oldest exchanges
> drop out of the window, or overflows it. The native tool-turn format has been checked on Qwen2.5 only. See
> [Multi-turn conversations]({{ '/guide/backends' | relative_url }}#multi-turn-conversations-gguf).

{: .warning }
> On MLX, calls are parsed in the format mlx-swift-lm infers from the model's `config.json` (JSON in `<tool_call>`
> tags when it infers none): a model that writes another format gets no calls. With tagged formats (JSON in
> `<tool_call>`, xmlFunction, gemma…) a call whose text does not parse is dropped, neither run nor shown. With
> Llama 3's untagged format, a `{…}` that does not parse streams as text, and text after a `{` that never closes
> is lost at the end of the reply. Every call in a reply runs, the same tool twice included, and every generated
> token counts against `maxTokens`, call text included. The tools reach the template only as `tools`, so a
> template that ignores them leaves the model unaware of them. Each reply prefills only what the prompt cache does
> not hold. Checked on Qwen3 0.6B 4-bit only. See
> [Prompt cache and tool rounds]({{ '/guide/backends' | relative_url }}#prompt-cache-and-tool-rounds-mlx).

### History Methods

```swift
// Auto-generate a title from the first message
func autoTitle(conversationID: UUID, store: ConversationStore = .shared) async throws

// Summarize and prune long conversations
func summarizeAndPrune(
    conversationID: UUID,
    keepLastN: Int = 10,
    maxContextTokens: Int = 4096,
    store: ConversationStore = .shared
) async throws
```

### Properties

```swift
var model: Model { get }                           // the loaded model
var lastGenerationStats: GenerationStats? { get }  // the last generation that returned; nil after one that threw

// Opt-in guard checked before and during every generation; nil (default) is off.
// Instances from ModelManager without tools are shared per model and sampling setting, so this applies to every
// caller of that cached instance; a tool-enabled instance is never shared.
var deviceGuard: DeviceConditions?

// Set when the last generation outgrew the MLX KV window (which drops old tokens silently);
// nil when it fit, the model does not run on MLX, its architecture ignores the window (for example
// Qwen3.5 text, Gemma 3/4 and LFM2 keep their own caches, so nothing was dropped),
// or the last generation threw.
var lastContextOverflow: ContextWindowOverflow? { get }

// The KV window the loaded model got on this device: llama.cpp's n_ctx for GGUF (chosen at load from free
// memory), the rotating cache's size for MLX; nil before a load and for remote models. Prompt, reasoning
// budget and answer share it.
var contextWindow: Int? { get }
```

### Generation Stats

Token counts and timings of the last generation, labelled with where they come from. Read them after `chat`
returns or a stream finishes:

```swift
for try await delta in llm.stream("Summarize this in one line.") { print(delta, terminator: "") }
if let stats = llm.lastGenerationStats {
    print(stats.source.label, stats.timeToFirstToken, stats.decodeTokensPerSecond ?? 0)
}
```

```swift
public struct GenerationStats: Sendable, Hashable {
    public enum Provenance: String, Sendable, Hashable, CaseIterable {
        case runtime    // exact token counts (MLX); prefill and decode timed by Tonamox
        case measured   // Tonamox's clock around the stream; output counted per piece; prompt estimated
        case estimated  // counts from text length (UTF-8 bytes ÷ 4)
        var label: String
    }
    let backend: BackendKind
    let source: Provenance
    let promptTokens: Int              // tokens prefilled; exact only for .runtime
    let generatedTokens: Int           // stop token excluded
    let promptTime: TimeInterval       // prefill through the first token; equals timeToFirstToken unless .runtime
    let timeToFirstToken: TimeInterval // from when the backend starts the request; includes template + tokenization
    let decodeTime: TimeInterval       // first generated token to last
    var decodeTokensPerSecond: Double?  // (generatedTokens − 1) ÷ decodeTime; nil below two tokens
    var prefillTokensPerSecond: Double? // promptTokens ÷ promptTime; on an MLX prompt-cache hit promptTime covers
                                        // only the prefilled tokens, so this overstates prefill speed
}
```

| Backend | `source` | Prompt tokens | Output tokens | Durations |
|---|---|---|---|---|
| `MLXBackend` | `.runtime` | exact, the whole prompt | exact | Tonamox's clock around mlx-swift-lm's token iterator. On a prompt-cache hit `promptTime` covers only the tokens prefilled; a tool turn sums prefill and decode over its replies and counts the last reply's prompt |
| `LlamaCppBackend`, no tools; constrained calls | `.measured` | estimated from the text prefilled: the rendered prompt, or only its new part when the KV cache was reused | one per streamed piece (one per sampled token in LocalLLMClient 0.5.0) | Tonamox's clock |
| `LlamaCppBackend` / `LayerStreamingBackend` with tools | `.estimated` | estimated from the text the last round prefilled, as above | estimated | Tonamox's clock |
| `LayerStreamingBackend`, no tools | `.measured` | estimated from the text prefilled, as above | one per streamed piece | Tonamox's clock |
| Remote (`HybridEscalator`) | — | — | — | no stats; provider-reported usage is in `HybridEscalator.Result.usage` |

LocalLLMClient 0.5.0 exposes no tokenizer or prompt count, so llama.cpp prompt counts stay estimates. A constrained
call's clock starts after its dedicated client loads. `InferenceBackend` gained `var lastGenerationStats:
GenerationStats? { get }`, `var lastContextOverflow: ContextWindowOverflow? { get }` and `var contextWindow: Int?
{ get }`, each with a public protocol-extension default of `nil`. It also requires `generate(prompt:systemPrompt:maxTokens:constraint:onToken:)`
with no default, so a conformer written before constrained generation must add it; throwing
`GenerationConstraintError.unsupportedBackend` is enough. No public API accepts a custom backend.

Loaded state is queried on `ModelManager`, not on `Tonamox`:

```swift
// Whether a model's weights are currently held in memory.
ModelManager.shared.isLoaded(_ model: Model) -> Bool
```

### Engine benchmark

`EngineBenchmark` runs the same workloads through several engines, one at a time, and reports which is fastest
on this device. `tonamox bench` is its command-line front end, and TonamoxExample's **Compare engines** screen
(Chat's model sheet) a SwiftUI one.

```swift
let statuses = await LocalProviderDetector.detectAll()
var candidates: [BenchmarkCandidate] = [.inProcess(.qwen3_4b)]
if let server = statuses.first(where: \.isAvailable), let model = server.models.first(where: \.runsLocally) {
    candidates.append(.server(server, model: model))
}
let benchmark = EngineBenchmark(candidates: candidates, workloads: BenchmarkWorkload.all,
                                settings: BenchmarkSettings(measuredRuns: 3, temperature: 0))
let report = await benchmark.run { event in
    if case .running(let progress) = event { print(progress.summary) }  // "Ollama (2/2) · chat · run 1/3"
}
print(report.fastestDecode(in: "chat")?.label ?? "no result", report.modelsDiffer(in: "chat"))
```

- **Candidates.** `.inProcess(_ model:)` has `ModelManager` load an instance of its own: weights not on disk are
  downloaded and the memory budget applies, as in `ModelManager.load(_:tools:temperature:topP:onProgress:)`, but
  the instance never comes from or goes into the cache. `BenchmarkCandidate(label:weights:load:)` takes any loader
  that returns a `Tonamox` for the benchmark's temperature. `.server(_:model:)` uses
  `OpenAICompatibleProvider.from(_:)`; `BenchmarkCandidate(label:weights:provider:modelID:kind:)` takes any
  `RemoteLLMProvider`. `weights` (`BenchmarkModelIdentity`: name, format, quantization) is what
  `modelsDiffer(in:)` compares.
- **Fairness.** Candidates never overlap. An in-process model is released with `ModelManager.release(_:)` after its
  last run, before the next candidate loads. `.inProcess(_:)` never reuses or releases an instance the app holds,
  though `ModelManager` may evict the app's models to make room, as for any load. Each workload runs
  `warmUpRuns` warm-up runs (default 1), kept in `BenchmarkWorkloadResult.warmUpRuns` but left out of its metrics,
  then `measuredRuns` (default 3). Every run's system prompt starts with a run marker
  (`BenchmarkReport.runMarkerFormat`, `[run {slot} {workload} {nonce}]` and a newline, with the candidate's
  `runMarkerNonce`) unique among the candidate's runs and shared by the same run of every candidate, so outputs stay
  comparable and prompt caches share at most the chat template's opening. Every candidate gets the same prompts,
  temperature and token budget (`maxTokensOverride` replaces the workloads' own).
- **Results.** `BenchmarkReport` (`hasMeasuredRuns`) → `BenchmarkCandidateResult` (`loadSeconds`, a download
  included; `coldTimeToFirstToken`, `loadSeconds` plus the first run's time to first token, or for a server that
  first run's alone; `loadError`; `memoryBeforeLoad` and `peakMemory`) → `BenchmarkWorkloadResult` (`BenchmarkMetric`
  median / minimum / maximum of the measured runs' time to first token, prefill and decode tok/s and token counts;
  `warmUpRuns`; `source`, the least exact provenance; `peakMemory` during the measured runs; `failure`;
  `agreement`) → `BenchmarkRun`. In-process runs report `lastGenerationStats`. Server runs are timed client-side
  (`BenchmarkTiming.clientSide`): first non-empty delta, then the last, reasoning deltas (`RemoteEvent.reasoning`)
  included; counts come from the server's usage (`.runtime`) or from text length (`.estimated`). A server run's
  `output` starts with its reasoning inside `<think>…</think>`, as an in-process engine streams it.
  `OutputAgreement` compares each first measured output with the first candidate that produced one, ignoring
  whitespace around the `<think>` tags and an empty block: `.exact`, `.partial(commonPrefixRatio:)`, or
  `.notApplicable` above temperature 0. `promptTruncationSuspects(in:)` lists candidates whose exact (`.runtime`)
  prompt count is under 70 % of the largest exact one.
- **Comparing engines.** Time to first token is the cross-engine figure. `hasExactPrefill(in:)` is `true` only for
  an in-process MLX model, which times prefill itself; elsewhere prefill tok/s is prompt tokens over the time to
  first token (llama.cpp in process: an estimated count; servers: client-side, HTTP included). `BenchmarkMemory`
  holds `footprintBytes` (`phys_footprint`) and `residentBytes` (`resident_size`) of this process, servers not
  measured. Neither includes all of the weights: on an M1 Pro a 15.2 GB GGUF grew footprint by 0.77 GB and resident
  by 2.96 GB, and which one counts MLX's Metal buffers has not been measured, so neither figure alone compares the
  two engines.
- **JSON.** The report is `Codable`. `OutputAgreement` encodes as `{"kind": "partial", "commonPrefixRatio": 0.82}`
  (`kind`: `reference`, `exact`, `partial`, `notApplicable`, `unavailable`), and a `BenchmarkRun` also encodes its
  `decodeTokensPerSecond` and `prefillTokensPerSecond`, which decoding recomputes.
- **Failures and cancellation.** `run` never throws: a failed load or run is stored in the report and the next
  workload or candidate goes on. Cancelling the task stops the stream in flight and returns the partial report with
  `wasCancelled`. It also cancels an in-process model's load: an MLX download stops between files, while a GGUF download
  and a load that cannot stop partway finish, and the model is released without running.

---

## ModelManager

Shared singleton for loading and caching models. Preferred over direct `Tonamox` factory calls — prevents redundant downloads and handles memory pressure.
Guide: [Memory Management]({{ '/guide/memory' | relative_url }}).

```swift
@MainActor
public final class ModelManager: ObservableObject
```

### Loading

```swift
// Load a model — returns cached instance if already loaded with the same sampling
// For GGUF models, downloads the file from HuggingFace first
func load(
    _ model: Model,
    tools: [any LLMTool] = [],            // GGUF or MLX text models; instances with tools are never cached
    temperature: Float? = nil,            // nil: backend default; 0 is greedy
    topP: Float? = nil,                   // nil: backend default; 0 < topP <= 1
    onProgress: (@MainActor (String) -> Void)? = nil
) async throws -> Tonamox

public enum ModelConfigurationError: LocalizedError, Equatable, Sendable {
    case toolsUnsupported(BackendKind)    // tools with an MLX vision or document model
    case invalidTemperature(Float)        // negative, infinite or NaN
    case invalidTopP(Float)               // outside 0 < topP <= 1, or NaN
}

// Separate from TonamoxError so exhaustive switches over it keep compiling.
public struct IncompatibleGGUFError: LocalizedError, Equatable, Sendable {
    let filename: String
    let blockers: [CompatibilityFinding]  // gguf.architecture, read from the file's header
    let underlyingMessage: String         // LocalLLMClient's "Failed to load model from file"
}
```

`load` checks `tools` and the sampling values first and throws `ModelConfigurationError` before
downloading anything. `temperature` and `topP` hold for the instance's lifetime: a GGUF builds its sampler when
the context is created. `nil` keeps the backend default (GGUF 0.7 / 0.95; MLX 0.7 for text, 0.1 for vision,
0 for OCR, top-p off). Each model and setting is its own cached instance, a separate load of the model; see
[Sampling]({{ '/guide/backends' | relative_url }}#sampling-temperature-and-top-p).

Before downloading, `load` throws `TonamoxError.modelTooLarge` when `HardwareAnalyzer` rates the model
`.tooLarge` on its own. It keeps at most `memoryBudget` instances loaded (a model at two settings counts twice)
and evicts the least recently used to make room. On iOS, where `HardwareProfile.current()` reports the app's
memory limit, it also evicts least-recently-used models until the new one is no longer `.tooLarge` beside the
ones that stay
([Memory Management]({{ '/guide/memory' | relative_url }})).

When llama.cpp fails to load a GGUF whose header the `gguf.architecture` rule blocks (other
than "not a chat model"), `load` throws `IncompatibleGGUFError` instead of LocalLLMClient's `LLMError.failedToLoad`,
as do the `Tonamox` factories; `EngineBenchmark` stores its message in `loadError`. The blocker comes from the header
alone, not from llama.cpp's own reason ([details]({{ '/guide/models' | relative_url }}#what-it-checks)).

{: .warning }
> `tools` run on GGUF models and MLX text models. With an MLX vision or document model, or any MLX model in the iOS
> Simulator, `load` throws `ModelConfigurationError.toolsUnsupported(.mlx)`. An MLX instance with tools runs on the
> weights of a cached instance of the same model when there is one, instead of loading them again; the two generate
> one at a time, and the weights stay in memory until both are released.

### State Observation

```swift
@Published private(set) var states: [Model: ModelLoadState]

func state(for model: Model) -> ModelLoadState

public enum ModelLoadState: Equatable {
    case idle
    case downloading(progress: String)   // human-readable progress text
    case loading
    case ready
    case failed(String)

    var isActive: Bool { get }           // .downloading or .loading
}
```

`ModelLoadingOverlay(model:)` is a SwiftUI view that shows a spinner and the progress text while that
model's state `isActive`, and nothing otherwise.

The state is per model, not per sampling setting. While another temperature or top-p of a loaded model loads,
the state reports that load, and it returns to `.ready` when that load fails or is cancelled (`cancelLoad`
included) as long as another setting of the model is still cached.

### Backend Query

```swift
// Which backend will be used for a model on the current device
func recommendedBackend(for model: Model) -> BackendKind

public enum BackendKind: String, Sendable {
    case mlx
    case llamaCpp
    case layerStreaming
    case remote   // cloud, or the user's own llama-server / Ollama / Magnitude
    case hybrid   // local backend that can escalate single requests
}
// recommendedBackend(for:) returns only .mlx, .llamaCpp or .layerStreaming.
```

### Eviction

```swift
func evict(_ model: Model)               // every sampling setting the model is loaded with
func evictAll()
func evictAllButMostRecent()             // also runs on memory pressure or a memory warning
func release(_ instance: Tonamox)      // unloads one instance; drops the cache entry only if it is the shared one
private(set) var memoryBudget: Int       // max instances kept loaded (1–4; one per model and sampling setting),
                                         // sized once from available memory
```

### GGUF Download Progress

```swift
// Detailed download progress for GGUF models
let ggufDownloader: GGUFModelDownloader

func cancelLoad(_ model: Model)          // also cancels the GGUF download
func pauseDownload()
func resumeDownload()
var isDownloadPaused: Bool { get }
var isDownloading: Bool { get }          // false while paused

// GGUFModelDownloader published properties (read-only):
@Published private(set) var progress: Double           // 0.0–1.0
@Published private(set) var downloadedBytes: Int64
@Published private(set) var totalBytes: Int64
@Published private(set) var isDownloading: Bool
@Published private(set) var isPaused: Bool
@Published private(set) var error: String?
```

---

## ConversationStore

SQLite-backed store for persistent chat history. Actor-isolated.
Guide: [Conversations & History]({{ '/guide/conversations' | relative_url }}).

The default store (`shared`, or `directory: nil`) is in the App Group's container once
`TonamoxSharedStorage.configure(appGroup:)` applied one, and copies the app's private history in once (see
[TonamoxSharedStorage](#tonamoxsharedstorage)). Connections wait up to 3 s for another connection's lock
(`busy_timeout`). While an App Group app is in the background (iOS), each call opens the database, runs inside its own
background task and closes it again; the default store also closes its idle connection on entering the background.
Every write posts `TonamoxSharedStorage.didChangeNotification` with `.conversations`.

```swift
public actor ConversationStore
static let shared: ConversationStore
```

### Conversations

```swift
func createConversation(model: Model, title: String = "New conversation") async throws -> Conversation
func allConversations() async throws -> [Conversation]
func conversation(id: UUID) async throws -> Conversation?
func updateTitle(_ title: String, for id: UUID) async throws
func deleteConversation(id: UUID) async throws
```

### Messages

```swift
init(directory: URL? = nil)                   // nil = <Application Support>/AuraLocal/conversations.sqlite, in the
                                              // App Group's container once one is configured
// Optional: every call opens the database when needed. On a store from an earlier version it replaces the
// full-text triggers and rebuilds the search index once.
func open() async throws
func close() async
@discardableResult func appendTurn(_ turn: Turn) async throws -> Turn
func deleteTurn(id: UUID) async throws
func turns(for conversationID: UUID) async throws -> [Turn]   // oldest first; insertion order within one millisecond
func contextWindow(for conversationID: UUID, maxTokens: Int = 2048) async throws -> [Turn]  // system turns + newest that fit
func pruneAndSummarize(conversationID: UUID, keepLastN: Int = 10, summary: String) async throws
func stats(for conversationID: UUID) async throws -> ConversationStats  // turnCount, totalTokenEstimate, oldestTurn, newestTurn
func search(_ query: String, limit: Int = 20) async throws -> [Turn]
func searchAgentMemory(_ query: String, limit: Int = 8) async throws -> [Turn]   // "AgentCrew:" conversations only
```

`search` and `searchAgentMemory` return turns containing any of the query's words, best match first (FTS5); each
word is quoted, so FTS5 operators in the query are plain text. `deleteTurn`, `deleteConversation` and
`pruneAndSummarize` remove the turns from the index too. Earlier versions left deleted turns in it, so a search
could return a later turn in their place or end early; opening such a store repairs the index. A read that returns
rows (`search`, `searchAgentMemory`, `turns(for:)`, `contextWindow`, `allConversations`, `conversation(id:)`) and
fails part-way throws `StoreError.sqliteError` instead of returning the rows read so far.

### Types

```swift
public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    let model: String          // Model.rawValue
    let createdAt: Date
    var updatedAt: Date
    var turnCount: Int
}

public struct Turn: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let conversationID: UUID
    let role: Role          // .user / .assistant / .system
    let content: String
    let createdAt: Date
    let tokenEstimate: Int

    init(id: UUID = UUID(), conversationID: UUID, role: Role, content: String,
         createdAt: Date = Date(), tokenEstimate: Int? = nil)   // nil = about 4 characters per token

    public enum Role: String, Codable, Sendable { case system, user, assistant }
}
```

---

## TonamoxSession

A conversation that can switch `TonamoxProfile`s mid-session; the engine is rebuilt for the new
profile. `TonamoxSession` keeps no history: each `stream` call is a single turn with no earlier
messages. `conversationID` stays the same across switches, as a key for you to store turns under
(for example in `ConversationStore`).

```swift
@MainActor
public final class TonamoxSession
init(conversationID: UUID = UUID(),
     profile: TonamoxProfile,
     makeEngine: @escaping @MainActor (TonamoxProfile) async throws -> any TonamoxProfileEngine = TonamoxSession.liveEngine) async throws

let conversationID: UUID
private(set) var profile: TonamoxProfile
var maxRepairAttempts: Int = 2     // re-prompts after a reply that breaks profile.outputSchema
var usesSchemaGrammar: Bool = true // GGUF in full, no tools: decode under a grammar built from outputSchema

func switchProfile(to newProfile: TonamoxProfile) async throws
func stream(_ prompt: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error>
func cancel()
var onToolEvent: (@MainActor (ToolEvent) -> Void)?    // handed to the engine when a profile with tools streams
private(set) var lastToolTurn: ToolTurnSummary?       // the last generation's; with an outputSchema, its last attempt
```

`stream` sends `profile.instructions` as the system prompt and defaults `maxTokens` to
`profile.sampling.maxTokens`. The default `makeEngine`, `TonamoxSession.liveEngine`, loads the model through
`ModelManager` with the profile's tools and `sampling.temperature` and `sampling.topP`. `init` and
`switchProfile` throw `ModelConfigurationError` for tools on an MLX vision or document model (or any MLX model in
the iOS Simulator) or an out-of-range temperature or top-p before building or tearing down an engine, whatever
`makeEngine` is. One generation runs at a time: a new
`stream` or a `switchProfile` cancels the previous one and waits for it to stop, also after `cancel()`, which returns without
waiting. A `stream` or `switchProfile` called while a switch is rebuilding the engine waits for it,
so that stream runs on the new profile. After a switch fails to build its engine, `stream` throws
`TonamoxError.modelNotLoaded` until a later `switchProfile` succeeds.

With tools, each stream gives the engine `profile.toolLoop` and `onToolEvent` (see
[Tool calling](#tool-calling-gguf-and-mlx)); a `switchProfile` to a profile that differs only in `toolLoop` applies it
without rebuilding the engine.

### TonamoxProfile

```swift
public struct TonamoxProfile: Sendable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var instructions: String            // the system prompt
    var model: Model
    var sampling: SamplingParams        // temperature + topP at load, maxTokens per turn; topK, contextOverride unused
    var tools: [any LLMTool]            // GGUF or MLX text; an MLX vision/document model throws ModelConfigurationError
    var outputSchema: OutputSchema?
    var escalation: EscalationPolicy    // default .off
    var toolLoop: ToolLoopOptions       // default: 1 round; tool errors reported to the model
}

public enum OutputSchema: Sendable, Equatable, Codable {
    case json(String)                   // a JSON Schema document
}
```

`TonamoxProfileCatalog.chat(model:)`, `.agent(model:tools:)` and `.securityReview(model:)` build the
common profiles.

### Structured output

With `outputSchema` set, `TonamoxSession` enforces the schema by **validation and repair** on every
backend. On a GGUF model loaded in full (`LlamaCppBackend`), and for a profile without tools, it also
**constrains decoding** with a GBNF grammar that Tonamox builds from the compiled schema (see
[Schema grammars](#schema-grammars) below). Elsewhere the model can write anything, and the session
checks what comes back.

1. `init` and `switchProfile` compile the schema before building an engine. A schema that does not
   compile throws `OutputSchemaError` and leaves the current profile and engine untouched. A
   `switchProfile` that fails to build the new engine has already torn the old one down; the
   session recovers on the next successful `switchProfile`.
2. `stream` appends the schema to the system prompt with an instruction to reply with a single
   JSON value, decodes under the schema grammar when it applies, buffers the whole reply, and looks
   for a conforming JSON value in it (see below).
3. A reply that breaks the schema is sent back with the original prompt and the list of
   violations, up to `maxRepairAttempts` times. Each repair is a full extra generation, under the
   grammar too.
4. The stream yields **one** element, the conforming JSON text, or finishes throwing
   `OutputSchemaError.violations(output:violations:)` for the last reply.

Without a schema, `stream` yields deltas as they are generated.

```swift
let profile = TonamoxProfile(
    id: "extract", displayName: "Extract",
    instructions: "Extract the person mentioned in the text.",
    model: .qwen3_1_7b,
    sampling: .precise,
    outputSchema: .json(#"""
        {"type": "object",
         "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 0}},
         "required": ["name", "age"], "additionalProperties": false}
        """#))

let session = try await TonamoxSession(profile: profile)
for try await json in session.stream("Ana turned 30 last week.") {
    print(json)   // e.g. {"name": "Ana", "age": 30}
}
```

`Tonamox.chat` and `Tonamox.stream` do not read profiles. To check their output, use the
validator directly:

```swift
public struct OutputSchemaValidator: Sendable {
    init(_ schema: OutputSchema) throws(OutputSchemaError)
    func validate(_ json: String) -> [OutputSchemaViolation]                     // empty = conforms
    func conformingJSON(in output: String) throws(OutputSchemaError) -> String  // first candidate that conforms
    static func extractJSON(from output: String) -> String?                      // first candidate that parses
}

public struct OutputSchemaViolation: Sendable, Equatable, CustomStringConvertible {
    let path: String       // JSON pointer (RFC 6901); "" is the whole value
    let message: String
}

public enum OutputSchemaError: Error, LocalizedError, Sendable, Equatable {
    case invalidSchema(String)            // not JSON (a GBNF grammar, say), or a malformed keyword value
    case unsupportedKeywords([String])    // JSON pointers into the schema
    case violations(output: String, violations: [OutputSchemaViolation])
}
```

Supported keywords:

| Keywords | Notes |
|----------|-------|
| `type` | A name or an array of names. `integer` accepts whole numbers, including `3.0` |
| `properties`, `required`, `additionalProperties` | `additionalProperties` is a boolean or a schema |
| `items`, `minItems`, `maxItems` | `items` is one schema; the tuple (array) form is rejected |
| `enum`, `const` | |
| `minLength`, `maxLength` | Counted in Unicode scalars |
| `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` | The exclusive bounds are numbers, not booleans |
| `anyOf`, `oneOf`, `allOf` | |
| `description`, `title`, `$schema`, `examples`, `default`, `$comment` | Accepted and ignored |

Any other keyword (`$ref`, `$defs`, `pattern`, `format`, `patternProperties`, `if`/`then`/`else`,
`not`, …) makes compilation throw `unsupportedKeywords`, so no constraint is skipped silently.
`true` and `false` work as schemas anywhere a schema does.

Candidates, in order: the whole reply; then, with reasoning removed (`<think>…</think>` and
`<thought>…</thought>` spans anywhere, tag names in any case, a leading block closed by a lone closing
tag, an unclosed opening tag to the end), the whole reply again,
each ```` ```json ```` (or unlabelled) fenced block, and each top-level balanced `{…}` or `[…]`.
Brackets inside strings are skipped, and values nested in one that parsed are not candidates.
`extractJSON` returns the first candidate that parses. `conformingJSON` and `TonamoxSession` take the
first that conforms and, when none does, report the violations of the first that parsed, so a
citation such as `[1]` or a draft inside a reasoning block does not hide the answer.

Parsing is strict RFC 8259: trailing commas, comments, single quotes, `NaN` and duplicate member
names make a candidate not JSON, so the text `conformingJSON` returns reads the same in any
conforming parser. Nesting deeper than 512 levels is rejected. Numbers compare as exact decimals:
`9007199254740993` does not equal `9007199254740992`, and `1e400` is a valid number.

#### Reasoning and answer

`ReasoningSplitter` separates the reasoning a model writes before its answer, for a UI that shows it
apart (TonamoxTerminal folds it into a collapsible block). It is a pure value type: feed it chunks as
they stream, or split a finished string.

```swift
public struct ReasoningSplitter: Sendable {
    enum Piece: Sendable, Equatable {
        case reasoning(String)
        case answer(String)
        case answerRetracted          // the answer so far was reasoning; it follows as .reasoning
    }
    init()
    static func split(_ text: String) -> ReasoningSplitter   // consume(text) + finish()
    mutating func consume(_ chunk: String) -> [Piece]
    mutating func finish() -> [Piece]                         // releases held bytes
    private(set) var reasoning: String                        // blocks joined by a blank line
    private(set) var answer: String
    private(set) var blockCount: Int
    private(set) var isReasoningUnterminated: Bool            // the stream ended inside a block
    private(set) var isFinished: Bool
    var hasReasoning: Bool { get }
    var isInsideReasoning: Bool { get }                       // a block is open right now
}

var splitter = ReasoningSplitter()
for try await chunk in stream { _ = splitter.consume(chunk); show(splitter.reasoning, splitter.answer) }
_ = splitter.finish()
```

Rules:

- Blocks are `<think>…</think>` and `<thought>…</thought>`; tag names ignore ASCII case, and a block
  closes only with its own name. `<thinking>`, `<thoughtful>` and `<think >` are not tags.
- Only leading blocks count: optional whitespace, then one or more blocks with optional whitespace
  between them. The first other character starts the answer, and from there no tag is special: a tag
  later in the answer or inside a code fence is answer text.
- Inside a block, an opening tag of the same name nests, and the block ends at the closing tag that
  balances it. A reasoning that mentions only `<think>` therefore never closes (fail-safe: no answer,
  rather than reasoning in the answer).
- In output that does not start with a block, the first closing tag ends a block the chat template
  opened in the prompt: the text before it becomes reasoning. Streaming has already yielded that text
  as answer, so `consume` returns `.answerRetracted` and then the text as `.reasoning`. This holds
  wherever the tag appears, inside a code fence too and after an opening tag, so an answer that merely
  mentions a closing tag loses the text before it to the reasoning.
- When the prompt itself ends with the opening tag, feed that tag before the output so it starts inside
  the block: `Tonamox.promptOpenedReasoningTag` (`String?`, `"<think>"` or `"<thought>"`) reports it
  for a loaded GGUF whose chat template does this. It is `nil` before a load and for MLX and remote
  models, which are not inspected; for those, reasoning cut off by the token limit before its closing
  tag reads as answer.
- A block that never closes makes the rest reasoning: after `finish()`, `isReasoningUnterminated` is
  true and `answer` is empty.
- Whitespace before and between blocks and before the answer is dropped (ASCII whitespace, U+00A0,
  U+200B, U+3000 and a byte order mark); block text and the end of the answer are kept as written, so
  trim the reasoning for display.
- While streaming it holds back at most nine bytes, the longest proper prefix of `</thought>`, so a tag
  split across chunks never shows up as text; `finish()` releases them (a final `<` becomes answer).
  Any chunking gives the same result as `split`.

#### Reasoning control

GGUF instances (llama.cpp and layer streaming) can switch thinking off and cap the reasoning separately from the
answer. MLX, Apple Intelligence and remote instances ignore these options (`reasoningSupport` is `.unsupported`).

```swift
public struct ReasoningOptions: Sendable, Hashable, Codable {
    enum ThinkingMode: String { case automatic, disabled }
    var thinking: ThinkingMode
    var budget: Int?                       // reasoning tokens before the block is closed; nil: no own budget
    init(thinking: ThinkingMode = .automatic, budget: Int? = nil)   // a negative budget counts as 0
    static let automatic                   // template default, no budget: the behaviour before this API
    static let disabled
    static func budgeted(_ tokens: Int) -> ReasoningOptions
}
public struct ReasoningCapabilities: Sendable, Hashable {
    let canDisableThinking: Bool           // rendering `enable_thinking = false` changes the prompt
    let enforcesBudget: Bool               // the backend closes a block at its budget
    static let unsupported
}
public struct ReasoningTurn: Sendable, Hashable {
    let renderedWithoutThinking: Bool      // the template got enable_thinking = false
    let budget: Int?                       // 0 when thinking was disabled without a budget
    let reasoningTokens: Int               // pieces inside the leading block; the forced close is not counted
    let answerTokens: Int
    let wasCut: Bool                       // the budget closed the block for the model; false for budget 0
}

// On Tonamox:
var reasoning: ReasoningOptions            // default for calls without options; read when a turn starts
var reasoningSupport: ReasoningCapabilities
var lastReasoningTurn: ReasoningTurn?      // nil before a generation, after one that threw, a constrained call
func promptOpenedReasoningTag(for options: ReasoningOptions) -> String?
func generate(_ prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024,
              reasoning: ReasoningOptions? = nil, onPiece: @escaping @MainActor (String) -> Void) async throws
```

- **Thinking off.** `.disabled` renders the GGUF's chat template with `enable_thinking = false` when that changes
  the prompt (Qwen3, LFM2.5, LFM3 and others; `reasoningSupport.canDisableThinking`). The check renders one user turn
  both ways when the model loads, so a template that only names the variable, or whose default is already off, does
  not count. Nothing is added to the user's message. Without a budget of its own, any reasoning block the model
  still opens (or the prompt opens, on a template without the switch) is closed at once, as with a budget of 0, and
  `lastReasoningTurn.budget` is 0. A budget of 0 is not a cut: `wasCut` stays `false`.
- **Budget.** With `budget` set, `maxTokens` is the answer's: the reasoning may take up to `budget` tokens on top.
  When the reasoning reaches the budget still inside its block, the engine decodes
  `"\n\nConsidering the limited time by the user, I have to give the solution based on the thinking directly now.\n</think>\n\n"`
  (the block's own closing tag, one per nesting level) into the context as if the model had written it, and keeps
  decoding the answer. The sentence is the one Qwen's thinking-budget guide uses: with a bare closing tag LFM3-1.7B
  went on reasoning in the answer. The stream gets the close without the sentence (`"\n</think>\n\n"`) as one more
  piece, so a reader never sees it as the model's words. Budget 0 decodes and streams `"</think>\n\n"` alone, which
  leaves the block empty, as a template renders thinking off. The close waits for a piece that is not empty (the
  sampler holding part of a UTF-8 character) and for a half-written tag to resolve. A block the model reopens after
  the close is closed once more with the bare tag; a third block ends the reply. In a tool loop every round shares
  the one budget. The turn produces at most `maxTokens + budget + 1` pieces (`Int.max` when that overflows). Without
  a budget nothing changes: reasoning counts against `maxTokens`.
- History is trimmed to keep `maxTokens` free for the reply, plus the budget only when the prompt itself opens a
  reasoning block; a model that opens one on its own may then fill the window, which ends its reply. Under memory
  pressure layer streaming caps the answer at 256 tokens and the budget at a quarter of that cap.
- The forced close happens in Tonamox's own turn engine, token by token on the `Context`. llama.cpp b12407's
  `common/reasoning-budget` sampler is C++ in `common/` and LocalLLMClient's sampler chain does not include it, so it
  is not reachable without changing the fork. A GGUF loaded with tools whose calls are not `<tool_call>` JSON decodes
  through LocalLLMClient's `LlamaClient`, which cannot be interrupted mid-reply: there the budget is ignored, the
  whole reply is capped at `maxTokens` and reasoning is only counted (`enforcesBudget == false`). The forced decode
  does not wait for LocalLLMClient's background pause, which the fork keeps internal (TD-068).
- `promptOpenedReasoningTag` follows `reasoning`; pass the call's options to `promptOpenedReasoningTag(for:)`
  before feeding a `ReasoningSplitter`: a template rendered without thinking usually closes the block itself
  (LFM3 ends the prompt with `<think></think>`).
- MLX: not implemented. `MLXDecodeLoop` owns its token loop, so a forced close is possible there (TD-067).

#### Boxed answers

`BoxedAnswer` unwraps the LaTeX `\boxed{…}` that math-tuned models write in plain chat:

```swift
public enum BoxedAnswer {
    static func display(_ text: String) -> String   // each box's content as **bold**, its own marks escaped
    static func plain(_ text: String) -> String     // the content alone, for copying
    static func containsBox(_ text: String) -> Bool
}
```

Fenced code blocks and inline code spans are untouched. Braces nest and `\{`, `\}` are literal; an unclosed box
stays as written. Inside a box `\text{}`, `\textbf{}`, `\mathrm{}` and nested boxes keep only their content. A math
wrapper holding nothing but the box (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, with spaces, tabs or line breaks around the
box) goes too; `$x = \boxed{5}$` keeps its `$`. `display` escapes `*`, `_` and backticks in the content and adds no
bold when the box already sits between the same `*` or `_` (`**\boxed{754}**` gives `**754**`). The content is trimmed
of the characters JavaScript's `\s` matches. A backtick fence line with a backtick after its marks is prose, as in
CommonMark.
The browser page's `AnswerFormat` follows the same rules, checked on the shared fixtures in
`Tests/SharedFixtures/boxed-answers.json`.

The reasoning removal in `OutputSchemaValidator`'s extraction is broader on purpose: it drops blocks
anywhere, because JSON never sits inside one. When the stripped text yields no candidate, a balanced
value of the unstripped text that itself contains a tag (`{"tag":"</think>"}`) still counts.

#### Schema grammars

For a profile with an `outputSchema` and no tools, every generation, repairs included, runs under the
schema's grammar on the dedicated client described in [Constrained Generation](#constrained-generation).
The grammar applies when the session's engine is an `Tonamox` (the default `liveEngine` returns one);
an engine of your own keeps validation only. It does not apply, and the session validates and repairs
only, when:

- the model runs on MLX or layer-streaming. Their `GenerationConstraintError.unsupportedBackend` is not
  an error here: the same attempt runs unconstrained, and the session stops asking for the grammar until
  a `switchProfile` rebuilds the engine. A grammar llama.cpp rejects (`invalidGrammar`) is handled the same
  way;
- the profile has tools, because the constrained client runs without them;
- `usesSchemaGrammar` is `false`;
- the schema admits no value (`false`, `minLength` above `maxLength`, …), so there is no grammar.

The grammar admits only JSON syntax and narrows it by what GBNF can express:

| Enforced by the grammar | Left to validation |
|-------------------------|--------------------|
| `type`, including arrays of types; `enum`, `const` | `maximum`, `exclusiveMaximum` |
| `properties`, `required`, `additionalProperties`, `items` | Any other part of `minimum` and `exclusiveMinimum` |
| `minItems`, `maxItems`, `minLength`, `maxLength` up to 64 | Those bounds above 64 |
| No minus sign under a `minimum` or `exclusiveMinimum` of 0 or more; for an integer, no `0` under an `exclusiveMinimum` of 0 or more or a `minimum` of 1 or more | `oneOf` exclusivity, `allOf` with several branches |
| `anyOf` or `oneOf` as alternatives, and a one-branch `allOf`, in a schema with no other keywords | Combinators next to other keywords |

Objects carry only their declared properties, even when `additionalProperties` allows more: required
ones first, in `required` order, then the optional ones sorted by name. That order can differ from the
one the model would write unprompted, which may cost answer quality. An object admits any members
instead when it has more than 16 properties and none required, or when its combinators name a
property it does not declare (unless `additionalProperties` is `false`). A property, `items` or
`additionalProperties` schema that a combinator next to it also constrains admits any value. A free-form
object can repeat a member name, which validation then rejects. A grammar of more than 512 rules or 64 KiB
admits any JSON value.

Numbers have no digit limit. A string admits no `\u` escape of a UTF-16 surrogate, so each character
it admits is one Unicode scalar, as `minLength` and `maxLength` count them; a character outside the
Basic Multilingual Plane is written as UTF-8.

Each constrained generation builds a dedicated llama.cpp client and samples the grammar over the whole
vocabulary; [Schema grammars]({{ '/guide/backends' | relative_url }}#schema-grammars) in the backends guide
has measured costs. A reasoning model cannot open a `<think>` block under the grammar; set
`usesSchemaGrammar = false` for one that needs it.

{: .warning }
> Validation checks shape, not truth: a conforming reply can still hold wrong values. A small model
> that keeps breaking the schema costs up to `1 + maxRepairAttempts` generations per `stream` call.

---

## HardwareAnalyzer

Assesses whether a catalog `Model` fits this device's memory. All methods are synchronous.
Guide: [Hardware Compatibility Check]({{ '/guide/models' | relative_url }}#hardware-compatibility-check).
For an arbitrary Hugging Face repo, use [`ModelCompatibilityChecker`](#modelcompatibilitychecker).

```swift
public enum HardwareAnalyzer   // namespace for static assessment methods
```

### Assessment

```swift
// Assess a model against the current device
static func assess(
    _ model: Model,
    profile: HardwareProfile = .current()
) -> ModelCompatibility

public struct HardwareProfile: Sendable {
    let totalMemoryGB: Double
    let availableMemoryGB: Double        // what a model may fill; from current(): iOS = memoryLimitBytes(),
                                         // macOS = reclaimable memory; 60% of RAM when the OS cannot tell
    let deviceName: String
    let memoryBandwidthGBs: Double?      // nil on iOS and for unrecognised chips

    static func current() -> HardwareProfile

    /// Bytes the process may still allocate, or nil when the OS cannot tell.
    /// iOS returns nil exactly when the process is at or over its jetsam limit —
    /// safety-critical callers must treat nil as danger, never as "plenty free".
    static func availableMemoryBytes() -> Int?

    /// iOS: the app's memory limit, os_proc_available_memory() + phys_footprint, capped at 74% of RAM.
    /// Does not shrink while a model is loaded. nil when iOS reports unknown, and on macOS.
    static func memoryLimitBytes() -> Int?
}

public struct ModelCompatibility: Sendable {
    let model: Model
    let fitLevel: ModelFitLevel
    let requiredMemoryGB: Double
    let availableMemoryGB: Double
    let estimatedDecodeTokensPerSecond: Double?  // nil when chip bandwidth is unknown; see Benchmarks › Speed estimate.
                                                 // For a mixture of experts, the low end of the range below
    let estimatedDecodeTokensPerSecondRange: ClosedRange<Double>?  // mixture of experts only; nil for dense
    var utilizationPercent: Double               // % of available memory consumed
    var speedLevel: SpeedLevel
}

// The estimated memory footprints are properties on `Model`, not on ModelCompatibility:
//   model.estimatedRuntimeMemoryGB    // full-load (monolithic) footprint in GB
//   model.estimatedStreamingMemoryGB  // layer-streaming footprint in GB
```

### Compatible Models

```swift
// Every model passed in is assessed, none filtered out; the default leaves uncensored models out.
// Order: .tooLarge last; otherwise downloaded first, then better fit, then lower memory utilization.
static func compatibleModels(
    from models: [Model] = Model.listedModels,
    profile: HardwareProfile = .current()
) -> [ModelCompatibility]
```

### ModelFitLevel

```swift
public enum ModelFitLevel: Comparable, Sendable {
    case excellent          // >40% RAM headroom
    case good               // 20–40% headroom
    case marginal           // <20% headroom
    case streamingRequired  // GGUF only — layer-streaming viable
    case tooLarge           // not runnable on this device

    var isRunnable: Bool    // false only for .tooLarge
    var label: String       // "Excellent", "Good", etc.
    var systemImage: String // SF Symbol name
}
```

---

## ModelCompatibilityChecker

Answers whether Tonamox's pinned runtimes (`PinnedRuntimes.mlxSwiftLMVersion` and
`PinnedRuntimes.llamaCppBuild`) can load and run a Hugging Face repo on a given device, and if not,
why. It reads the repo listing, `config.json`, the safetensors weight map and the first bytes of
GGUF or safetensors files through HTTP range requests; nothing is downloaded in full. It never
throws: fetch failures (network errors, 401/403, 404) become findings. Unless a blocker was found,
the verdict is `.unknown` when the repo listing, an MLX repo's `config.json` or the GGUF
architecture could not be read.

This is not `ModelCompatibility`, the RAM-fit result `HardwareAnalyzer.assess` returns for catalog
models. Guide: [Finding compatible models]({{ '/guide/models' | relative_url }}#finding-compatible-models).
CLI: `tonamox models search`, `tonamox models check`, `tonamox models devices`.

```swift
let checker = ModelCompatibilityChecker()
let report = await checker.check("mlx-community/Qwen3.5-27B-4bit", on: .mac32GB)
print(report.status.label, report.headline)
```

### Checking

```swift
public struct ModelCompatibilityChecker: Sendable {
    init(transport: URLSession = .shared,
         authorizer: any DownloadAuthorizing = KeychainDownloadAuth(),   // HF token: Keychain account "download.huggingface"
         ggufHeaderBytes: Int = ModelCompatibilityChecker.defaultGGUFHeaderBytes,
         requestTimeout: TimeInterval = 60)
    static let defaultGGUFHeaderBytes: Int   // 4 MiB; also read from a local GGUF that llama.cpp failed to load

    // ggufFile: the GGUF whose header is read when the repo lists it; else the smallest whole top-level quant
    func check(_ repo: String, on target: DevicePreset = .thisDevice(), ggufFile: String? = nil) async -> CompatibilityReport
    func snapshot(of repo: String, ggufFile: String? = nil) async -> RepoSnapshot      // fetch once…
    static func repoID(from input: String) -> String?         // "owner/repo" from an id or a huggingface.co / hf.co URL
}

public enum CompatibilityEvaluator {
    // …then judge any number of devices without refetching. Pure, no network.
    static func evaluate(_ snapshot: RepoSnapshot, on target: DevicePreset) -> CompatibilityReport
}
```

### Report

```swift
public struct CompatibilityReport: Sendable {
    let repoID: String
    let target: DevicePreset
    let weightFormat: DetectedFormat         // .mlx .gguf .imageGeneration .unconvertedSafetensors .noWeights .unknown
    let modelCategory: Model.Category?       // how Tonamox would load it; nil when it cannot
    let status: CompatibilityVerdict         // .runnable .runnableWithCaveats .notRunnable .unknown
    let findings: [CompatibilityFinding]     // blockers first, then caveats, then info
    let overview: ArchitectureFacts          // family, layers, trainedContext, kvHeads, headDim, hasVision, quantization,
                                             // kvLayers (cache per layer type), experts (MoE routing)
    let weightsBytes: Int64?                 // non-GGUF weights
    let weightsFit: FitEstimate?
    let quantFits: [QuantFit]                // every GGUF model quant, smallest first, each with its fit;
                                             // adapters and auxiliary files (artifact.excludedFiles) never count
    let suggestedEntry: CatalogEntry?        // the models.json entry when it can run: entry.jsonText()
    let licenseID: String?
    let licenseName: String?
    let gatedMode: String?
    let artifact: ArtifactClassification     // standalone model, adapter (LoRA) or auxiliary files, and the signal

    var blockers: [CompatibilityFinding]
    var caveats: [CompatibilityFinding]
    var headline: String                     // first blocker or caveat, else how it fits
    var bestFit: FitEstimate?                // weightsFit, or the recommended GGUF quant's fit
    var recommendedQuant: QuantFit?          // the quant suggestedEntry downloads; nil when nothing runs
    var smallestQuant: QuantFit?             // smallest single-file quant, for "nothing fits" answers
    // QuantFit.recommended(in:) prefers top-level single files; QuantFit.isTopLevel says which are
    var huggingFaceURL: URL?
}

public struct ArtifactClassification: Sendable, Equatable {
    let kind: ModelArtifactKind              // .standaloneModel, .adapter(base: String?), .auxiliary(AuxiliaryArtifact)
    let signal: ArtifactSignal?              // the strongest signal that decided; nil for a plain model
    let evidence: String?                    // the key, tag, file or word behind it
    let excludedFiles: [ExcludedArtifactFile]  // GGUF files not offered as versions (path, kind, sizeBytes)
    let isCertain: Bool                      // false for a name, or a tag/file no header could check
    var isSuspectedAdapter: Bool             // a model, but some signal says it might be an adapter
}

public struct CompatibilityFinding: Sendable, Equatable, Identifiable {
    let rule: String                         // the CompatibilityRule id
    let level: FindingSeverity               // .blocker / .caveat / .info
    let title: String
    let detail: String
}

public struct FitEstimate: Sendable, Equatable {
    let rating: ModelFitLevel
    let requiredGB: Double
    let budgetGB: Double
    let tokensPerSecond: Double?             // nil when the device's bandwidth is unknown; MoE: the range's low end
    let tokensPerSecondRange: ClosedRange<Double>?  // mixture of experts only; nil for dense
    var summary: String                      // "Good · 12.0 of 20.0 GB"
    var decodeText: String?                  // "~18 tok/s", or "~37–75 tok/s (uncalibrated MoE range)"
}
```

`CompatibilityRules.all` lists the rules (`CompatibilityRule` has an `id` and a `summary`).
`RepoSnapshot.listing` is the parsed repo listing (`HFRepoInfo`); its `revision` is the commit sha the listing
describes, so later fetches can be pinned to it, as `CoreMLDiffusionInspector` does.
`ModelArtifactClassifier.classify(_:)` decides `ArtifactClassification` from a snapshot alone; the evaluator calls
it before judging any fit. Signals, strongest first (`ArtifactSignal`): `.ggufType` (`general.type` `adapter`),
`.ggufAdapterKeys` (`adapter.*`), `.loraTensorNames` (`.lora_a` / `.lora_b`), `.huggingFaceTags` (`lora`, `peft`,
`adapter`, `base_model:adapter:<repo>`), `.adapterFiles` (`adapter_config.json`, `adapter_model.safetensors`) and
`.nameToken` (a word-bounded `lora` / `adapter` in a file or repo name; `isCertain` is `false`). A header that says
`general.type` `model`, or carries `<arch>.block_count`, or tensor names without LoRA deltas, outranks tags, files
and names. The first three describe the sampled GGUF only; with other model GGUFs in the repo, only that file is
excluded. Without a confirming header, `lora` / `peft` / `adapter` tags, PEFT files and a repo-name word next to
model files leave `kind` `.standaloneModel` with `isSuspectedAdapter` and an `artifact` caveat; only
`base_model:adapter:` decides on its own. An adapter report has no quants, no entry, no fit findings and an
`artifact` blocker that names the base when known
(header `general.base_model.0.*`, the tag, or the card's `base_model`, kept in `HFRepoInfo.baseModels`).
`QuantHint.text(for:)` gives a quant token's plain meaning (`Q4_K_M` → "balanced, common default").
`GGUFHeaderParser.parse(_:)` reads GGUF v2/v3 metadata from the first bytes of a file into a
`GGUFHeader` (`isComplete` is `false` when the bytes ran out; `generalType` is `general.type`; `tensorNames` keeps the
first 64 tensor names when the bytes reach past the metadata), and `SafetensorsHeader.parse(_:)`
does the same for a safetensors header.

To find repos to check, `HuggingFaceSearch.search(_:limit:sort:tag:session:)` queries the Hugging
Face model search; `tag:` (`"mlx"`, `"gguf"`, …) filters on the server. `HFPipelineFilter` keeps the hits
whose declared `pipelineTag` it admits (`admits(_:)`); `HFPipelineFilter.chat` admits `text-generation`,
`image-text-to-text` and `any-to-any`, plus repos that declare none (`admitsUndeclared`, `true` by default),
since many GGUF uploads declare none. It reads only the tag: whether the weights load is still the checker's call.

### DevicePreset

A device to judge against: this one, measured now, or a fixed class of iPhone or Mac. `budgetGB`
is the memory an app may fill with weights and KV cache. Only `thisDevice()` and `mac32GB` are
measured (on iOS, `thisDevice()` falls back to an estimate of 60% of RAM when iOS reports its memory
limit as unknown); every other budget is an estimate and says so in `source`.

```swift
public struct DevicePreset: Sendable, Hashable, Identifiable {
    let id: String                           // "this-device", "iphone-4gb", "mac-32gb", …
    let displayName: String
    let platform: TargetOS                   // .iOS / .macOS
    let totalMemoryGB: Double
    let budgetGB: Double
    let isMeasured: Bool
    let source: String                       // where budgetGB comes from
    let bandwidthGBs: Double?
    var memoryProfile: HardwareProfile       // what HardwareAnalyzer consumes
    var budgetText: String                   // "20.0 GB (measured)" / "≈3.0 GB (estimate)"

    // Without a profile, a Mac is judged by Metal's recommendedMaxWorkingSetSize and an
    // iPhone by the app's memory limit (HardwareProfile.memoryLimitBytes()), the figure
    // ModelManager.load checks too. A given profile is used as is.
    static func thisDevice(profile: HardwareProfile? = nil) -> DevicePreset

    static let iPhone4GB: DevicePreset
    static let iPhone6GB: DevicePreset
    static let iPhone8GB: DevicePreset
    static let iPhone17Pro: DevicePreset
    static let mac16GB: DevicePreset
    static let mac32GB: DevicePreset
    static let mac64GB: DevicePreset
    static let classes: [DevicePreset]                                     // the fixed presets, phones first
    static func all(profile: HardwareProfile? = nil) -> [DevicePreset]     // thisDevice + classes
    static func named(_ id: String, profile: HardwareProfile? = nil) -> DevicePreset?
}
```

---

## Model

`Model` is a value type backed by a JSON model registry (not a `String` enum — there is
no `rawValue` initializer). Named models like `.qwen3_1_7b` are static factory properties.

```swift
public struct Model: Sendable, Identifiable, Codable, CustomStringConvertible

// Collections. allModels has every registered model; the others draw from listedModels, which
// leaves uncensored models out: only uncensoredModels lists those.
static var allModels: [Model]
static var listedModels: [Model]
static var textModels: [Model]
static var visionModels: [Model]
static var specializedModels: [Model]
static var mlxModels: [Model]
static var ggufModels: [Model]
static var runnableModels: [Model]     // filtered by HardwareAnalyzer
static var uncensoredModels: [Model]
static func models(in domain: Domain) -> [Model]

// Unavailable (a compile error that gives the reason): the catalog was checked against Hugging Face
// and these repos hold no loadable weights or do not exist:
// graniteVision_3_3, granite4_compact, gemma4_1b, gemma4_4b, lfm25_3_2b, ministral_3b

// Metadata
var displayName: String
var approximateSizeMB: Int
var purpose: Purpose
var format: ModelFormat                // .mlx or .gguf
var ggufFilename: String?              // nil for MLX models
var isUncensored: Bool
var license: String?                   // the card's license, or its license_name when "other"; nil = not recorded
var hasPermissiveLicense: Bool         // license is apache-2.0 or mit (Model.permissiveLicenses); false when nil
var isMacOSRecommended: Bool          // true for models ≥15 GB
var isDownloaded: Bool                 // in ModelStorage.rootDirectory, or a copy an earlier version left in Caches
var cacheDirectory: URL                // GGUF download folder: <root>/models/<repoID> (not in Caches, despite the name)
var resolvedFileURL: URL?              // GGUF: local file, else the finished download (root, then Caches), else its destination
var kvLayers: KVCacheLayout?           // cache per layer type (sliding, recurrent); nil = all full attention
var experts: ExpertRouting?            // mixture of experts: routedExperts, expertsPerToken, activeSizeMB; nil = dense
var maxContextLength: Int?             // a ceiling the weights impose below the memory budget; nil = none
var capabilities: ModelCapabilities    // see below
```

### ModelCapabilities

`model.capabilities` is an `OptionSet` saying what a model takes and does, read from its catalog category, its
`defaultDocumentPrompt` and the backend `BackendRouter` picks for it. TonamoxExample's Chat tab shows it as badges and
offers image input and document extraction only where they work.

| Capability | Set when | Enables |
|------------|----------|---------|
| `.text` | category `.text` or `.vision` | a conversation from text alone (`chat`, `stream`, `stream(_:in:)`) |
| `.vision` | category `.vision` or `.visionSpecialized`, MLX format (the llama.cpp backends drop the image) | an image with the prompt (`analyze`, `streamVision`) |
| `.documentExtraction` | an image model with a `defaultDocumentPrompt` | `extractDocument(_:)` |
| `.tools` | a GGUF model, or an MLX text model outside the iOS Simulator | `ModelManager.shared.load(_:tools:…)`; an MLX vision or document model throws `ModelConfigurationError.toolsUnsupported(.mlx)` |

### ModelRegistry

The collections above read `ModelRegistry.shared.models`: the bundled catalog, any remote catalog, and models
added at runtime.

```swift
public final class ModelRegistry: @unchecked Sendable
static let shared: ModelRegistry
var models: [Model]                                   // read under the registry's lock
func model(id: String) -> Model?
func model(repoID: String) -> Model?
func register(_ model: Model)                         // adds, or replaces the model with the same id
@discardableResult func unregister(id: String) -> Bool  // only ids register(_:) added; catalog ids stay
func refreshFromRemote(url: URL) async throws
func loadCachedRemote(maxAge: TimeInterval = 86_400)
```

### ModelStorage

Where downloaded weights live: `<Application Support>/AuraLocal/Models`, excluded from backup. Inside the app
container on iOS and in a sandboxed Mac app, or inside the App Group's container once
`TonamoxSharedStorage.configure(appGroup:)` applied one; `~/Library/Application Support/AuraLocal/Models`, shared, for a
non-sandboxed macOS process (the `tonamox` CLI, an app without App Sandbox), configured or not. In an App Group the
app's private root is merged in at `configure` (renames only) and stays a read fallback. Guides:
[Where models are stored]({{ '/guide/models' | relative_url }}#where-models-are-stored),
[Sharing storage between apps]({{ '/guide/models' | relative_url }}#sharing-storage-between-apps-app-group).

```swift
public enum ModelStorage {
    static var rootDirectory: URL     // first access creates it, excludes it from backup, migrates Caches when sandboxed
                                      // (and, in an App Group, the app's private root)
    // Renames Tonamox's downloads out of Caches (never copies, never overwrites); idempotent
    @discardableResult static func migrateLegacyDownloads() -> ModelStorageMigration
}

public struct ModelStorageMigration: Sendable, Equatable {
    let moved: [String]               // paths relative to the roots, now in the storage root
    let conflicts: [String]           // left in Caches: the storage root already has that path
    let failures: [String]            // left in Caches: the rename failed; still read from there
    let duplicatesRemoved: [String]   // App Group merge only: source copies deleted because the group holds an
                                      // identical finished copy; always empty from migrateLegacyDownloads()
    init(moved: [String], conflicts: [String], failures: [String], duplicatesRemoved: [String] = [])
    var isEmpty: Bool
}
```

### ModelDownloads

Downloads a model to the exact path its backend loads from, under `ModelStorage.rootDirectory`, without loading
it. Each file arrives in `Range` chunks appended to `<file>.partial`, which survives a cancel, a network cut or a
relaunch; a partial whose ETag no longer matches restarts from zero, and a file moves into place only when its
size matches and, for an LFS file, when its SHA-256 matches the one Hugging Face publishes. A finished model an
earlier version left in Caches is used from there; a GGUF `.partial` left there moves into the storage root and is
resumed. Downloads of the same file or snapshot run one at a time, also with `GGUFModelDownloader`, the MLX load
path, `ChunkedDownloader` and other processes sharing the storage root; a later call returns the finished model
without a transfer. Guides:
[Downloading without loading]({{ '/guide/models' | relative_url }}#downloading-without-loading),
[Concurrent downloads]({{ '/guide/models' | relative_url }}#concurrent-downloads).

```swift
public enum ModelDownloads {
    static func plan(for model: Model, auth: any DownloadAuthorizing = KeychainDownloadAuth()) async throws -> DownloadPlan
    // Resumes <file>.partial, verifies SHA-256; returns the GGUF file or the MLX snapshot folder.
    // progress: (bytes on disk, total)
    static func download(_ model: Model, auth: any DownloadAuthorizing = KeychainDownloadAuth(),
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    // Finished and partial files: storage root, the app's private root in an App Group, Caches. Evict first.
    // Throws ModelFilesInUseError, deleting nothing, while a download (any process) holds the model's lock.
    static func delete(_ model: Model) throws
    static func bytesOnDisk(for model: Model) -> Int64      // every root models are read from
    static func availableDiskBytes() -> Int64?              // download needs the remaining bytes + 20%
    static func verifiedSHA256(of file: URL) -> String?     // what a download verified the file against; nil = unverified

    // One folder of a repo at a pinned revision (e.g. a Core ML pipeline); sends no token by default
    static func downloadFolder(repoID: String, revision: String, folder: String, include: [String],
                               auth: any DownloadAuthorizing = NoDownloadAuth(),
                               progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    static func planFolder(repoID: String, revision: String, folder: String, include: [String],
                           auth: any DownloadAuthorizing = NoDownloadAuth()) async throws -> DownloadPlan
    static func localFolder(repoID: String, folder: String) -> URL   // where downloadFolder writes
    static func completedFolder(repoID: String, folder: String, revision: String) -> URL?  // root, else Caches
    static func isFolderComplete(repoID: String, folder: String, revision: String) -> Bool
    static func deleteRepo(_ repoID: String) throws                   // models--org--repo: every folder, finished and partial
    static func deleteFolder(repoID: String, folder: String) throws   // one folder with its partials and markers, then the
                                                                      // parents it leaves empty; other folders stay
    // deleteRepo and deleteFolder throw ModelFilesInUseError while a download holds the repo's snapshot lock
}

public struct DownloadPlan: Sendable, Equatable {
    let repoID: String
    let files: [PlannedFile]          // path, sizeBytes
    let totalBytes: Int64
    let bytesOnDisk: Int64            // finished files plus .partial bytes
    var remainingBytes: Int64
}

public enum ModelDownloadError: LocalizedError, Equatable, Sendable {
    case unauthorized(repoID: String), notFound(repoID: String, path: String), notFoundOrPrivate(repoID: String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64), http(status: Int)
    case incompleteRepo(repoID: String), sizeMismatch(path: String, expected: Int64, actual: Int64), unsupported(String)
}

// Separate from ModelDownloadError so exhaustive switches over it keep compiling. The file is already deleted.
public enum ModelIntegrityError: LocalizedError, Equatable, Sendable {
    case checksumMismatch(path: String, expected: String, actual: String)   // lowercase hex SHA-256
}

// Separate from ModelDownloadError for the same reason. Nothing was moved into place; download again.
public enum DownloadConflictError: LocalizedError, Equatable, Sendable {
    case partialChanged(path: String)   // the finished .partial was gone or resized by another writer
}

// A delete refused because a download, in this process or another one sharing the storage root, holds the lock.
public struct ModelFilesInUseError: LocalizedError, Equatable, Sendable {
    init(name: String)
    let name: String                    // the file or snapshot folder, by name
}
```

Only single-file GGUF quants at the top level of a repo download; a split or subfolder quant, or a model
backed by a local file, throws `.unsupported`. `DownloadedModels.scan()`, `scanSnapshots()` and
`partialFiles()` list the GGUF files, MLX snapshots and `.partial` files on disk, in the storage root and in
Caches; `DownloadedModels.modelsDirectory` is the GGUF root downloads write to and `modelsDirectories` every GGUF
root that is read. `GGUFModelDownloader` (the GGUF path of `ModelManager.load`) and
`ChunkedDownloader.download(from:to:fileName:expectedSHA256:onProgress:)` throw `ModelIntegrityError` too; the
latter checks only a hash you pass. `GGUFModelDownloader` and the MLX load path throw `DownloadConflictError` too.
`ChunkedDownloader` waits for another download to the same destination. It returns the file there without a
transfer when that download ran in the same process and fetched the same URL and hash, or when the file hashes to
the `expectedSHA256` passed; otherwise it downloads again and replaces the file.

### DownloadRecords

The sized `Model` behind each download from a search result, stored in `UserDefaults` under
`dev.auralocal.downloadRecords`, so the model can be registered again after a relaunch. Files on disk stay the
source of truth. See [Keeping downloads across launches]({{ '/guide/models' | relative_url }}#keeping-downloads-across-launches).

```swift
public struct DownloadRecords: @unchecked Sendable
// UserDefaults.standard; or, once TonamoxSharedStorage.configure(appGroup:) applied a scope, the shared file
// AuraLocal/download-records.json, into which the first access copies this app's UserDefaults records once.
static var standard: DownloadRecords { get }
init(defaults: UserDefaults = .standard)
static func key(for model: Model) -> String            // "gguf:<repo>/<file>" or "mlx:<repo>"
func remember(_ model: Model)                           // replaces any record for the same file
func forget(_ model: Model)
var models: [Model]
func model(repoID: String, ggufFilename: String?) -> Model?   // nil filename = the MLX snapshot
func contains(_ model: Model) -> Bool                   // by id
@discardableResult func registerDownloaded() -> [Model] // at launch; drops records with nothing on disk
@discardableResult func registerIfDownloaded(_ model: Model) -> Bool
func remove(_ model: Model)                             // forget + ModelRegistry.shared.unregister(id:)
```

A record whose file a registry entry already points at is not registered, so one file never shows twice in the
pickers. Each read-modify-write of the stored dictionary holds a lock, so calls from several threads don't drop
records; the shared file is also held under a `flock` (`AuraLocal/records.lock`) across processes and replaced
atomically. With the shared file, `registerDownloaded()` drops no records. A write that changes the records posts
`TonamoxSharedStorage.didChangeNotification` with `.models` (in this process only when no group is configured).

### Download on demand

`ModelManager.load`, `Tonamox.text`/`vision`/`specialized` and the one-liners download a missing model before
they load it. A screen that should ask first shows `ModelDownloadPlaceholder` while a model it needs is not on
disk, and loads once the placeholder reports it ready. The SDK's own tabs (`DocsTab`, `TextChatTab`, `VisionTab`,
`OCRTab`) do this by default.

```swift
public struct RequiredModel: Identifiable, Hashable, Sendable {
    init(_ entry: Model, purpose: String)   // purpose: what the feature uses it for
    let entry: Model
    let purpose: String
}
extension [RequiredModel] { var notDownloaded: [RequiredModel] }   // reads the disk

public struct ModelDownloadPlaceholder: View {
    init(_ title: String, message: String, models: [RequiredModel],
         onReady: @escaping @MainActor () -> Void = {})              // once every model is on disk
}

@MainActor @Observable
public final class OnDemandDownloads {
    static let shared: OnDemandDownloads
    var revision: Int { get }                        // bumped when a download finishes, fails or is cancelled
    func phase(of model: Model) -> Phase             // .idle, .waiting, .downloading(done:total:), .failed(String)
    func isDownloading(_ model: Model) -> Bool       // waiting or transferring
    func download(_ models: [Model])                 // queues the ones not on disk, in order
    func cancel(_ models: [Model])                   // keeps the .partial, so the next download resumes
}

extension Model { var approximateSizeBytes: Int64 }  // approximateSizeMB × 1,000,000
```

```swift
struct LibraryScreen: View {
    let needed = [RequiredModel(.qwen3_1_7b, purpose: "Answers questions about your documents")]
    @State private var isReady = false

    var body: some View {
        if isReady || needed.notDownloaded.isEmpty {
            LibraryView()   // loads with ModelManager.shared.load, from disk
        } else {
            ModelDownloadPlaceholder("Download the Library model",
                                     message: "Answers come from a model that runs on this device.",
                                     models: needed) { isReady = true }
        }
    }
}
```

The placeholder lists each model with its purpose, its approximate size (`approximateSizeMB`) and what a cancelled
download left on disk, the total still to download (less those `.partial` bytes), the free space from `ModelDownloads.availableDiskBytes()`
and, when the download plus the 20 % margin `ModelDownloads` requires may not fit, a warning; a model rated
*Too Large* for the device's free memory gets a warning too, and so does an MLX model in the Simulator, where it
downloads but cannot load. Nothing touches the network until the user taps
**Download**. While it runs each row shows bytes and percent and the button becomes **Cancel download**; a failed
model shows its error and the button becomes **Retry download**. Leaving the screen does not stop a download.
It centers in the space it is given and scrolls at large Dynamic Type sizes, so it works as a whole screen or in
place of one control.

`OnDemandDownloads` runs one transfer at a time through `ModelDownloads.download`, so files land where the
backends load them from, and tracks models by file (`DownloadRecords.key(for:)`). TonamoxUI's
`ModelDownloadCenter` counts its downloads as busy (a catalog row or the Hugging Face browser does not start the
same file, Delete refuses it) and folds its `revision` into its own. The reverse is not checked: a placeholder
can start a file that `ModelDownloadCenter` or a `ModelManager.load` is already downloading.

---

## TonamoxSharedStorage

Opt-in sharing of models, download and image-model records, conversations, the document index, the e5 bundle and
(iOS, visionOS) keychain items between the apps of one App Group. Without `configure(appGroup:)` every path stays
as it was. Guides: [Sharing storage between apps]({{ '/guide/models' | relative_url }}#sharing-storage-between-apps-app-group),
[Installation › App Groups]({{ '/guide/installation' | relative_url }}#app-groups-sharing-storage-between-apps).

```swift
public enum TonamoxSharedStorage {
    // Call first in App.init. The first storage access (ModelStorage, DownloadRecords.standard,
    // CoreMLDiffusionModelStore.standard, KeychainStore, ConversationStore.shared, DocumentLibrary.shared,
    // AutoEmbeddingProvider.defaultModelBundleURL, scope) fixes the configuration; a later call changes nothing.
    @MainActor @discardableResult
    static func configure(appGroup identifier: String) -> SharedStorageConfiguration
    static var scope: SharedStorageScope { get }        // reading it fixes the configuration too
    static let didChangeNotification: Notification.Name // "dev.auralocal.sharedStorage.didChange", main queue
    static func change(of notification: Notification) -> SharedStorageChange?
    static func postChange(_ change: SharedStorageChange)  // Darwin post to the group, or in-process without one
}

public enum SharedStorageScope: Sendable, Equatable {
    case standard                                         // not configured, or the group did not resolve
    case appGroup(identifier: String, container: URL)     // iOS/visionOS, or a sandboxed Mac app with the entitlement
    case userWide(identifier: String)                     // a Mac process without App Sandbox
}

public enum SharedStorageConfiguration: Sendable, Equatable {
    case applied(SharedStorageScope)
    case unavailable(appGroup: String)                    // no entitlement or no container; scope stays .standard
    case ignored(current: SharedStorageScope, firstUse: String)  // storage already used, or another group configured
}

public enum SharedStorageChange: String, Sendable, CaseIterable {
    case models, conversations, documents
}
```

- **Idempotent.** The same identifier again returns the first result; another identifier returns `.ignored`, with
  `firstUse` set to `"configure(appGroup: <first>)"`. A call after storage was used returns `.ignored` with the name
  of what used it, and logs a fault (`dev.auralocal`, category `SharedStorage`).
- **At `configure`** (`.appGroup`): the app's private models and e5 bundles are renamed into the group (on the main
  thread; renames, attribute reads and the removal of identical private copies only), the keychain items are copied
  into the group's access group (iOS, visionOS), the Darwin observers are registered, and on iOS the background
  observer is installed. Records, conversations and the document index are copied on their first access.
  `.userWide` registers the observers and copies the records only.
- **Change signal.** With a group, `postChange` sends the Darwin notification `<identifier>.<change>`, which
  every running process of the group, this one included, re-posts as `didChangeNotification` on the main queue.
  Without one it posts `didChangeNotification` in this process only. Tonamox posts `.models` after downloads,
  deletes and record changes, `.conversations` after every `ConversationStore` write, and `.documents` after
  `DocumentLibrary` adds, removes or re-embeds. A suspended app misses Darwin notifications.
- **Background** (iOS and iPadOS, `.appGroup`): entering the background closes the shared SQLite stores'
  idle connections inside a background task, which is kept while a download holds a lock; the locks are released
  when the time runs out. Until the app returns, every `ConversationStore` and document-index call opens, runs in its
  own background task and closes. macOS and visionOS have no background hooks.

---

## BackgroundLifecycle (iOS)

When the app enters the background it cancels every generation running through `Tonamox` or
`CoreMLDiffusionEngine`, and until the app returns new ones throw at once. Both throw
`GenerationInterrupted`. With `aggressiveMemorySaving`, it also evicts every loaded model except the
most recently used one. The observers are installed when a model loads or an image generation starts.
Guide: [Background Lifecycle]({{ '/guide/memory' | relative_url }}#background-lifecycle-ios).

```swift
@MainActor
public final class BackgroundLifecycle
static let shared: BackgroundLifecycle

@Published private(set) var isPaused: Bool     // true while the app is backgrounded; generations are refused
var aggressiveMemorySaving: Bool = false       // evicts all but the most recently used model on background
```

Nothing is cancelled on macOS.

### GenerationInterrupted

Thrown when Tonamox stops a generation itself. A stream yields the text first, then finishes with it.

```swift
public struct GenerationInterrupted: Error, LocalizedError, Sendable, Equatable {
    enum Trigger: Sendable, Equatable {
        case appBackgrounded
        case deviceConditions(DeviceConditions.Assessment)
    }
    let reason: Trigger
    let partialText: String      // what was produced; always truncated, always "" for images
}
```

### DeviceConditions

Opt-in guard: assessed before a generation and every `checkInterval` tokens or denoising steps. At warn
the generation continues and `onWarning` runs; at block it throws `GenerationInterrupted`. The battery is
read only when the app has enabled `UIDevice.isBatteryMonitoringEnabled` (process-wide; Tonamox never
sets it). Guide: [Device conditions]({{ '/guide/memory' | relative_url }}#device-conditions).

```swift
public struct DeviceConditions: Sendable {
    enum Level: Int, Comparable { case normal, warn, block }
    enum Cause: Equatable { case thermal(ProcessInfo.ThermalState), lowPowerMode, lowBattery(Float) }

    struct Reading: Sendable, Equatable {
        var thermalPressure: ProcessInfo.ThermalState
        var isLowPowerModeEnabled: Bool
        var batteryLevel: Float?             // nil unless battery monitoring is on
        var isCharging: Bool?
        static func system() -> Reading                  // any thread; no battery
        @MainActor static func current() -> Reading      // plus battery when monitoring is on (iOS)
    }

    struct Assessment: Sendable, Equatable {
        let severity: Level
        let causes: [Cause]                  // every cause at warn or block
        let snapshot: Reading
    }

    var warnAtThermalState: ProcessInfo.ThermalState?   // .serious
    var blockAtThermalState: ProcessInfo.ThermalState?  // .critical
    var lowPowerMode: Level                             // .warn
    var warnBelowBatteryLevel: Float?                   // nil: battery ignored
    var blockBelowBatteryLevel: Float?                  // nil
    var checkInterval: Int                              // 8
    var onWarning: (@Sendable (Assessment) -> Void)?    // once per transition into warn

    func assess(_ reading: Reading) -> Assessment
}
```

### ContextWindowOverflow

```swift
public struct ContextWindowOverflow: Sendable, Equatable {
    let promptTokens: Int
    let generatedTokens: Int
    let windowSize: Int
    var droppedTokens: Int { get }   // promptTokens + generatedTokens - windowSize
}
```

---

## System tools

On-device Apple frameworks (Vision, Natural Language, Sound Analysis, Core ML, Create ML) wrapped as
`SystemTool`s. Each tool's own API is in the
[On-device ML tools]({{ '/guide/ml-tools' | relative_url }}) guide.

```swift
public protocol SystemTool: Sendable {
    var id: String { get }
    var displayName: String { get }
    var summary: String { get }
    var category: SystemToolCategory { get }                // default .customModel
    func availability() async -> SystemToolAvailability     // .available / .unavailable(reason:); never throws
}

public enum SystemToolRegistry {
    static let all: [any SystemTool]                        // the built-in tools that need no file
    static func discover() async -> [ToolInfo]
    static func availableTools() async -> [ToolInfo]
    static func tool(id: String) -> (any SystemTool)?
}
```

### Text embeddings (Core ML)

`CoreMLTextEmbeddingTool` runs a sentence-embedding bundle such as multilingual-e5-small on-device.
A bundle is a directory holding `embedding-model.json` (`TextEmbeddingManifest`), the `.mlpackage`
or `.mlmodelc`, and the Hugging Face `tokenizer.json` and `tokenizer_config.json`. The tool is not
in `SystemToolRegistry.all`; create it with the bundle's URL. TonamoxDocs wraps it in
[`CoreMLEmbeddingProvider`]({{ '/api/rag' | relative_url }}#coremlembeddingprovider).
Guide: [Using the model without TonamoxDocs]({{ '/guide/rag' | relative_url }}#using-the-model-without-auradocs).

```swift
public struct CoreMLTextEmbeddingTool: SystemTool {
    // compiledModelsDirectory nil = Caches/AuraLocal/CompiledModels
    init(bundleAt url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine, compiledModelsDirectory: URL? = nil)

    // Checks the manifest, the model file and the tokenizer files without loading the model.
    @discardableResult
    static func validateBundle(at url: URL) throws -> TextEmbeddingManifest

    let manifest: TextEmbeddingManifest?     // nil when missing or invalid; availability() says why
    var dimensions: Int                      // 0 without a manifest
    var identifier: String                   // "model_id@revision"; the tool id without a manifest

    func embed(_ text: String, role: TextEmbeddingRole = .passage) async throws -> TextEmbedding
    func embed(_ texts: [String], role: TextEmbeddingRole = .passage) async throws -> [TextEmbedding]
    func tokenize(_ text: String, role: TextEmbeddingRole = .passage) async throws -> TextEmbeddingTokens
    @discardableResult
    func warmUp() async throws -> Duration   // the first Neural Engine load compiles on-device
    func truncatedInputCount() async -> Int  // inputs cut at max_tokens so far
    func unload() async
}

public enum TextEmbeddingRole: String, Sendable, CaseIterable {
    case query     // prefixed with the manifest's query_prefix
    case passage   // prefixed with passage_prefix
    case raw       // used as given
}

public struct TextEmbedding: Sendable, Equatable {
    let vector: [Float]
    let tokenCount: Int                      // <s> and </s> included
    let isTruncated: Bool                    // the text exceeded max_tokens and its tail was dropped
}

public struct TextEmbeddingTokens: Sendable, Equatable {
    let ids: [Int]
    let originalCount: Int                   // length before truncation
    var isTruncated: Bool
}

public struct TextEmbeddingManifest: Codable, Sendable, Equatable {
    static let schemaName: String            // "aura.text-embedding/1"
    static let fileName: String              // "embedding-model.json"
    let modelID: String                      // JSON: model_id
    let revision: String
    let dimensions: Int
    let maxTokens: Int                       // JSON: max_tokens
    let queryPrefix: String                  // JSON: query_prefix
    let passagePrefix: String                // JSON: passage_prefix
    // also schema, modelFile, inputName, outputName, buckets, padTokenID, pooling, normalize, license
    var identifier: String                   // "model_id@revision"
    static func load(fromBundle bundleURL: URL) throws -> TextEmbeddingManifest
}
```

### EmbeddingIndexIdentity

Which embedding model produced the vectors in a stored index. `DocumentLibrary` records it and
re-embeds when the configured provider no longer matches.

```swift
public struct EmbeddingIndexIdentity: Sendable, Equatable {
    let identifier: String
    let dimensions: Int
    init(identifier: String, dimensions: Int)

    static let preTrackingIdentifier: String      // "tonamox.tfidf-hash/4096"

    enum Reconciliation { case upToDate, adopt, reembed }
    static func reconciliation(
        stored: EmbeddingIndexIdentity?,          // nil for an index written before identities were recorded
        configured: EmbeddingIndexIdentity,
        storedVectorLengths: Set<Int>,
        storedVectorCount: Int
    ) -> Reconciliation
}
```

---

## Hybrid Inference

Optional, **consent-gated** escalation to a bigger local or cloud model. Off by default.
See the [Hybrid Inference guide]({{ '/guide/hybrid' | relative_url }}) for the full flow.

### Local provider detection

```swift
public enum LocalProviderKind: String, Sendable, Codable {
    case ollama, llamaServer, magnitude
    var displayName: String              // "Ollama", "llama-server", "Magnitude"
}

public struct LocalProviderEndpoint: Sendable, Hashable {
    static let ollamaDefault             // http://localhost:11434
    static let llamaDefault              // http://127.0.0.1:8080/v1
    static let magnitudeDefault          // http://127.0.0.1:10100/inference/v1
    static let defaults: [LocalProviderEndpoint]   // all three, probed concurrently
}

@MainActor
public enum LocalProviderDetector {
    // By default probes Ollama, llama-server and Magnitude on this machine (llama-server and
    // Magnitude via GET {base}/models); pass LocalProviderEndpoint(kind:baseURL:) for another host.
    // Never throws.
    static func detectAll(
        endpoints: [LocalProviderEndpoint] = LocalProviderEndpoint.defaults,
        timeout: TimeInterval = 2.0
    ) async -> [LocalProviderStatus]
}

public struct LocalProviderModel: Sendable, Codable, Identifiable, Hashable {
    let name: String
    let sizeBytes: Int64?                // Ollama: size; llama-server: meta.size
    let quantization: String?            // Ollama only
    let contextLength: Int?              // llama-server: meta.n_ctx_train; Magnitude: context_length
    let remoteHost: String?              // Ollama cloud models: "https://ollama.com:443"
    var runsLocally: Bool                // false with a remoteHost or a ":cloud" / "-cloud" tag
}
```

### HybridEscalator

```swift
@MainActor
public final class HybridEscalator {
    init(ledger: CostLedger = .shared)   // prices and session spend come from this ledger

    // Route by policy: stays local, escalates, or asks consent per rules R1–R7. Builds one payload
    // (policy.keepRatio, redaction per policy.piiRedaction), shows it to the gate on an offer, and
    // sends exactly it.
    func routeAndEscalate(
        policy: EscalationPolicy,
        systemPrompt: String? = nil,
        context: String,
        question: String,
        domain: Model.Domain? = nil,
        localContextWindow: Int = 8192,
        localAnswer: String? = nil,        // enables the low-confidence trigger
        consent: any ConsentGate = DenyingConsentGate(),   // asked via requestConsent(target:preview:offer:)
        maxTokens: Int = 1024,
        targets: [RemoteTarget]? = nil,    // nil = candidateTargets(policy:)
        temperature: Float? = nil,         // as in escalate(_:to:temperature:onToken:)
        onToken: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Result?              // nil = the router kept it local
                                           // throws TonamoxError.escalationDeclined when the gate declines

    // Direct escalation to a chosen target: preparePayload(keepRatio: 0.5, redactPII:), then
    // escalate(_:to:). Checks no policy, consent or cost cap.
    func escalate(
        to target: RemoteTarget,
        systemPrompt: String? = nil,
        context: String,
        question: String,
        maxTokens: Int = 1024,
        redactPII: Bool = false,           // PIIRedactor on the context and the question
        temperature: Float? = nil,         // as in escalate(_:to:temperature:onToken:)
        onToken: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Result

    // The exact request, not sent: with redactPII, redacts the context and the question, then compresses
    // the context to keepRatio × the target's context window (8192 when unknown) − maxTokens, at least 256.
    func preparePayload(
        for target: RemoteTarget,
        systemPrompt: String? = nil,
        context: String,
        question: String,
        maxTokens: Int = 1024,
        keepRatio: Double = 0.5,
        redactPII: Bool = false
    ) -> EscalationPayload
    // Sends a payload exactly as built, without recompressing or redacting; an earlier request with the same
    // provider cacheIdentity, model, messages, maxTokens and temperature is answered from ResponseCache.shared.
    // An empty or whitespace-only answer is returned but not cached. Records cost; a stream stopped after
    // output without usage (cancel, dropped connection) is recorded at estimatedInputTokens + maxTokens,
    // flagged Record.isEstimated, and a cancelled call throws CancellationError. Checks no policy, consent or cap.
    func escalate(
        _ payload: EscalationPayload,
        to target: RemoteTarget,
        temperature: Float? = nil,         // the request's sampling temperature; nil sends 0.7
        onToken: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Result

    // A llama-server (preferred), Ollama or Magnitude on this machine (LocalProviderEndpoint.defaults), with its
    // largest-context model; nil if none runs. Nothing scans the network.
    // Skips models with runsLocally == false (Ollama cloud models forward prompts off the machine).
    static func bestLocalTarget() async -> RemoteTarget?
    // BYOK targets from the Keychain: "cloud.anthropic", then "cloud.openai", then "cloud.gemini" (unpriced),
    // each only when its key is stored. [] when !allowCloud.
    static func cloudTargets(
        allowCloud: Bool,
        anthropicModel: String = RemoteTarget.defaultAnthropicModel,   // "claude-sonnet-4-5"
        openAIModel: String = RemoteTarget.defaultOpenAIModel,         // "gpt-4o"
        geminiModel: String = RemoteTarget.defaultGeminiModel          // "gemini-3.5-flash-lite"
    ) -> [RemoteTarget]
    // bestLocalTarget() first, then cloudTargets(allowCloud: policy.allowCloud).
    static func candidateTargets(policy: EscalationPolicy) async -> [RemoteTarget]

    public struct Result: Sendable {
        let answer: String
        let compression: CompressionResult
        let usage: TokenUsage?
        let providerName: String
        let redactedPIICount: Int
        let fromCache: Bool
    }
}

public struct EscalationPayload: Sendable, Equatable {
    let systemPrompt: String?            // sent verbatim: never compressed or redacted
    let userMessage: String              // "Context:\n<context>\n\nQuestion: <question>", or the question alone
    let maxTokens: Int
    let redactionEnabled: Bool           // PIIRedactor ran on the context and the question
    let redactedPIICount: Int            // in the question and the whole context, before compression
    let compression: CompressionResult   // keptText is the context as sent
    var messages: [[String: String]]     // role/content, system first; Anthropic sends it as top-level "system"
    var estimatedInputTokens: Int        // system prompt + user message at ~4 chars/token; what routeAndEscalate prices
}
```

### EscalationPolicy

```swift
public struct EscalationPolicy: Sendable, Equatable, Codable {
    var mode: Mode                     // .off / .askEachTime / .autoWithConsentMemory
    var allowCloud: Bool
    // Default 1.0. Rule R7: when the request's projection is above $0 (a LAN target never trips it)
    // and CostLedger.sessionCostUSD plus that projection exceeds the cap, the router offers
    // .costCapped, which the default ConsentGate.requestConsent(target:preview:offer:) declines.
    // An unpriced cloud model, or a session with unpriced calls, is offered as .costUnknown.
    var costCapUSDPerSession: Decimal
    // Default 0.5. routeAndEscalate compresses the context to keepRatio × the target's context window
    // minus maxTokens; escalate(to:) always uses 0.5.
    var keepRatio: Double
    // Default .cloudOnly. Where routeAndEscalate redacts the context and the question.
    // A policy saved without this key decodes as .cloudOnly.
    var piiRedaction: RedactionScope

    enum RedactionScope: String, Sendable, Codable {
        case cloudOnly                 // cloud targets; your own LAN box gets the text verbatim
        case allTargets
        case never
    }

    init(mode: Mode = .off, allowCloud: Bool = false, costCapUSDPerSession: Decimal = 1.0, keepRatio: Double = 0.5,
         piiRedaction: RedactionScope = .cloudOnly)
    static let off: EscalationPolicy   // the default — never leaves the device
    func redactsPII(for target: RemoteTarget) -> Bool
}
```

### EscalationRouter

The pure decision behind `routeAndEscalate`, which fills `RoutingInput` from its target and its
`CostLedger`. Call it yourself to test a policy.

```swift
public enum EscalationRouter {
    static func decide(_ input: RoutingInput) -> RoutingDecision   // rules R1–R7, no I/O
    // A send the user asked for, to a target the user chose: no trigger needed, allowCloud checked here,
    // the cost cap refuses instead of offering.
    static func decideUserRequested(_ input: RoutingInput) -> UserRequestedDecision
}

public struct RoutingInput: Sendable {
    init(policy: EscalationPolicy, hasCandidateTarget: Bool, candidateIsCloud: Bool,
         online: Bool = true, promptTokens: Int = 0, localContextWindow: Int = 8192,
         localAnswer: String? = nil, domain: Model.Domain? = nil,
         projectedCostUSD: Decimal? = nil,   // nil = unknown; a cloud target is then offered, never free
         sessionSpentUSD: Decimal = 0,       // priced spend already recorded this session
         unpricedRecordCount: Int = 0)       // session calls of unknown cost; > 0 makes the spend a lower bound
}

public enum RoutingDecision: Sendable, Equatable {
    case stayLocal
    case escalate(reason: EscalationReason)
    case offer(reason: EscalationReason)
}

public enum UserRequestedDecision: Sendable, Equatable {
    case refuse(UserRequestRefusal)          // nothing is sent
    case ask(reason: EscalationReason)       // .userRequested, or .costUnknown for an unpriced cloud target/session
    case send                                // only a LAN target under .autoWithConsentMemory
}

public enum UserRequestRefusal: Sendable, Equatable {
    case policyOff, cloudNotAllowed, offline, overCostCap
}

public enum EscalationReason: String, Sendable, Equatable {
    case sizeOverflow, lowConfidence, domainSensitive, userRequested
    case costCapped    // a trigger fired, but sessionSpentUSD + a non-zero projection exceeds the cap
    case costUnknown   // a trigger fired for a cloud target whose projection is nil, or with a
                       // non-zero projection under the cap while unpricedRecordCount > 0
}
```

### Providers & targets

```swift
public protocol RemoteLLMProvider: Sendable {
    /* id, displayName, retentionNote, stream(_:) */
    // ResponseCache key; defaults to id. OpenAICompatibleProvider and AnthropicProvider return
    // "<id>@<scheme>://<host>:<port><path>" of their base URL (no user, password, query or key).
    var cacheIdentity: String { get }
}

public enum RemoteEvent: Sendable {
    case token(String)       // an answer delta
    case reasoning(String)   // a reasoning delta streamed apart from the answer (OpenAICompatibleProvider reads
                             // `reasoning_content` or `reasoning`); escalation leaves it out of the answer but
                             // records the call's cost if the stream then fails
    case usage(TokenUsage)
}

public struct OpenAICompatibleProvider: RemoteLLMProvider {
    init(id: String, displayName: String, baseURL: URL, apiKey: String? = nil,
         streaming: Bool = true, retentionNote: String = "Sent to an OpenAI-compatible endpoint.")
    // Build from a detected local llama-server / Ollama / Magnitude endpoint, named "<kind> (local)"
    // (Ollama requests go to <root>/v1; the others use the detected base URL as is).
    static func from(_ status: LocalProviderStatus) -> OpenAICompatibleProvider
    // Unavailable: GitHub retired GitHub Models on 2026-07-30. Calling it is a compile error.
    @available(*, unavailable, message: "GitHub retired GitHub Models on 2026-07-30. …")
    static func gitHubModels(apiKey: String) -> OpenAICompatibleProvider
}

public struct RemoteTarget: Sendable {
    let provider: any RemoteLLMProvider
    let modelID: String
    let contextLength: Int?
    let origin: Origin                 // .cloud / .localNetwork(LocalProviderKind)
    init(provider: any RemoteLLMProvider, modelID: String, contextLength: Int? = nil, origin: Origin)
    var isLocalNetwork: Bool

    static let defaultOpenAIModel: String      // "gpt-4o"
    static let defaultAnthropicModel: String   // "claude-sonnet-4-5"
    static let defaultGeminiModel: String      // "gemini-3.5-flash-lite"

    // Google's OpenAI-compatible endpoint (https://generativelanguage.googleapis.com/v1beta/openai/, beta),
    // Bearer key, provider id "cloud.gemini", origin .cloud, contextLength nil, unpriced. Sends no temperature
    // (deprecated by Google on 2026-07-21). retentionNote names the free tier's terms and the EEA/UK/CH rule.
    static func gemini(apiKey: String, model: String) -> RemoteTarget
}
```

{: .note }
> GitHub retired GitHub Models on 2026-07-30. `OpenAICompatibleProvider.gitHubModels(apiKey:)` and
> `HybridEscalator.cloudTargets(allowCloud:anthropicModel:openAIModel:gitHubModelsModel:)` are
> `unavailable`, so old callers get a compile error with the migration path. A key stored under
> `"cloud.github-models"` is no longer read and stays in the Keychain until you delete it.

### AskTargetResolver

The provider choice behind `tonamox ask`, as a pure function: no network, no Keychain access of its own.
Without a `baseURL`, `.auto` / `.local` never return a cloud target; a prompt leaves the machine
only when the caller names `.openAI` / `.anthropic` / `.gemini` or passes a base URL. A `baseURL` is
classified by its host alone: loopback or private network is `.localNetwork(.llamaServer)`,
anything else `.cloud` (also under `.auto`).

```swift
public enum AskTargetResolver {
    enum Choice: String, Sendable, CaseIterable {
        case auto, local                 // llama-server, else Ollama, else Magnitude (bestLocalTarget order)
        case openAI = "openai"           // key: OPENAI_API_KEY, else Keychain "cloud.openai"
        case anthropic                   // key: ANTHROPIC_API_KEY, else Keychain "cloud.anthropic"
        case gemini                      // key: GOOGLE_API_KEY, else GEMINI_API_KEY, else Keychain "cloud.gemini"
    }

    enum Failure: Error, Equatable, LocalizedError {
        case noLocalProvider
        case modelNotServedLocally(model: String, available: [String])
        case missingAPIKey(provider: Choice, environmentVariable: String, keychainAccount: String)
                                         // environmentVariable: "GOOGLE_API_KEY or GEMINI_API_KEY" for .gemini
        case conflictingOptions(String)  // baseURL with .openAI/.anthropic/.gemini, or .local with a public host
        case modelRequired               // baseURL without a model
        case invalidBaseURL(String)
        var isUsageError: Bool           // true for the last three (tonamox exits 2; otherwise 1)
    }

    static func resolve(
        _ choice: Choice,
        model: String? = nil,             // nil: the provider's default (local: largest context window)
        baseURL: String? = nil,           // any OpenAI-compatible server; key from AURA_API_KEY
        environment: [String: String],
        readKey: (String) -> String?,     // e.g. KeychainStore.read(for:); called only for .openAI/.anthropic/.gemini
        localProviders: [LocalProviderStatus]   // from LocalProviderDetector.detectAll()
    ) throws(Failure) -> RemoteTarget
}
```

A `baseURL` host that is loopback, private (RFC 1918, IPv6 ULA), link-local, `localhost`, `*.local` or
`*.home.arpa` gets the origin `.localNetwork(.llamaServer)`; any other host is `.cloud`.

### Keys, cost & privacy

```swift
// BYOK API keys — Keychain only (WhenUnlockedThisDeviceOnly, never iCloud-synced).
// Accounts read by Tonamox: "cloud.anthropic" · "cloud.openai" · "cloud.gemini" · "download.huggingface"
// (Hugging Face token for gated repos, KeychainDownloadAuth.huggingFaceAccount; also used by
// ModelCompatibilityChecker) · "download.<host>" (bearer token for any other download host).
// "cloud.github-models" is no longer read (GitHub Models was retired).
// iOS/visionOS with an App Group configured: save writes to the group's access group; the app's existing items
// are copied into the group once, ever (the private copies stay); until that copy finished read and hasKey fall
// back to any group the app has, afterwards they read the group only; delete removes every copy the app can
// reach. macOS: unchanged (login keychain, no access groups).
public enum KeychainStore {
    static func save(_ key: String, for account: String) throws
    static func read(for account: String) -> String?
    static func delete(for account: String)                 // every copy in the access groups the app has
    static func hasKey(for account: String) -> Bool         // attributes only; never reads the secret
}
// KeychainDownloadAuth.saveHuggingFaceToken(_:) (trims; throws on empty), .deleteHuggingFaceToken(),
// .hasHuggingFaceToken

// USD per 1M tokens.
public struct TokenPrice: Sendable, Hashable {
    var inputUSDPerMillion: Decimal
    var outputUSDPerMillion: Decimal
    init(inputUSDPerMillion: Decimal, outputUSDPerMillion: Decimal)
}

@MainActor
public final class CostLedger: ObservableObject {
    static let shared: CostLedger      // HybridEscalator's default ledger
    init()                             // starts with the built-in prices

    @Published private(set) var records: [Record]   // per-escalation token + $ accounting, all sessions
    // The totals below cover the records since the last startNewSession().
    var sessionTokens: Int
    var sessionCostUSD: Decimal        // priced records only, estimated ones included
    var unpricedRecordCount: Int       // records whose costUSD is nil
    var estimatedRecordCount: Int      // records priced from estimatedUsage
    var sessionRecordCount: Int        // priced and unpriced
    func startNewSession()             // keeps records, restarts the totals

    // model nil = every model of the provider; a nil price removes the entry.
    func setPrice(_ price: TokenPrice?, provider: String, model: String? = nil)
    // The model-specific price, else the provider-wide one, else nil.
    func price(provider: String, model: String? = nil) -> TokenPrice?
    // 0 for local-network targets, nil for an unpriced cloud model.
    func projectedCost(target: RemoteTarget, inputTokens: Int, maxOutput: Int) -> Decimal?
    // Deprecated: the static form reads CostLedger.shared's prices.
    static func projectedCost(target: RemoteTarget, inputTokens: Int, maxOutput: Int) -> Decimal?

    // estimatedUsage is priced only when usage is nil.
    func record(provider: String, model: String? = nil, usage: TokenUsage?, estimatedUsage: TokenUsage? = nil,
                origin: RemoteTarget.Origin, compressionRatio: Double?)

    struct Record: Identifiable, Sendable {
        let id: UUID
        let provider: String
        let model: String?
        let isLocalNetwork: Bool
        let usage: TokenUsage?         // reported by the provider
        let estimatedUsage: TokenUsage? // conservative estimate used when usage is nil; not in sessionTokens
        let costUSD: Decimal?          // nil: a cloud call with no price, or with neither usage nor estimate
        let compressionRatio: Double?
        var isEstimated: Bool          // costUSD came from estimatedUsage
    }
}

@MainActor
public protocol ConsentGate: Sendable {
    // projectedCostUSD is nil when the target's price is unknown. From routeAndEscalate, preview is the
    // payload's compression: its keptText is the context as sent, without the question or system prompt.
    func requestConsent(target: RemoteTarget, preview: CompressionResult,
                        projectedCostUSD: Decimal?) async -> Bool
    // What routeAndEscalate calls. Default: declines .costCapped, passes any other offer to the method above.
    func requestConsent(target: RemoteTarget, preview: CompressionResult,
                        offer: EscalationOffer) async -> Bool
}

public struct EscalationOffer: Sendable, Equatable {
    init(reason: EscalationReason, projectedCostUSD: Decimal?, sessionSpentUSD: Decimal,
         unpricedRecordCount: Int, costCapUSD: Decimal, payload: EscalationPayload? = nil)
    let reason: EscalationReason
    let projectedCostUSD: Decimal?     // payload's estimated tokens + maxTokens; nil when the target is unpriced
    let sessionSpentUSD: Decimal       // CostLedger.sessionCostUSD; a lower bound while unpricedRecordCount > 0
    let unpricedRecordCount: Int
    let costCapUSD: Decimal            // policy.costCapUSDPerSession
    let payload: EscalationPayload?    // what approval sends; routeAndEscalate always sets it
}
```

A call that throws after it streamed text (a cancel, a dropped stream) is still recorded, with the
usage the provider reported before failing, if any; a cloud call recorded without usage has an
unknown cost. A call that fails before any output is not recorded. A provider response that carries
only one of the two token counts is treated as no usage.

Built-in prices, approximate list prices to override with your plan's: `claude-sonnet-4-5` on
`"cloud.anthropic"` ($3 in / $15 out per 1M tokens) and `gpt-4o` on `"cloud.openai"` ($2.50 / $10).
No provider-wide defaults exist, so any other model starts unpriced.

```swift
let ledger = CostLedger.shared
ledger.setPrice(TokenPrice(inputUSDPerMillion: 0.5, outputUSDPerMillion: 1.5), provider: "my-gateway")
let projected = ledger.projectedCost(target: target, inputTokens: 2_000, maxOutput: 1_024)   // Decimal?
```

Also available: `ContextCompressor` (token-saving compression), `PIIRedactor`,
`ResponseCache`, and `NetworkMonitor`.

### Limitations

- `CostLedger` prices only the two default cloud models out of the box. Any other cloud model is
  unknown (`nil`), not free, until you call `setPrice`, and until then the router offers each
  escalation to it with `.costUnknown` rather than checking the cap. Unpriced records add nothing to
  `sessionCostUSD`, so while `unpricedRecordCount > 0` a priced request under the cap is offered as
  `.costUnknown` too.
- Only `routeAndEscalate` applies the cap. `escalate(to:)` sends without checking it.
- `ResponseCache.shared` is in memory only (64 entries by default, cleared on relaunch). `HybridEscalator`
  keys it on the provider's `cacheIdentity` (id plus endpoint for the bundled providers), the model, the
  whole payload: system prompt, user message (compressed context plus question) and `maxTokens`, and a
  temperature other than the default 0.7, and does not cache an empty or whitespace-only answer.
  `lookup`/`insert` with `payload:` take an optional `temperature:` (nil keys as before).
  `lookup`/`insert` with `prompt:` key on that string alone.
- `PIIRedactor` is pattern-based (emails, `sk-…`/`pk_…`/`rk-…` keys, bearer tokens, Slack and GitHub
  tokens, AWS access key IDs) and covers the context and the question only. The system prompt is
  sent verbatim on every path.
