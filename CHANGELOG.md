# Changelog

Notable changes to TONAMOX. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Swift package consumers pin TONAMOX by `revision:` (a version requirement cannot resolve; see
[Installation](docs/guide/installation.md#pin-a-commit)), so a tag marks a release and locates the `tonamox` CLI
tarball; it is not a version you can require.

## [Unreleased] (planned 1.4.0)

Changes since `v1.3.0` (7653c93, 2026-07-08). `v0.1.0` (97ab9d1, 2026-07-10) was tagged two days later on the
same history, so it already contains the first hybrid, SystemTool and `aura` CLI entries below.

### License

- TONAMOX is now licensed under **AGPL-3.0-or-later**, or under a commercial license from the copyright holder
  (af056da). Commits up to and including 1647874, among them every earlier tag (`v0.1.0`, `v1.0.0`–`v1.3.0`),
  remain under the MIT License. See [License](README.md#license).
- Contributions are accepted under the terms in [CONTRIBUTING.md](CONTRIBUTING.md) and must be signed off.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the dependencies' licenses.

### Breaking changes

- **Renamed to TONAMOX.** The repository is `github.com/iOSDevC/Tonamox`, the modules are `TonamoxCore`,
  `TonamoxUI`, `TonamoxVoice`, `TonamoxDocs`, `TonamoxAgents`, `TonamoxAppleIntelligence` and `TonamoxImageGen`, the main
  type is `Tonamox` (with `TonamoxProfile`, `TonamoxSession`, `TonamoxError`), and the CLI is `tonamox`. On-disk
  folders keep the `AuraLocal` name, so existing downloads stay in place. The exception is `DocumentLibrary`'s
  default index, which moved from `AuraLocal/docs` to `Tonamox/docs`. An index in the old folder is read again only
  by an app that configures App Group sharing (see Fixed).
- `InferenceBackend` has a new requirement, `generate(prompt:systemPrompt:maxTokens:constraint:onToken:)`.
  A custom backend must implement it; one that cannot enforce the constraint throws
  `GenerationConstraintError.unsupportedBackend`.
- `Model.textModels`, `.visionModels`, `.specializedModels`, `.ggufModels`, `.mlxModels`, `.runnableModels`,
  `Model.models(in:)`, `HardwareAnalyzer.compatibleModels()` and `HardwareAnalyzer.compatibleModels(purpose:)`
  leave uncensored models out, so AuraUI's pickers list one only once it is downloaded. `Model.uncensoredModels`
  lists them, `Model.allModels` still has every model, and AuraExample's Catalog shows them behind a toggle.
- `Model.gemma4_1b`, `.gemma4_4b`, `.granite4_compact`, `.lfm25_3_2b`, `.ministral_3b` and `.graniteVision_3_3`
  are `@available(*, unavailable)`, with the reason in the message: none of them ever downloaded a loadable model.
- Tools on an MLX vision or document model throw `ModelConfigurationError.toolsUnsupported(.mlx)` from
  `ModelManager.load` and `AuraSession` instead of being dropped silently. GGUF tool calling is unchanged.
- **Behaviour change (MLX tools):** an MLX text model loaded with tools runs them with the same tool loop as GGUF
  (`toolLoop`, `ToolEvent`, `lastToolTurn`, `{"error": …}` results, one round by default), with calls parsed in the
  format mlx-swift-lm infers from the model's `config.json`. `ModelCapabilities.tools` includes MLX text models
  outside the iOS Simulator.
- **Behaviour change (MLX cancellation):** an MLX call cancelled before it starts, or while it waits for another
  generation on the same weights, throws `CancellationError` without prefilling, as on GGUF, instead of
  prefilling the prompt and returning one token's text.
- **Behaviour change (MLX prompt cache):** an MLX text model keeps the KV cache of its last generation, so the
  next prompt prefills only the tokens it does not share with it (prefill over an 8-turn conversation with Qwen3
  0.6B: 0.46–0.61 s against 1.44–1.80 s). The cache stays in memory until `unload()` or an eviction. A greedy
  reply can differ from a full prefill's after a few dozen tokens, as with any change of prefill split; on a hit
  `lastGenerationStats.promptTime` covers only the tokens prefilled, so `prefillTokensPerSecond` overstates
  prefill speed, and AuraExample's model evaluation no longer shows it. MLX stats are timed by TONAMOX around
  mlx-swift-lm's token iterator instead of read from `GenerateResult`.
- **Behaviour change (GGUF tools):** calls a model makes after `maxToolRounds` rounds (default 1, as many rounds as
  before) are reported as `ToolEvent.roundLimitReached` and in `ToolTurnSummary.skipped` instead of being dropped
  silently; a tool that throws, arguments that do not decode and an unknown tool name reach the model as
  `{"error": …}` instead of failing the turn (`ToolLoopOptions(toolErrors: .failTurn)` restores that); tool output
  reaches the model as JSON with sorted keys instead of `key: value` pairs in random order; with a chat template that
  supports tools, the resumed prompt carries the model's call as an assistant turn and each result as a `tool` turn
  in the template's own format; with other templates each round is sent as one assistant turn, the model's call as
  `<tool_call>` text followed by every result in `<tool_response>` (before, only the results were sent, and only
  the last one as an assistant turn), so templates that require alternating roles, such as Gemma 3's, render it;
  after a result the tool instructions are sent again while another round may run (before, only the first reply's
  prompt carried them, so on a template without tool support a later round had no list of the tools).
- **Behaviour change (GGUF tools):** models asked to write calls as `<tool_call>` JSON (templates without tool
  support, and templates that write calls that way, such as Qwen2.5's) run on TONAMOX's own llama.cpp context and
  tool-call parser instead of LocalLLMClient's `LlamaClient`: every call in a reply runs (LocalLLMClient kept only
  the first per tool name); a `<tool_call>` block that is not a JSON object with a `name` stays in the reply text
  instead of vanishing; arguments reach the tool as JSON with sorted keys; a round goes back to the model as the
  reply it wrote, `<tool_call>` text included; `maxTokens` counts the calls' tokens too; and a reply cut short no
  longer makes the next turn wait for its decode to finish. Other call formats keep the `LlamaClient` path.
- **Behaviour change (GGUF):** when a chat template ends with a newline, the prompt no longer does: TONAMOX drops
  one trailing newline from the template, as Python Jinja (Hugging Face's and llama.cpp's renderers) does, so
  Qwen2.5's prompt ends `<|im_start|>assistant\n` instead of `<|im_start|>assistant\n\n`. Replies at temperature 0
  can differ from before.
- **Behaviour change:** AuraUI's `TextChatTab`, `VisionTab` and `OCRTab` and AuraDocs' `DocsTab` no longer download
  a model without asking. While a model they need is not on disk they show `ModelDownloadPlaceholder` with
  **Download**; models already on disk load as before. `DocsTab` used to download Qwen3 1.7B and FastVLM (~2 GB)
  as soon as it appeared. Each tab takes `autoDownload: Bool = false`; pass `true` to keep the old behaviour.
- Hybrid API, for code written against `v0.1.0` or a revision before 2026-09-30:
  - `OpenAICompatibleProvider.gitHubModels(apiKey:)` and the `cloudTargets` overload taking `gitHubModelsModel:`
    are `@available(*, unavailable)`: GitHub retired GitHub Models on 2026-07-30.
  - `ConsentGate.requestConsent(target:preview:projectedCostUSD:)` takes `Decimal?` (`nil` when the model is
    unpriced), and the protocol gains `requestConsent(target:preview:offer:)`, which has a default.
  - `CostLedger.Record.costUSD` is `Decimal?`, `RoutingInput.projectedCostUSD` is `Decimal?`, and
    `EscalationReason` has a new case, `.costUnknown`.
  - The static `CostLedger.projectedCost(target:inputTokens:maxOutput:)` is deprecated in favour of the instance
    method.
- **Behaviour change:** with an `outputSchema`, no tools and a GGUF model on `LlamaCppBackend`, each `AuraSession`
  generation (repairs included) runs on a dedicated constrained llama.cpp client: replies follow the schema's
  structure by construction, with required properties in `required` order and optional ones by name; objects
  carry only their declared properties, even when `additionalProperties` allows more; each generation pays a
  client build and grammar sampling (1.0–1.35 s against 0.41–0.60 s per reply on Qwen2.5-0.5B, M1 Pro; see
  [Schema grammars](docs/guide/backends.md#schema-grammars)). This includes `tonamox receipt extract|eval --model`
  with such a model. MLX and layer-streaming keep validation only. `usesSchemaGrammar = false` restores the
  previous path.
- `LocalProviderKind` has a new case, `.magnitude`: an exhaustive `switch` over it needs a branch for it.
- `RemoteEvent` has a new case, `.reasoning(String)`: an exhaustive `switch` over it needs a branch for it.
  `OpenAICompatibleProvider` yields a server's reasoning deltas (`reasoning_content`, or `reasoning`) as
  `.reasoning` instead of dropping them; the escalation path leaves them out of the answer, but a stream that
  fails after them is recorded in the cost ledger.
- **Behaviour change:** `LocalProviderEndpoint.defaults` also probes Magnitude
  (`http://127.0.0.1:10100/inference/v1`), so `detectAll()`, `Tonamox.detectLocalProviders()` and
  `tonamox providers` return three statuses instead of two, and `bestLocalTarget()` and `tonamox ask` fall back to
  a running Magnitude after llama-server and Ollama.
- **Behaviour change (deletes):** `ModelDownloads.delete`, `deleteRepo` and `deleteFolder`, and with them
  `CoreMLDiffusionModel.delete()`, throw the new `ModelFilesInUseError` and delete nothing while a download holds
  the model's lock file, in this process or in another one sharing the storage root. Before, they deleted the
  files under the running download.
- `DownloadRecords.standard` and `CoreMLDiffusionModelStore.standard` are computed `static var`s instead of
  `static let`s, so they can resolve the App Group (source compatible).

### Added

- Hybrid local + remote inference: `HybridEscalator`, `EscalationRouter`, `OpenAICompatibleProvider`,
  `AnthropicProvider`, `ConsentGate` with the exact payload, `KeychainStore` (bring your own key),
  `PIIRedactor`, `CostLedger` with per-model prices and a session cap, `ResponseCache` and `ContextCompressor`.
- `AuraAgents`: the `AgentCrew` multi-agent pipeline as a library, with per-step escalation and recall of what
  earlier runs established.
- `AuraImageGen`: Core ML Stable Diffusion on iOS and macOS, including models inspected and adopted from Hugging
  Face (`CoreMLDiffusionInspector`), and FLUX + LoRA through mflux on macOS.
- On-device ML tools: Vision OCR (`VisionOCRTool`, `recognizeLines`), image classification, barcodes and faces;
  language identification, entities and sentiment; sound classification; Core ML models; text classifiers and
  Create ML training; `CoreMLTextEmbeddingTool` and opt-in multilingual-e5-small embeddings in `AuraDocs`.
- The `tonamox` CLI: `providers`, `tools`, `ask`, `ocr`, `ml`, `models search|check|devices` and `imagegen`.
- `ModelCompatibilityChecker`: whether a Hugging Face repo runs on the pinned runtimes, and why not; Hugging Face
  search with a device-fit filter; the Model Finder example app; the AuraUI Hugging Face browser.
- `ModelDownloads`: resumable GGUF and MLX downloads, gated and private repos, one folder of a repo pinned by
  revision (`HFRepoInfo.revision`, `deleteFolder`), and `DownloadRecords` that survive relaunches.
- `DownloadConflictError.partialChanged(path:)`: a finished `.partial` that another writer removed or resized before
  it was moved into place fails with this instead of a raw file-system error, and nothing is replaced.
- GGUF: `GenerationConstraint` (`.json`, `.grammar(gbnf:root:)`) enforced in llama.cpp's sampler, and
  conversations rendered with each model's chat template and real roles.
- `GenerationStats` after each generation, a decode-speed estimate, and `HardwareAnalyzer.assess` judging wall
  clock as well as memory.
- KV cache sizing per layer type and MoE decode by active experts; `Model.maxContextLength`; MLX `maxKVSize` and
  `lastContextOverflow`.
- iOS: generation stops when the app backgrounds (`GenerationInterrupted`), an opt-in `DeviceConditions` guard,
  and models judged against the app's memory limit.
- `AuraSession` enforces an `OutputSchema` by validation and repair.
- On a GGUF model loaded in full, `AuraSession` decodes `OutputSchema` replies under a GBNF grammar built from the
  schema (profiles without tools); `AuraSession.usesSchemaGrammar` turns it off.
- `temperature:` and `topP:` on `ModelManager.load` and `Tonamox.text`, `.vision` and `.specialized`.
- `PrivacyInfo.xcprivacy` manifests for `AuraCore`, `AuraImageGen` and the AuraExample app.
- `VisionDocumentTool` (`system.vision.document`, iOS 26 / macOS 26): Vision's `RecognizeDocumentsRequest` with
  paragraphs, tables and lines with boxes, and the money amounts (as `Decimal` plus currency), dates, contacts and
  links Data Detection finds; `tonamox ml document <image>` prints them.
- `tonamox receipt extract|eval`: receipt fields (merchant, date, total, tax, currency) read from a photo by a
  rule-based baseline and, with `--model`, by a local model at temperature 0 under a JSON Schema. Model values are
  checked against the OCR text, and `eval` scores both against a labelled CSV with pass/fail thresholds (exit
  status 1 on a failed gate, 2 when the run cannot finish or an image cannot be read). Currency is reported but not
  scored or checked. The deterministic part lives in the `ReceiptSpike` target, which is not a library product.
- `Model.license`, the license the model's Hugging Face card states, and `Model.hasPermissiveLicense` (Apache-2.0
  or MIT; an unrecorded license is not permissive). The catalog's `license` key is checked and written by
  `scripts/verify_catalog.py`, and `tonamox models check --entry` fills it in. 46 of the 53 entries record one; the
  other seven model cards declare none. `Model.listedModels` is the catalog
  without its uncensored entries.
- Continuous integration (`.github/workflows/ci.yml`) and a weekly canary that resolves without the lockfile.
- `ModelDownloadPlaceholder` (AuraCore, SwiftUI): stands in for a feature whose models are not on disk, with each
  model's purpose and size, the free space and a warning when it may not fit, **Download**, progress, Cancel and
  Retry, and an `onReady` callback once the files are there. `RequiredModel`, `[RequiredModel].notDownloaded`,
  `OnDemandDownloads` (one transfer at a time through `ModelDownloads`, tracked by file) and
  `Model.approximateSizeBytes` go with it; `DocsTab.neededModels` lists what `DocsTab` loads.
- GGUF tool loop controls: `ToolLoopOptions` (`maxToolRounds`, `toolErrors`) on `Tonamox.toolLoop` and
  `AuraProfile.toolLoop`, `ToolEvent` through `Tonamox.onToolEvent` and `AuraSession.onToolEvent`, and
  `ToolTurnSummary` in `lastToolTurn`.
- Tool calling on MLX text models, with the same controls. `ModelManager.load(_:tools:)` runs an MLX tool instance
  on the weights of a cached instance of the same model instead of loading a second copy.
- Magnitude detection: `LocalProviderKind.magnitude`, `LocalProviderEndpoint.magnitudeDefault` and
  `LocalProviderKind.displayName`. Magnitude's models come from `GET {base}/models`, with its `context_length` as
  `LocalProviderModel.contextLength` and no version; `OpenAICompatibleProvider.from(_:)` names it
  "Magnitude (local)" and keeps its base URL. Only this machine is probed: a Magnitude elsewhere needs its Network
  access on and `OpenAICompatibleProvider(id:displayName:baseURL:apiKey:)` with its key. Magnitude is a separate app
  whose update check sends hardware information and whose `magnitude server setup` installs a self-updating
  background service.
- Engine benchmark: `EngineBenchmark` runs `BenchmarkCandidate`s (an in-process `Tonamox`, or a model on a local
  llama-server, Ollama or Magnitude) one at a time through `BenchmarkWorkload`s (`chat`, `code`, `longDocument`)
  and returns a Codable `BenchmarkReport`: per workload the median, minimum and maximum time to first token,
  prefill and decode tok/s of the measured runs (prefill exact only for in-process MLX, `hasExactPrefill(in:)`),
  token counts with their provenance, peak process memory for in-process models as `BenchmarkMemory`
  (`phys_footprint` and `resident_size`, which count llama.cpp's mapped GGUF weights differently), the warm-up runs,
  and `OutputAgreement` with the first engine at temperature 0; per candidate the load time and
  `coldTimeToFirstToken` (load plus the first run's time to first token). Each run's system prompt starts with a
  run marker (`runMarkerFormat`, `runMarkerNonce`) so prompt caches cannot turn later runs into hits. Server runs
  time reasoning deltas like answer deltas and keep them in the output inside `<think>…</think>`, so a reasoning
  model compares with an in-process one. `BenchmarkCandidate.inProcess(_:)` loads an uncached instance, so the
  app's own instances are never reused or released; cancelling the benchmark cancels that load too.
  `tonamox bench` drives it from the command line: it exits 1 when no engine produced a measured run, and Ctrl-C
  prints the partial report and exits 130. `GenerationStats.Provenance` is now `Codable`.
- TonamoxExample: **Compare engines** in Chat's model sheet runs `EngineBenchmark` over the downloaded models and
  the models of detected local servers, with workload, run-count and temperature settings, progress and Cancel,
  and per-workload results that mark the fastest decode and time to first token and warn when the engines ran
  different models or a server may have cut the prompt, plus each engine's cold start.
- `IncompatibleGGUFError` (`filename`, `blockers`, `underlyingMessage`): when llama.cpp fails to load a GGUF, the
  llama.cpp backends read its first `ModelCompatibilityChecker.defaultGGUFHeaderBytes` (4 MiB) and, if
  `gguf.architecture` (other than "not a chat model") or `gguf.qwen35-nextn` blocks it, throw this instead of
  `LLMError.failedToLoad`. The blocker comes from the header alone; other failures keep their error, and a file that
  loads is never checked.
- App Group shared storage: `TonamoxSharedStorage.configure(appGroup:)`, called first in `App.init`, lets the apps
  of one App Group share models, download and image-model records, conversations, the document index, the e5
  bundle and, on iOS and visionOS, the keychain items of service `dev.auralocal.remote`. The call returns
  `SharedStorageConfiguration` (`.applied`, `.unavailable`, `.ignored`), and the active scope is
  `TonamoxSharedStorage.scope`. On iOS (and in a sandboxed Mac app with the entitlement), the scope is
  `.appGroup` and the data lives in the group container. A Mac app without App Sandbox gets `.userWide`: files
  stay user-wide, and records are kept in `AuraLocal/download-records.json` and `image-model-records.json` there.
  When storage moves into the group, the app's private model files and e5 bundle are renamed into it. Records,
  conversations, document indexes and keychain items are copied once, and the private copies stay. An older
  build of the same app on the same device therefore no longer sees the moved models. Not configured, nothing
  changes. See [Sharing storage between apps](docs/guide/models.md#sharing-storage-between-apps-app-group).
- `TonamoxSharedStorage.didChangeNotification`, `change(of:)` and `postChange(_:)` with `SharedStorageChange`
  (`.models`, `.conversations`, `.documents`): posted after downloads, deletes, record changes, conversation
  writes and document-library changes, through Darwin notifications to every app of the group (in-process
  without one). `ModelDownloadCenter.reloadSharedState()` re-registers records and unregisters models whose
  record another app deleted; the center runs it on every `.models` signal. `DocsTab` reloads its documents on
  `.documents` and when its scene becomes active again, since a suspended app misses the signals.
- iOS App Group apps close their shared SQLite connections when they enter the background. While backgrounded,
  each `ConversationStore` and document-index call opens, runs in its own background task and closes, and download
  locks are released when the background time runs out, because iOS kills a suspended app holding a lock in a
  shared container.
- `ModelFilesInUseError` (`name`) and `ModelStorageMigration.duplicatesRemoved`.
- TonamoxExample project: four more apps, each with a shared scheme: **TonamoxChat** (Chat and Voice),
  **TonamoxImage** (Image), **TonamoxLibrary** (`DocsTab`) and the iOS-only **TonamoxTerminal** (a read-only
  list of the shared models). They are built from the Example's feature folders. All five configure
  `group.io.iosdevc.tonamox` and carry it in their iOS builds; the Mac builds carry no App Group.

### Changed

- AuraExample's Library and (macOS) Agents tabs ask before downloading their models, like the SDK tabs (see
  Breaking changes).
- MLX is back: `AuraCore` links mlx-swift-lm again and offers both engines.
- LocalLLMClient is pinned by revision `edc39ef` (tag 0.5.0, llama.cpp b8851); mlx-swift-lm from 3.31.3;
  ml-stable-diffusion exact 1.1.1; mlx-swift `0.31.3..<0.31.5`.
- Toolchain floor: Swift 6.1 / Xcode 16.3; Xcode 26 for `AuraAppleIntelligence` and `AuraAgents`; Xcode 26.4 for
  `AuraImageGen` and the `tonamox` CLI.
- The model catalog is verified against Hugging Face (`scripts/verify_catalog.py`); several entries moved repo
  (Dolphin 8B to `dphn/`, so it downloads again).
- The context window follows the model's KV cost and the memory left after its weights, capped at what the
  weights support; memory on macOS is measured instead of assumed.
- A GGUF turn whose rendered prompt starts with exactly the last turn's prompt and reply, and goes on with a special
  token, decodes only what it adds; any other turn starts from an empty KV cache and re-prefills the history, and so
  does every turn after a reply that was cut. Tool rounds on templates with native tool turns (Qwen2.5's) reuse the
  cache the same way while another round may run; on templates without tool support each round's results join the
  reply's assistant turn, so every round re-prefills. After a ~2,400-token system prompt, Qwen2.5-0.5B's time to the
  first token stayed near 50 ms instead of about 800 ms (M1 Pro). A reused turn keeps the reply's tokens as sampled
  and as llama.cpp computed them one at a time; a full prefill re-tokenizes the reply text (usually, not always, to
  the same tokens) and computes it in one batch, so at temperature 0 a reused turn can now and then pick a different
  token.
- `tonamox ask` uses a local llama-server, Ollama or Magnitude by default, or OpenAI, Anthropic or a custom endpoint when named.
- Without a configured App Group, behaviour is close to before but not identical: `ConversationStore` and the
  document index wait up to 3 s (`busy_timeout`) for another connection's lock instead of failing at once with
  `SQLITE_BUSY`; deletes refuse with `ModelFilesInUseError` while a download holds the lock (see Breaking);
  download records are encoded with sorted keys; and record, conversation and document-library changes post
  `TonamoxSharedStorage.didChangeNotification` in-process, so `ModelDownloadCenter` re-scans the registry and
  `DocsTab` reloads its list (it re-reads the chunks only when the set of documents changed).
- `KeychainStore.hasKey(for:)` reads the item's attributes only, never its secret.
- `DownloadRecords` and `CoreMLDiffusionModelStore` writes that change the records post
  `TonamoxSharedStorage.didChangeNotification` (in this process only when no group is configured), and an
  unchanged `remember` no longer rewrites the store.
- TonamoxExample's sources are split into feature folders (`Chat`, `Voice`, `Image`, `Models`, `Hybrid`, `ML`,
  `Agents`, `Common`, `CommonUI`) shared by the five apps. Its iOS builds use `TonamoxExample-iOS.entitlements`
  with the App Group. `HuggingFaceTokenSection` no longer says other apps can't read the token.

### Fixed

- `VoiceSession.interrupt()` and `cancel()` now stop the reply being generated. Before, the reply kept
  generating, set the state back to `.thinking` and was still spoken after either call.
- `ModelManager.state(for:)` no longer returns to `.downloading` after `.loading`: load messages such as
  "… ready" keep `.loading`, and only download progress shows as `.downloading`.
- TONAMOX resolves for integrators (the swift-syntax conflict between LocalLLMClient and mlx-swift-lm).
- AuraCore builds for the iOS Simulator, and GGUF runs there.
- Conversation search after deletes, turns stored in the same millisecond, one reply per prompt when a generation
  stops, and `stream(_:in:)` and Apple Intelligence streams cancelling when the consumer stops.
- Consent shows, caches and prices the exact escalation payload; redaction applies on the policy path; the cost
  cap holds at the consent gate; unknown spend is never priced as $0.
- `HybridEscalator` no longer caches an empty or whitespace-only answer (a reasoning model that spent `maxTokens`
  thinking), which `ResponseCache` then served for every repeat of the request; and an escalation whose stream
  fails after reasoning deltas is recorded in the cost ledger.
- A loaded model stays ready when another sampling load fails.
- Two downloads of one model no longer write the same `.partial` files at once, which failed one of them with
  "`<file>.partial` doesn't exist". `ModelDownloads.download` and `downloadFolder`, `GGUFModelDownloader`, the MLX
  load path and `ChunkedDownloader` wait for each other per file or per Hugging Face snapshot, in one process and,
  through a `flock` on a lock file next to the destination, across processes sharing the storage root (the `tonamox`
  CLI and AuraExample on a Mac). The later call returns the finished model without a transfer.
- `ChunkedDownloader` replaces a file already at the destination instead of failing with "an item with the same
  name already exists" on a single-stream download, and keeps it without a transfer when it hashes to the
  `expectedSHA256` passed.
- `GGUFModelDownloader.cancel()` also ends calls of that downloader still waiting for the file, and a download
  cancelled while it verifies is no longer moved into place after the next download of the file started.
- RAG document IDs survive relaunches, and vectors from a provider the index no longer matches are never stored.
- The memory safeguards that were documented but inert (`evictAllButMostRecent`, the iOS OOM guards).
- `scripts/package-cli.sh` finds the build products of newer SwiftPM (`.build/out/Products/Release`), and the
  `tonamox` tarball now carries the SwiftPM resource bundles and the license texts.
- GGUF tool turns: a resumed prompt that outgrew the context failed the turn; every round's prompt now drops the
  oldest exchanges, as the first one does.
- GGUF tool instructions listed the tools as JSON with its keys in a different order on every render; the keys are
  sorted now.
- A GGUF that llama.cpp b8851 cannot load reported only "Failed to load model from file". It now names the header's
  blocker (an architecture b8851 does not know, a `qwen35` MTP block that needs b9180) through
  `IncompatibleGGUFError` (see Added).
- In an app that configures App Group sharing, the document index an earlier build kept in `AuraLocal/docs` (the
  default before the rename to `Tonamox/docs`) is merged into the shared index once, when its embedding model
  matches or the shared index is empty. Without sharing it is still not read.

### Removed

- The GitHub Models preset; `cloudTargets` no longer reads the `cloud.github-models` Keychain entry.
- Six catalog entries (see Breaking changes).

### Security

- Cloud API keys live only in the Keychain, this device only.
- The compatibility checker no longer traps on crafted GGUF headers or `config.json` files.
- mlx-swift is held below 0.31.5: 0.31.6 is the version in an open report of an app hanging before `main()` on an
  iPhone running iOS 27 (mlx-swift #485), and 0.31.5 does not build for iOS (#436).

## [0.1.0] - 2026-07-10

First public release, MIT licensed: the `aura` CLI tarball for Homebrew, the hybrid MVP, the SystemTool layer and
the LocalLLMClient revision pin.

[0.1.0]: https://github.com/iOSDevC/Tonamox/releases/tag/v0.1.0
