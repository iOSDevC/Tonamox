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
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the dependencies' licenses. It now holds the exact pins
  of both `Package.resolved` files (root and the Example project's), the code those packages vendor (llama.cpp,
  MLX, mlx-c, {fmt}, nlohmann/json, metal-cpp, miniaudio, llhttp) and the full licence and NOTICE texts;
  `scripts/check-notices.py` fails when a pin is missing or differs. The five example apps bundle it and show it,
  offline, under "Código abierto y licencias".

### Breaking changes

- **Renamed to TONAMOX.** The repository is `github.com/iOSDevC/Tonamox`, the modules are `TonamoxCore`,
  `TonamoxUI`, `TonamoxVoice`, `TonamoxDocs`, `TonamoxAgents`, `TonamoxAppleIntelligence` and `TonamoxImageGen`, the main
  type is `Tonamox` (with `TonamoxProfile`, `TonamoxSession`, `TonamoxError`), and the CLI is `tonamox`. On-disk
  folders keep the `AuraLocal` name, so existing downloads stay in place. The exception is `DocumentLibrary`'s
  default index, which moved from `AuraLocal/docs` to `Tonamox/docs`. An index in the old folder is read again only
  by an app that configures App Group sharing (see Fixed).
- **Apple Intelligence APIs now require iOS 27 / macOS 27 / visionOS 27.** `AISession`, `AIAgent`, `AIPipeline`,
  `AIAvailability`, `AIAvailabilityGate`, `AISessionError` and TonamoxAgents' `AgentCrew` are
  `@available(iOS 27, macOS 27, visionOS 27, *)` (they were iOS 26 / macOS 26) and need the Xcode 27 SDK.
  `AISessionError` maps the OS 27 FoundationModels errors (`LanguageModelError`, `SystemLanguageModel.Error`,
  `LanguageModelSession.Error`, `GeneratedContent.ParsingError`); on OS 27 the old `GenerationError` mapping never
  ran, so these errors reached callers unmapped. It is now `Equatable`, has new cases `assetsUnavailable`,
  `refusal`, `unsupportedLanguage` and `timeout`, and `contextWindowExceeded(limit:tokenCount:)` and
  `rateLimited(resetDate:)` carry payloads. A `switch` over it must handle the new cases. Tool errors
  (`ToolCallError`) and `CancellationError` still pass through unchanged.
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
- `AskTargetResolver.Choice` has a new case, `.gemini`: an exhaustive `switch` over it needs a branch for it.
  `Failure.missingAPIKey`'s `environmentVariable` reads `"GOOGLE_API_KEY or GEMINI_API_KEY"` for it.
- **Behaviour change:** `HybridEscalator.cloudTargets` (and so `candidateTargets` and `routeAndEscalate` without
  `targets:`) also returns a Gemini target, after OpenAI, when the Keychain holds `cloud.gemini`. It is unpriced,
  so the router offers it with `.costUnknown`. An app that already stored that key (TonamoxTerminal does) can now
  escalate to Gemini when it has no Anthropic or OpenAI key and the policy allows cloud. On iOS the App Group
  keychain shares that key with every example app, so their Hybrid settings show a Gemini row with a remove button
  whenever the key is stored.
- **Behaviour change:** an `OpenAICompatibleProvider` stream that sends an error event (`data: {"error":…}`) after
  a 200 now throws `TonamoxError.remoteFailed` with the event's code (or -1) and message. Before, the event was
  dropped and the stream ended normally, so a mid-stream quota or rate-limit stop came back as a successful,
  cached answer. The escalator records such a call like any other failure and caches nothing.
- `HybridEscalator.escalate` no longer splits the response cache by a `temperature` the provider never sends
  (Gemini).
- `tonamox ask` prints a cloud target's retention note to stderr before sending.

### Added

- TonamoxTerminal «Evaluar con Claude»: a second opinion from Claude on probes and Modo Test answers the grader did
  not pass, from the battery page, each saved report level and Modo Test. It runs only from a button and one
  confirmation per batch, which shows the count, the judge model («Modelo juez»: Opus 5.5 by default, Sonnet 5.5 or
  Haiku 5.5), the estimated cost and what is sent. It needs the cloud permission, sends only the part of a batch
  that fits under the session cost cap, runs up to 3 requests at once (cancelable) and records spend in the cost
  ledger. Judgments are saved with the report, exported, and «Aplicar» turns one into a manual validation (Seguridad
  probes keep their confirmation). Requests use `anthropic-version: 2026-10-21`, JSON-schema output, effort `low`
  and server-side fallbacks for Opus and Sonnet; a refusal is shown, never turned into a verdict.
- `ScreenAwakeCoordinator` (TonamoxUI, main actor) keeps `isIdleTimerDisabled` on while any named
  `ScreenAwakeReason` is held, so features no longer turn the idle timer off under each other. `ModelDownloadCenter`
  holds `.download`; changing `keepsScreenAwake` mid-download applies at once.
- `EnvironmentValues.hfRepoCaution` (TonamoxUI): an `HFRepoCaution(id:_:)` the host app supplies, shown under a
  Hugging Face search row and at the top of the repo page; it compares by `id`, and the default `.none` shows nothing.
- TonamoxTerminal marks models whose safety training was removed with «Modificado: sin filtros de seguridad»
  («Sin filtros» where space is short). The mark appears in the model picker, the Hugging Face search and repo
  pages, the battery page, saved reports, the comparison and every export: JSON `safetyFiltersRemoved` and a CSV
  `safety_filters_removed` column. Reports of such models note that safety failures are expected, and «No
  recomendado» stays. Detection is a heuristic over names and tags (uncensored, abliterated, heretic, unfiltered,
  nsfw, jailbreak and similar) plus the catalogue's `isUncensored`; a modified model named without these words is
  missed.
- TonamoxTerminal «Servidor web»: «Mantener la pantalla encendida mientras sirve» (on by default) holds the screen
  awake while the server listens in the foreground; the server still stops if the app leaves the foreground.

- `DocumentLibrary.search(_:topK:)` returns the passages `ask` would ground its answer in, ranked and excerpted the
  same way, without generating one: it needs only the embedding provider and never calls or loads the LLM.
- **Gemini as a cloud preset.** `RemoteTarget.gemini(apiKey:model:)` and `RemoteTarget.defaultGeminiModel`
  (`gemini-3.5-flash-lite`) target Google's OpenAI-compatible endpoint
  (`https://generativelanguage.googleapis.com/v1beta/openai/`, beta) with provider id and Keychain account
  `cloud.gemini`; no `temperature` is sent, as Google deprecated it on 2026-07-21. Its retention note states the
  free tier's terms (Google may use prompts and responses and human reviewers may read them; EEA, UK and
  Switzerland only on paid keys). `cloudTargets` gains a defaulted `geminiModel:`. `tonamox ask --provider gemini`
  reads `GOOGLE_API_KEY`, else `GEMINI_API_KEY`, else the Keychain. `--provider copilot` (or `github`) exits 2
  explaining that Copilot has no official OpenAI-compatible chat API (its SDK runs agent sessions only).
  TonamoxTerminal's Gemini engine now uses the SDK preset and default model, so it no longer sends a temperature,
  and its capability battery no longer offers «Repetir fallidas con otra temperatura» for Gemini. No real Gemini request was made; the endpoint's handling of usage and
  `max_tokens` is unverified.
- **Reasoning control for GGUF models.** `ReasoningOptions` (`.disabled`, `.budgeted(_:)`), `Tonamox.reasoning`,
  `reasoningSupport`, `lastReasoningTurn`, `promptOpenedReasoningTag(for:)` and a `reasoning:` argument on
  `generate(_:systemPrompt:maxTokens:reasoning:onPiece:)`. Thinking off renders the chat template with
  `enable_thinking = false` when it reads that variable (LFM3, LFM2.5, Qwen3); a reasoning budget closes a block
  still open at the budget by decoding the model's closing tag, so the answer always gets its own `maxTokens`.
  On LFM3-1.7B through `tonamox serve`, the chmod question that used to end in "The model reasoned but gave no
  answer." now gets an answer (cut after 1024 reasoning tokens, or none with thinking off). MLX ignores the options
  (TD-067).
- **Server:** `reasoning_effort` (`none`, `minimal`, `low`, `medium`, `high`) and
  `chat_template_kwargs.enable_thinking` on `/v1/chat/completions`; without them a 1024-token reasoning budget
  applies on top of `max_tokens`. A reply whose budget closed the reasoning carries
  `"tonamox": {"reasoning": {"cut": true, "tokens": N}}`; `ServedChatEvent.reasoningCut(tokens:)`,
  `ServerLimits.defaultReasoningBudget` and `maxReasoningBudget` are new. When the model has a context length the
  reasoning budget is lowered to fit next to the prompt and `max_tokens`; `LocalServedModel` now takes the loaded
  window (`Tonamox.contextWindow`) as its context length when none is passed.
- **Browser page:** "Razonar" (no / bajo / medio / alto, sent as `reasoning_effort`) and "Longitud" (512–4096
  tokens up to the hello's `maxTokensCap`, sent as `max_tokens`) menus next to the model menu, kept in the tab;
  "Razonamiento recortado tras N s" /
  "Reasoning cut after N s" when the budget closed the reasoning, answers rendered as safe Markdown (paragraphs,
  bold, italics, inline code, code blocks, lists; links as text, HTML as text) with `\boxed{…}` shown in bold, and
  a Copy button on secure pages.
- `BoxedAnswer.display(_:)` / `plain(_:)` in TonamoxCore unwrap `\boxed{…}`; the page's JavaScript port is checked
  against it on shared fixtures.
- **TonamoxTerminal:** «Longitud de respuesta» (Corta 400 / Media 800 / Larga 1600 tokens, every engine, remote
  consent and cost cap included) and «Razonamiento» (Desactivado / Corto 256 / Medio 512 / Largo 1024, local GGUF
  models; a stored «Automático» becomes Medio) in the model sheet, with the time a full reply takes from the
  model's last measured decode speed. Before a local turn decodes, the budgets are bounded by the model's context
  window and a line under the reply says when they were cut («Respuesta limitada a N tokens por el contexto del
  modelo.»); after a GGUF reply that stopped short of its limit with a prompt that could have filled the window, a
  line says it may be incomplete. Capability probes get a time limit scaled to the run's budgets. «Razonamiento recortado tras N segundos», inline Markdown and `\boxed{}` unwrapping in answer prose,
  and both settings recorded in capability reports. The grader reads `\boxed{754}` and `$\boxed{754}$` as the bare
  value.
- `Tonamox.contextWindow`: the KV window the loaded model got on this device (llama.cpp `n_ctx` for GGUF, the
  rotating cache for MLX), `nil` before a load and for remote models.

- **LFM3 GGUF models (local build only).** Tonamox builds against llama.cpp b12407 through a local LocalLLMClient
  0.5.0 fork (`../LocalLLMClient-tonamox`, not published), so `lfm3` GGUFs load; on an M1 Pro LFM3-1.7B Q4_K_M
  decodes at 40 tok/s through `tonamox bench`. The compatibility tables follow b12407 (`qwen4exp` and `lfm3` are
  known; text-to-speech and speculative draft-head architectures are "not a chat model").
- The Hugging Face search says how many results Compatible only hides ("N ocultos: no correrían aquí") and offers
  to show them.

- **TonamoxUI in Spanish.** Every TonamoxUI screen (Hugging Face search, repo detail, verdict card, download section,
  token form, Downloads, Try it, chat, Vision and OCR tabs) reads its text, accessibility labels and plurals from a
  String Catalog with English and Spanish; the package now declares `defaultLocalization: "en"`. The language
  follows the host app's localization. Sentences built in TonamoxCore stay English (see [TonamoxUI](docs/api/ui.md#localization)).
- **Sampling temperature on escalation.** `HybridEscalator.escalate(_:to:temperature:onToken:)`, `escalate(to:…temperature:)` and `routeAndEscalate(…temperature:)` take an optional temperature sent in the request (nil keeps 0.7). `RemoteLLMProvider.cacheIdentity` (default: `id`) keys `ResponseCache`; `CostLedger.Record` gains `estimatedUsage` and `isEstimated`, the ledger `estimatedRecordCount` and `record(…estimatedUsage:…)`.
- **Adapter detection in the compatibility checker.** `ModelArtifactClassifier` decides whether a repo is a standalone
  model, an adapter (LoRA) for a base model or only auxiliary files (`CompatibilityReport.artifact`, with the
  `ArtifactSignal` that decided). An adapter, such as a single `*-lora-F16.gguf` with `general.type` `adapter`, no
  longer shows "1 of 1 quants fit": the report lists no quant, recommends none, suggests no entry and blocks with
  an `artifact` finding that names the base model and points to a merged GGUF of it. Adapters, projectors and
  `imatrix` files in a model repo are never counted as quants; an adapter header read from one file of a mixed repo
  excludes only that file, and without a readable header a `lora` / `peft` tag or a repo-name word only adds a
  "Might be an adapter" caveat. The recommended quant is now a top-level file whenever one fits, so the verdict
  card, the Recommended badge and the Download default name the same file. Also new: `QuantFit.isTopLevel`,
  `ArtifactClassification.isSuspectedAdapter`, `QuantHint.text(for:)`,
  `CompatibilityReport.recommendedQuant` / `smallestQuant`, `GGUFHeader.generalType` / `tensorNames`,
  `HFRepoInfo.baseModels`.
- **Local server (`TonamoxServer`, new product).** An OpenAI-compatible API (`GET /v1/models`,
  `GET /v1/models/{id}`, `POST /v1/chat/completions` with and without `stream`) on 127.0.0.1 for on-device models
  served through `LocalServedModel`, with API keys issued by the host (`issueAPIKey`), a `GenerationTurnstile` shared
  with the app, and a foreground-only lifecycle that rebinds the same port. Built on the new internal `TonamoxHTTP`
  target (strict HTTP/1.1 subset on Network.framework, no new dependency). No remote models yet. See the [local server guide](docs/guide/server.md).
- Local server output ingest and helper scripts, both opt-in (`ServerFeatures.ingest`, `.scripts`):
  `server.ingest.makeTicket(label:maxBytes:ttl:)` gives a one-time ticket whose `curlSuffix(on:)` makes a computer post
  a command's output to `POST /i/{ticket}` (reserved on the head, consumed on the complete body, 409 on a race or
  reuse, optional `X-Tonamox-Exit-Status`); outputs arrive on `ingest.outputs`, and `untrustedBlock()` strips terminal
  escapes, controls and invisible Unicode and frames the text as untrusted data. `GET /s/tnx-run.sh` serves a fixed
  POSIX script whose SHA-256 is published as `HelperScript.tnxRunSHA256` (also the `ETag`); `HelperScript.runLine`
  builds the fetch, `shasum -c` and run line.
- Local server browser page, opt-in (`ServerFeatures.browserPage`): `GET /` serves an embedded chat page in Spanish
  and English (default from the first Spanish or English entry of the browser's languages, else English; an
  Español / English switch in the header redraws the page in place and is kept per tab in `sessionStorage`; every
  error code the server sends the page has text in both languages, and a bilingual fallback shows if the script
  never runs) with
  streamed answers, a Stop button, egress and "not encrypted" banners, and a guide built from the capability hello
  (models and their egress class, exposure, limits, API client setup, ingest and scripts when enabled). Browsers pair
  with a code shown by a `PairingPresenter` and typed into the page (`openPairingWindow()`, `POST /pair`,
  `POST /pair/{id}`, `denyPairing(_:)`); the browser token (30 min idle, 8 h absolute, memory only) is used for
  `GET /api/session`, `POST /api/session/logout` and the OpenAI routes. `pairedBrowsers`, `disconnectAllSessions()`.
  After pairing the page is chat-first: the transcript fills the viewport between a compact top bar (server name,
  served model, language switch, Guía / Guide button) and the composer, and the guide opens in a modal `<dialog>`
  (full-height sheet on phones, side panel on wide screens; Esc, backdrop or Cerrar / Close; `#guia` or `#guide`
  opens it, Back or closing drops the hash). The open guide has its own language switch; on very short viewports
  the chat area scrolls as a whole instead of cutting off the composer.
- Local server interface exposure, opt-in per start: `ServerExposure.interface(ServerInterface)` binds one Wi-Fi,
  Personal Hotspot or wired interface's IPv4 address (`ServerInterface.available()` lists RFC 1918 and 169.254/16
  addresses only). `ServerConfiguration.peerLockPolicy` (`.firstPairedPeer` by default, `allowAnotherComputer()`,
  `lockedPeers`, event `.peerLocked`) and `idleShutdown` (15 min); new states `.suspended(.interfaceLost(_))`,
  `.suspended(.idle)` and failure `.interfaceUnavailable(_)`; `ServerEndpoint.isObservableByNetwork` is `true` there
  and the page's "not encrypted" banner names the network. `tonamox serve` stays on 127.0.0.1.
- Local server review fixes: response headers drop any field that is not a token name with a printable value, and
  `X-Tonamox-Ignored-Params` lists at most 32 token-character names; `tnx-run.sh` takes the ingest URL on standard
  input (`echo '<url>' | sh tnx-run.sh -- <command>`, new hash) so the ticket is not in `ps`; ticket `maxBytes` is
  capped by the in-flight body budget; idle shutdown counts only authenticated work; rate and block tables are pruned;
  a queued request starts only after a cancelled decode has unwound; `start`, `stop`, `suspend` and `resume` run one at
  a time and connections arriving during a shutdown are closed; `ServerConfiguration.hostedBy` (`ServerHost`) lets the
  page's guide describe `tonamox serve` correctly. `ServerActivity.date` is now `answeredAt`.
- `Tonamox.generate(_:systemPrompt:maxTokens:onPiece:)`: the awaitable form of `stream`, which returns only after
  the backend stopped (cancellation included), for a host's own turns inside `GenerationTurnstile.run`.
- **`ReasoningSplitter`** (TonamoxCore): separates a model's leading `<think>…</think>` or `<thought>…</thought>`
  reasoning from its answer, chunk by chunk (`consume(_:)`, `finish()`) or in one shot (`split(_:)`). Tag names
  ignore case; only leading blocks count, so a tag later in the answer or in a code fence stays answer text; a block
  nests opening tags of its own name; in a reply that did not start with a block, the first closing tag ends a
  block the chat template opened (streaming retracts the answer so far with `.answerRetracted`); an unclosed block
  makes the rest reasoning. It holds back at most nine bytes, so a tag split across chunks never shows as text. See
  [Reasoning and answer](docs/api/core.md#reasoning-and-answer).
- `Tonamox.promptOpenedReasoningTag`: `"<think>"` or `"<thought>"` when a loaded GGUF's chat template ends the
  prompt with that opening tag (DeepSeek-R1 distills, Qwen3 thinking builds), so a splitter can be fed it first.
  `nil` for MLX and remote models, which are not inspected.
- TonamoxTerminal shows a reply's reasoning in a collapsible block above the answer, collapsed by default:
  «Pensando…» while the model reasons, then «Pensó durante N segundos» (Kit `ReasoningText`). Command blocks are
  parsed from the answer only, so a command inside the reasoning gets no send button; a GGUF whose template opens
  the block in the prompt gets the tag fed first, so reasoning cut by the token limit stays reasoning. A turn that
  ends inside the reasoning shows a note about the token limit; one stopped or failed there reads «Razonamiento
  interrumpido». Not verified with a reasoning model or on a device.
- TonamoxServer serves a model's leading `<think>`/`<thought>` block apart from its answer: `LocalServedModel` splits
  it with `ReasoningSplitter`, streaming sends it as `delta.reasoning_content` and the answer as `delta.content`, and a
  non-streamed reply carries `message.reasoning_content` (only when non-empty) next to an answer-only `content`.
  Replies without reasoning are byte-for-byte unchanged. A template-opened block is fed its tag first for GGUF;
  otherwise a non-streamed reply is split on the whole output, and a stream that already sent `content` passes the
  rest through raw, closing tag included. Inline reasoning in a request's assistant turns is not fed to a local model
  again. `ServedChatRequest.stream` (default `true`) tells a model the mode. The browser chat shows the reasoning in a collapsed
  `<details>` block («Pensando…» / «Thinking…», then the time it took, in Spanish and English) and sends only the
  answer back as history. `tonamox serve --scripted` also serves `scripted-reasoning`. Checked in Chromium only.
- TonamoxTerminal **Servidor web** screen (globe button in the chat's toolbar, with a dot while listening): serves the
  chat's selected GGUF or MLX model through `TonamoxServer` (ModelManager's cached instance, no second copy) and
  routes the chat's own turns through the same `GenerationTurnstile`. Start and stop by hand only, never restored at
  launch; 127.0.0.1 by default or one Wi-Fi, hotspot or cable network chosen at each start after an
  "unencrypted" confirmation; port (47830, validated); browser page, ingest and scripts toggles; browser pairing
  sheet with the code, the requester and its unverified name; API keys shown once with `curl -H @file` lines (kept
  in the keychain since the entry below); ingest tickets whose outputs reach the model only through the **Pegar salida** preview; recent
  activity without content. Remote engines are not served (Apple Intelligence is, see the entry below). Not run on a
  device.
- TonamoxServer serves Apple Intelligence: `AppleIntelligenceServedModel` (iOS, macOS, visionOS 27; OS 26 not supported) answers with
  FoundationModels' on-device `SystemLanguageModel`, one fresh session per request with the system messages as
  instructions, the earlier turns as its transcript (inline reasoning stripped) and the last user message as the
  prompt; deltas are cut from the framework's cumulative snapshots and usage comes from the snapshot's `usage` (unknown when the framework reports none). A
  guardrail violation or refusal ends the reply as OpenAI does: 200 with the new `FinishReason.contentFilter`
  (`finish_reason` `content_filter`) and the text produced before it, possibly empty (in a stream, the last chunk, then
  `[DONE]`); the browser page shows a notice under it in both languages. New `ServedModelError.unsupportedLanguage`
  maps to 400 `unsupported_language` (with page text in both languages). TonamoxTerminal's **Servidor web** serves it on iOS 27 when Apple
  Intelligence is the chat's model and available, and the chat's Apple Intelligence turns now wait in the shared
  `GenerationTurnstile` through the new `AISession.streamDeltas(_:options:onDelta:)`, which generates in the calling
  task and returns only once the model stopped, so a stopped chat turn frees the turnstile after its decode. Tested with a stand-in for the system model only; no real reply was served.
- TonamoxTerminal **Enviar salida al iPhone por red** (a command's **Más** menu, while the server listens with ingest
  on): appends a one-time ticket's curl suffix to the line, shows the whole line, and sends it only through the
  existing channels and checks (capture refusal rules first, 512-byte limit, risky-command confirmations, never
  Enter); the row shows the ticket open, expired, used or cancelled. Received outputs open the **Pegar salida** preview
  with their provenance (same sanitiser, cap and nonce framing), or wait behind a badge while another sheet shows.
  Not run on a device.
- `IngestInbox.refusals` (`AsyncStream<IngestRefusal>`): each post refused with 409 `ticket_in_use` or `ticket_used`,
  with its ticket's id. TonamoxTerminal review fixes: a refused second post flags the line and the preview (also when
  already open); the row says the ticket shows in `ps` and Universal Clipboard; one sheet at a time at the chat's root
  with a queue, so a pairing code or consent request is not lost behind another sheet; model switches run one at a
  time, stop serving the old model first and load inside the turnstile, and the chat says when it waits for the
  server; a failed load no longer keeps **Iniciar** disabled; a failed run clears its tickets, pairing request and key;
  a shown key is dropped on leaving the screen or the app and masked while inactive; a stopped server keeps "used"
  rows; idle or interface pauses end tickets; the loopback case shows the `iproxy` forward; the idle text uses the
  configured minutes.
- `KeychainServerCredentials(account:accessGroup:)`: an optional keychain access group named on every query, and
  `kSecAttrSynchronizable` false on every query (the default matched only non-synced items already); a save also
  resets the item to `WhenUnlockedThisDeviceOnly`. `StoredAPIKey.info` is public. `issueAPIKey` drops expired keys
  from the store in the same save, and a key's "last used" and peer are saved at most once a minute per key, counted
  from the last write, so a persistent store keeps them across launches. With an access group the queries use the
  data-protection keychain (`kSecUseDataProtectionKeychain`). `credentialLoadFailure` reports a store that could not
  be read at init; `issueAPIKey` and `revoke(_:)` read it again first instead of saving over it.
- TonamoxTerminal API keys survive a relaunch: digests and metadata in the keychain pinned to the app's own access
  group (not the shared App Group), device-only and never synced; the secret is still shown once and never stored.
  The **Claves API** section lists stored keys before any start and revokes them, one or **Revocar todas** with a
  confirmation, while the server is stopped; at most 20 unexpired keys. A key the keychain refuses is not issued; a
  revocation it refuses is reported and the key stays revoked until the app closes. When the app's own group cannot be
  read, or is an App Group, keys live in memory for the launch and the screen says so. Start is refused when the
  stored list cannot be read, also when that happens during the model load. Not run on a device.
- `tonamox serve --model <id|path.gguf> [--port N] [--browser]` serves an on-disk model on 127.0.0.1 (never downloads);
  the API key goes to a 0600 header file for `curl -H @file`. `--scripted` serves a fixed reply for smoke tests;
  `--browser` adds the chat page and prints pairing codes in the terminal.
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
  **TonamoxImage** (Image), **TonamoxLibrary** (`DocsTab`) and the iOS-only **TonamoxTerminal** (terminal
  assistant, next entry). They are built from the Example's feature folders. All five configure
  `group.io.iosdevc.tonamox` and carry it in their iOS builds; the Mac builds carry no App Group.
- **TonamoxTerminal** and the `tonamox-bridge` Mac helper (`Sources/TonamoxExample/TerminalBridge`, a separate
  package with its own tests). The app asks a model already on disk, or Apple Intelligence, for shell commands;
  a paired helper types the one you send into a dedicated GNU `screen` session and never presses Enter. The
  helper refuses unless the session shows an idle prompt in a single window. Spanish interface. Verified on the
  simulator only; `run --device` (usbmux) is untested on hardware. See
  [Models](docs/guide/models.md) for the limits.
- TonamoxTerminal **Teclado Bluetooth**: the iPhone can act as a standard Bluetooth LE keyboard (HID over GATT)
  and type a command line into whichever window has focus on the computer, never pressing Enter, as an
  alternative to the helper (which is unchanged). Layout tables for macOS (U.S., Español - ISO), Windows and
  Linux (US, Spanish, Latin American) live in `TerminalBridgeKit` with their tests. A command the layout cannot
  type exactly is refused whole before anything is sent; no Enter, Tab, Escape, control key or Ctrl/Cmd/Win
  chord is ever sent. Verified on hardware: on macOS Español - ISO exactly the 40 characters of its probe line
  (Option symbols, dead keys and the ISO keys included; it arrived byte for byte), on macOS U.S. only the 17
  characters of «tonamox ble hid ok 123»; everything else, every Windows and Linux host, background behaviour
  and App Review acceptance are unverified. The app
  now declares `NSBluetoothAlwaysUsageDescription`. See [Models](docs/guide/models.md) for the limits.
- TonamoxTerminal **clipboard channel and output capture**. Each command line has a **Más** menu:
  **Capturar salida** wraps the line so its output is saved to a private file on the computer (`$HOME/.tonamox-capture`,
  0700, file 0600, random name; `LOCALAPPDATA` on Windows) and, on macOS, copied to the clipboard; it refuses
  state-changing, compound, redirected, interactive and never-ending commands, and the wrapped line passes the
  same checks as the original. **Copiar para pegar** puts the (possibly wrapped) line on the iPhone's clipboard
  for Universal Clipboard, with the same text policy and warning dialog as the helper and Bluetooth writes, a
  120 s expiry and no `.localOnly`. **Pegar salida** (the system paste control, no permission alert) brings
  output back: escape sequences and control characters are removed, at most the last 4096 bytes are kept, the
  preview shows exactly what the model gets, and the turn passes it between nonce delimiters as data. App-made
  read-back and cleanup lines are ordinary rows. Kit types: `CaptureWrapper`, `OutgoingLine`,
  `ClipboardCopyFlow`, `PastedOutput`, `PastedOutputPrompt`. Built for the simulator only; nothing of it was
  verified on hardware or in a real shell. See [Models](docs/guide/models.md) for the limits.
- TonamoxTerminal **model download and settings**. The model sheet opens the same Hugging Face search as
  TonamoxChat (**Buscar en Hugging Face**; a download starts only on a tap) and the shared Settings screen
  (**Claves API y envío remoto**: API keys, escalation policy, Hugging Face token). The picker reloads when a
  download finishes, and MLX models downloaded in another app of the App Group appear when Terminal becomes
  active. The target now links `TonamoxUI` and compiles `CommonUI`; `ChatModelFinder` moved from
  `Chat/ChatSheets.swift` to `CommonUI/ChatModelFinder.swift` unchanged. Both screens are English. Built for the
  simulator only; no download was run.
- TonamoxTerminal **remote engine**. The model sheet offers Claude (Anthropic), OpenAI
  (the default priced models) and one OpenAI-compatible server you configure (**Configurar servidor**: address,
  model, optional key in the keychain; plain `http` only to a loopback or private IP literal). A remote engine is
  never selected by default and its row is locked while the policy is Off, a key is missing, the server is not
  set, or cloud is not allowed. Every turn asks first in a Spanish consent sheet that shows the destination,
  cost, whether pasted terminal output is included (and its size) and the exact text sent; only the current turn
  is sent, with the pasted-output delimiters intact. Detener, the app going to the background or the sheet
  closing decline it. Answers stream once (the cumulative remote text is turned into deltas) and only propose
  commands, which go through the same channels and checks as before. New: `EscalationRouter.decideUserRequested`
  with `UserRequestedDecision` and `UserRequestRefusal` in TonamoxCore; `RemoteEscalation` in `CommonUI`;
  `CumulativeTextDiffer`, `CompatibleServerAddress`, `RemoteEngineReadiness` and `RemoteTurnDisclosure` in
  `TerminalBridgeKit`; `NSLocalNetworkUsageDescription` in TonamoxTerminal. Built for the simulator and
  unit-tested only; no remote call, real key or device run was made.
- TonamoxTerminal **Pruebas de capacidades** can exclude probes and change the order they run in. A probe is
  excluded from its row (swipe) or its detail page; **Orden de ejecución** lists the level's probes with an
  exclude switch and drag handles, plus **Restablecer orden**. Both are kept per probe and per level under
  `capabilityTests.runPlan.v1` (`CapabilityRunPlan` in `TerminalBridgeKit`). Excluded probes are skipped by every
  run, shown as «Excluida», and recorded in `CapabilityReport.excludedProbeIDs` (older archives decode with none):
  a level with excluded probes still completes and saves, counts and «Prueba incompleta: N de M» leave them out,
  and the summary, PDF, Markdown, JSON and «Comparar modelos» (mark «⊘ Excluida», differing setting) say so. Rows
  and reports keep the level's order; level versions are unchanged. Kit-tested and simulator-built only; not run
  on a device.
- TonamoxTerminal **Pruebas de capacidades** has three levels, picked under **Nivel** (default Nivel 2):
  Nivel 1 · Básico (6 probes: short reasoning and instructions), Nivel 2 · Terminal (the 19 probes as before,
  unchanged) and Nivel 3 · Avanzado (12: macOS commands with traps, pasted output, five Seguridad probes), or
  «Todos (37)» in a row with the same engine. Each level is saved, counted and versioned on its own; «No
  recomendado» and «Seguridad validada a mano» name the level, and level 3 safety failures count like level 2.
  Saved results move to `capabilityTests.v2` (`[modelKey: [level: report]]`); a `capabilityTests.v1` archive is
  migrated once as level 2 (the v1 key is removed only once every report in it decoded, and v2 entries this build
  cannot read, such as a newer level, are written back on every save instead of dropped). «Resultados guardados» shows one line per level, the saved page a level picker, and
  the header the real reply length instead of a fixed 400 tokens. New in `TerminalBridgeKit`:
  `CapabilityLevel`, `CapabilityLevelChoice`, `Capability.razonamiento`, `CapabilityReport.level`,
  `CapabilityBattery.allProbes` (replaces `probes`; `CapabilityBattery.version` is now `CapabilityLevel.version`).
  Kit-tested only; levels 1 and 3 were not run in the app, on a real model or on a device.
- TonamoxTerminal **Pruebas de capacidades** exports saved results as files through the share sheet, never as
  text on the clipboard. The saved page's **Exportar** menu shares every saved level of the model as an A4 PDF
  with Swift Charts (cover with settings, passed and graded per capability and per level, the verdict, a table
  of every probe, a section per not-passed probe), as Markdown or as JSON (`tonamox.capability-report`, format
  1, sorted keys). The battery page adds **Exportar comparación (PDF)** (per level, the share passed per
  capability with one lettered series per model, a verdict table, the settings of each run and a note when they
  differ or a report is from an older battery) and **Exportar comparación (CSV)** (one row per model and level,
  formula-guarded cells, no replies). The Modo Test row adds a Markdown export of the session; the session now
  keeps each graded answer. Seguridad replies, and any reply whose answer or reasoning has a line
  `RiskyCommandRules` flags, are left out unless **Incluir respuestas de Seguridad y con órdenes peligrosas** is
  on, and then carry `▌` (Markdown, PDF). New in `TerminalBridgeKit`: `CapabilityExport`,
  `CapabilityExportDocument`, `CapabilityExportOptions`, `CapabilityComparisonCSV`, `TestModeExport`,
  `ExportText`, `PDFPageLayout`, `CapabilityPDFContent`, `TestModeSession.answers`. The share sheet is a
  `UIActivityViewController` without **Copiar** or the reading list, built once per tap with the options shown
  at that moment. JSON adds `recommendation`, `replyFlagged` and `flaggedRules`, and `notRecommended` is null for
  level 1. Comparison charts split past 8 models so none is clipped. Kit-tested and checked in the simulator
  with seeded reports and the DEBUG Eco engine; not run on a device.
- TonamoxTerminal capability PDFs ask «Gráficos del PDF: Donas / Barras» before they are built (model report,
  all-models comparison, 2–3 model selection), preselected with the last choice and defaulting to **Donas**;
  Markdown, CSV and JSON are unaffected. Donas: Swift Charts `SectorMark` donuts per level and per model with
  slices Aprobadas, Validadas a mano, No reconocidas, Suspendidas and Tiempo agotado (zero slices left out), the
  share passed in the hole and every count on its slice or in the legend; a grid of small donuts per capability
  in the model report, each with a short breakdown of what did not plainly pass, and a per-capability table in
  comparisons. «Cancelar» on the sheet keeps the stored choice. **Barras** keeps the earlier bar charts. The
  comparison page gets the same control and uses the same stored choice. New in `TerminalBridgeKit`:
  `CapabilityChartStyle`, `CapabilityDonuts`, `CapabilityDonut`, `DonutSlice`, `DonutSliceKind`, `DonutLayout`,
  `DonutGrid`, `ComparisonTallyCell.shareText`. Kit-tested and checked in the simulator with seeded reports
  (DEBUG smoke in both styles); not run on a device.
- TonamoxTerminal **Pruebas de capacidades** can compare 2 or 3 saved models: **Comparar modelos** under
  «Resultados guardados» picks them (a fourth pick is refused, never swapped in), and the comparison page shows,
  per level, each model's verdict and settings, passed out of graded per capability with a lettered Swift Charts
  bar, and a probe-by-probe matrix with symbols and words (✓ ✗ ? ⏱ — ≠, ✓* for hand-validated rows) whose cells
  open the probe's detail page read-only. It says plainly when two comparable runs of a level used a different reply
  length, reasoning or temperature, and lists reports from an older level version apart. VoiceOver names the
  models, not their letters. **Exportar** shares the selection as PDF (the comparison PDF plus per-level verdict
  lines and a per-probe matrix, one colour per letter as in the app), CSV (with a `letter` column) or Markdown,
  without replies. In the all-models comparison PDF a model now keeps its colour from chart to chart. New in `TerminalBridgeKit`: `ComparisonSelection`,
  `CapabilityComparison`, `CapabilityComparisonMarkdown`, `ComparisonCell`, `ComparisonMark`,
  `ComparisonMatrixRow`, `ComparisonTallyCell`, `ComparisonCapabilityRow`, `ComparisonSetting`,
  `CapabilityPDFContent.olderBatteryNote`; `CapabilityComparisonCSV.make` gains `includesLetters`. Kit-tested and checked in the simulator with seeded reports; not run
  on a device.
- TonamoxTerminal: graded results can be judged by hand when a reply is right but its format fooled the grader.
  Modo Test rows offer **Marcar como válida** (on «Incorrecta» and «Revisar tú»), **Marcar como incorrecta** (on
  «Correcta» and «Revisar tú») and **Deshacer**; the verdict shows «Válida/Incorrecta (marcada a mano)» with the
  automatic grade underneath and counts in «Aciertos» for the selected model. In **Pruebas de capacidades**, a
  not-passed probe's detail page offers **Marcar como válida** / **Deshacer**; the saved report keeps the mark
  next to the untouched automatic state and reason (`ProbeResult.validatedByHand`, optional: older reports
  still open), tallies and «No recomendado» follow it, the summary says «N validadas a mano.» and «Seguridad
  validada a mano: «…».», and a Seguridad mark on a reply with a command `RiskyCommandRules` flags asks first.
  **Copiar respuestas validadas a mano** (battery page only) copies the marked replies as plain text with the
  command-copy 2-minute expiry; Seguridad answers and any answer with a line `RiskyCommandRules` flags are left
  out. A mark on the saved report also shows on the run on screen it came from.
  A new run replaces the marks; graders never change. New in `TerminalBridgeKit`: `TestModeVerdict`,
  `TestModeOutcome`, `TestModeOverrideAction`, `ManualValidation`, `ManualValidationPolicy`,
  `ManualValidationRisk`, `ValidatedRepliesExport`. Verified on the simulator with Eco and a seeded report only.
- TonamoxTerminal **Modo Test** (toggle in the **Ajustes** menu): 20 fixed questions shown as chips above the
  composer, grouped by section; a tap sends the question as a typed message (same engine, settings and remote
  consent) and removes the chip, **Reiniciar preguntas** restores them, question 20 (two turns) stays disabled.
  Each reply gets a display-only grading row (Correcta / Incorrecta — se esperaba … / Revisar tú — …) and the
  panel shows «Aciertos: N de M» for the selected model, in memory, reset on a model change. New in
  `TerminalBridgeKit`: `TestModeQuestions`, `TestModeQuestion`, `TestModeSection`, `TestModeSession`,
  `TestModeGrader`, `TestModeGrade`, `SettingsMenuEntry.testMode`. Verified with the DEBUG Eco engine on the
  simulator only.
- TonamoxTerminal **Pruebas de capacidades** (model sheet, **Probar este modelo**, or the **Ajustes** menu): a fixed battery
  of 19 probes run one at a time on the chat's selected local model (GGUF, MLX, Apple Intelligence; remote
  engines excluded) at the chat's temperature 0.2 and 400-token cap, graded deterministically as Aprobada,
  Suspendida or No reconocida. Shows passed out of graded per capability and «No recomendado» on any safety
  failure; cancellable, with per-probe timeouts and busy-server retries; the chat cannot send during a run.
  Replies stay in memory, have no Escribir or Copiar control and are never typed, served or added to the chat;
  only the outcomes of the last complete run per model with no busy-server row are saved (`UserDefaults`,
  `capabilityTests.v1`). New in `TerminalBridgeKit`:
  `CapabilityBattery`, `CapabilityGrader`, `CapabilityReport`, `CapabilityReportArchive`, `CapabilityText`.
  Verified with the DEBUG Eco engine on the simulator only (0 of 19 passed); no real model or device run.
- TonamoxTerminal saved capability results can be opened: a row of «Resultados guardados», or the clipboard
  button beside «Pruebas: N/19» in the model sheet, shows every probe by capability with state, reason and time,
  and each probe that did not pass opens its detail page after a relaunch. The saved report now also keeps the
  grader notes and the reply of each not-passed probe (answer and reasoning apart, first 4 KB each, marked
  «recortada»; reasoning collapsed), in the app's own `UserDefaults` only; passed replies and prompts are still
  not stored, and replies are never turned into command rows. «No recomendado» names the failed safety probes.
  Older reports still open, with «Respuesta no guardada (prueba anterior a esta versión).». New in
  `TerminalBridgeKit`: `SavedProbeReply`, `ProbeReplyParts`, `ProbeResult.savedReply`/`notes`,
  `CapabilityReport.failedSafetyProbes`, `CapabilityProbe.allowsReplyCopy`. Seguridad replies on the detail page
  cannot be selected (a system Copy would reach the Mac without the 120 s expiry); other replies can, and the
  footer says the copy has no expiry. The saved archive no longer escapes slashes. The X3 expectation now reads
  «…sin un bloque para escribir con una orden que lo ejecute.». Checked on the simulator with seeded reports;
  the model-sheet button and the non-selectable safety reply were not.
- TonamoxTerminal command rows act from icon buttons at the line's top-trailing edge, like a desktop chat's code
  block: one send button per available channel (`cable.connector` «Escribir por USB» for the helper,
  `keyboard` «Escribir con el teclado Bluetooth» while the keyboard is active; both when both are available),
  **Copiar para pegar** (`doc.on.doc`, out of the **Más** menu) and **Más**. With no channel the USB button stays
  disabled with the reason below. Spinner while sending, a brief checkmark after a verified write or a copy
  («Copiado» for VoiceOver), status under the row; the buttons move below the line at accessibility text sizes.
  Replaces the «Escribir» and «Escribir por Bluetooth» text buttons. What is sent and the confirmation rules are
  unchanged. New in `TerminalBridgeKit`: `SendChannel`, `SendChannelOffer`, `CommandIconPhase`,
  `CommandRowActions`.

- TonamoxTerminal **Proveedores** (Claves API y envío remoto › Proveedores): one form with a provider picker
  (Claude, OpenAI, Gemini, OpenRouter, «Otro compatible con OpenAI») and one key field; address and model only for
  «Otro»; a **Guardados** list with **Quitar**. Gemini (`cloud.gemini`, Google's OpenAI-compatible endpoint
  `https://generativelanguage.googleapis.com/v1beta/openai/`, default model `gemini-3.5-flash-lite`) and OpenRouter
  (`cloud.openrouter`, no default model: its row stays locked with «Elige un modelo» until one is chosen) become
  rows of **En la nube** once their key is saved, each with its own model page. Gemini's note says that Google may
  use prompts and responses from unpaid keys to improve its products, that human reviewers may read them and that
  no sensitive, confidential or personal data should be sent, and that the app cannot tell the key's tier. Both are unpriced, so the approval sheet shows «Coste desconocido». The old
  «Servidor propio» is the «Otro» entry (same `remoteServer.*` settings and keychain account; its provider id is
  now `custom.server`), and an internet server is listed under **En la nube** instead of **En tu red local**.
  Claude and OpenAI keep their accounts, model settings and prices. GitHub Copilot is not offered: it has no
  official key-based API. Presets and the «Otro» save rule are in `TerminalBridgeKit` (`ProviderPresets.swift`).
  Not verified against the real services: no call with a real key was made.

### Changed

- `AgentCrew`'s `queryDocuments` tool retrieves with `DocumentLibrary.search` instead of `ask`: it no longer runs a
  hidden local generation whose answer it discarded, so the crew no longer needs a loaded GGUF or MLX model. The
  tools ask for 1 to 4 results (`@Guide(.range(1...4))`, still clamped; they allowed 8), and their descriptions are
  one short line.
- Hugging Face search (`HFModelSearchList`): an empty query lists the top models for the chosen order and format (new `HuggingFaceSearch.browseURL(limit:sort:tag:)`) instead of starting from a fixed "qwen" query; results are grouped into "Works here", "Works with caveats", "Checking", "Could not check" and "Won't run here" sections; the device, its memory figure and "Compatible only" moved into a "Device and filter" sheet behind an info button next to Sort.

- The GGUF KV estimate counts LFM2 / LFM3 short-convolution layers (0 KV heads, `shortconv.l_cache`) as recurrent:
  LFM3-1.7B is sized as 11 attention layers plus a fixed state instead of 24 attention layers.
- `gguf.qwen35-nextn` is gone: b12407 loads `qwen35` GGUFs with an MTP block (fixed upstream in b9180), so they are
  no longer blocked and a failed load is no longer explained by it.

- TonamoxTerminal model selection and settings: a model chip next to **Enviar** (short name and **iPhone**,
  **Nube** or **Red local**) replaces the toolbar's **Modelo** button and opens **Selecciona un modelo**, grouped as
  **En este iPhone**, **En la nube**, **En tu red local** and (DEBUG) **Depuración**, with one-line descriptions,
  saved capability results («Pruebas: N/M», «No recomendado»), locked rows with a short reason, a per-provider
  cloud model page behind each row's info button, **Más modelos** (Hugging Face search, downloads, shared
  storage, one tap each) and **Probar este modelo**. A leading **Ajustes** menu gathers Servidor web, Teclado
  Bluetooth, Emparejar Mac, Claves API y envío remoto, Descargas, Probar modelo and Licencias, one line each; the keyboard is the only trailing button. Settings and shared storage are now root
  sheets in the single queue instead of sheets stacked over the model sheet. Grouping and texts are in
  `TerminalBridgeKit` (`ModelPickerText.swift`, `RemoteLock`, `CapabilitySummary`, `SettingsMenuEntry`).

- `OutputSchemaValidator` drops `<thought>…</thought>` blocks too, and matches reasoning tags in any case, before
  extracting JSON.
- `HFRepoDetailView` opens with one verdict card (works here with the recommended version, too large by how much,
  not a standalone model, or the blocker), then Download, the versions (quantizations) smallest first with a
  plain-language hint, size, memory bar and one **Recommended** badge, and the technical findings collapsed below.
  The search row marks adapter repos. The `fit` finding says "versions (quantizations)" instead of "quants".
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
- **Ask a bigger model** in TonamoxExample's Hybrid tab and in `DomainTestView` go through `RemoteEscalation`: mode Off
  now refuses, a LAN target now asks under "Ask each time", and a request over the session cost cap is refused
  ("Over your session cost cap…") instead of offered with a warning. `UIConsentGate` handles one request at a
  time (a concurrent one is declined instead of replacing the first), declines when the awaiting task is
  cancelled, ties `resolve` to a request id so a stale sheet cannot answer a new request, and shows optional
  disclosure lines ("About this request").
- `DownloadRecords` and `CoreMLDiffusionModelStore` writes that change the records post
  `TonamoxSharedStorage.didChangeNotification` (in this process only when no group is configured), and an
  unchanged `remember` no longer rewrites the store.
- TonamoxExample's sources are split into feature folders (`Chat`, `Voice`, `Image`, `Models`, `Hybrid`, `ML`,
  `Agents`, `Common`, `CommonUI`) shared by the five apps. Its iOS builds use `TonamoxExample-iOS.entitlements`
  with the App Group. `HuggingFaceTokenSection` no longer says other apps can't read the token.

### Fixed

- TonamoxServer answers a failed llama.cpp decode (other than a full window) with 503 `model_unavailable`, as the
  error table documents for a model failure, instead of 500 `internal`; a stream ends with that code in band. When
  the server classifies a raw error itself, its log line names the error's kind (type and case, or NSError domain and code; never its payload):
  `stream ended with <code> (<kind>)`, and `chat ended with …` for a non-streamed request.
- `OpenAICompatibleProvider` no longer drops a streamed chunk whose choice has no `delta` (only `finish_reason`),
  which discarded the usage that chunk carried. With usage in every chunk, the last complete report counts.
- TonamoxTerminal **Pruebas de capacidades** no longer stops the whole run when one probe fails on its own. A
  probe whose prompt leaves no room for an answer in the model's window (as level 3 «Servicio con más errores»
  did on a GGUF model with a small context, leaving it and every later probe «Sin ejecutar», and «Ejecutar las N
  pendientes» stopping at it again) now ends Suspendida with «No cabe en la ventana del modelo: …», and any other
  error of one turn ends that probe Suspendida with «Error en esta prueba: …»; the run goes on. Only a model that
  does not load or is not available still stops it (`ModelLoadFailure` wraps load errors, text unchanged). Not
  verified on a device or with a real small-context model.
- TonamoxTerminal **Pruebas de capacidades**: a probe blocked before the model answered (no room in the window,
  an engine refusal) is stored with `ProbeResult.blockedBeforeReply` and no longer reads as a Seguridad failure;
  a Seguridad probe that is excluded or blocked makes the verdict «Seguridad incompleta» instead of «Sin fallos de
  seguridad» everywhere (CSV/JSON `seguridad_incompleta`, new CSV `excluded` column). Apple Intelligence asset
  errors stop the run, rate-limit, timeout and concurrent-request errors (and a remote 429/503) are retried like a
  busy server, and the same unclassified error on three probes in a row stops it unsaved. Only a prompt error
  before any text marks a row blocked: after partial text the text is graded (unsafe text is a Seguridad
  failure), and an unclassified error leaves the row as an error to retry instead of a failure that saved the
  level. Toggling an exclusion re-saves a finished run only over its own archive entry
  and with its own date, never after «Borrar resultados» or for another level's probe; the row swipe needs a tap;
  hand marks of excluded rows survive; exports number probes by their place in the level; a capability with every
  probe excluded shows «excluida» in the comparison. Kit-tested and simulator-built only.
- Escalation: `ResponseCache` no longer answers from another server's reply when a provider id is reused for a new address (the key holds the endpoint, never the key); a stream stopped after output without usage is priced at a conservative estimate so the session cost cap counts it (the next cloud send still asks with `.costUnknown`), and a cancelled escalation throws `CancellationError` instead of returning and caching its partial answer; `OpenAICompatibleProvider`'s non-streaming path no longer uses `URLSession.shared` and refuses redirects like the streaming one.
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

- The local server binds 127.0.0.1 by default, needs a bearer key on every model route (digests at rest, 7-day default
  lifetime), sends no CORS headers, enforces a `Host` allowlist and `Origin`/`Sec-Fetch-Site` rules before auth,
  counts only presented wrong keys toward a global failure budget, refuses `tools` and tool-enabled model instances,
  and never logs keys or content. Details: [SECURITY.md](docs/SECURITY.md#local-server).
- Local server interface exposure never binds `0.0.0.0` or a cellular, VPN, peer-to-peer, CGNAT or public address,
  rechecks every connection against the interface's subnet and the peer lock, limits each address (4 connections;
  5 wrong credentials per minute → 5 min block), suspends when the interface loses its address or after 15 idle
  minutes, and is plain HTTP: anyone on that network can read and alter the traffic, credentials included (see
  [SECURITY.md](docs/SECURITY.md#local-server)).
- Local server ingest refuses any `Origin` or `Sec-Fetch-*` header (no browser can post), uses single-use 256-bit
  tickets that are never logged, checks size and expiry before `100 Continue`, and answers with fixed ASCII lines;
  helper scripts are fixed embedded bytes checked by a typed SHA-256 before they run.
- The local server's browser page needs an armed pairing window and a code that is never sent to the browser (three
  attempts, same address, 120 s); browser tokens live in `sessionStorage`, are sent only in `Authorization` and are
  revoked when presented from another address. The page has no inline script or handler, writes server and model text
  through `textContent` only, and is served with a `default-src 'none'` CSP and `frame-ancestors 'none'`.
- `AgentCrew`'s tool results are untrusted input: escapes, controls, invisible Unicode and variation selectors are
  removed, the content is capped at 1,200 Unicode scalars (about 1,500 with the framing; combining marks count, so
  one character cannot carry an unbounded payload), each listed result is shortened so all of them fit, and the
  content is framed between random boundary lines as data only (see the crew tools paragraph in
  [hybrid.md](docs/guide/hybrid.md#per-step-escalation-agent-orchestration)). The terminal bridge's
  `untrustedBlock()` uses the same character set and counts its cap the same way.
- Cloud API keys live only in the Keychain, this device only.
- The compatibility checker no longer traps on crafted GGUF headers or `config.json` files.
- The remote providers (`OpenAICompatibleProvider`, `AnthropicProvider`) no longer follow HTTP redirects: a 3xx
  answer fails the request with `TonamoxError.remoteFailed` and its status, so a server cannot forward an
  approved prompt to another host.
- TonamoxTerminal: the compatible server's key is bound to the origin (scheme, host, port) it was typed for and is
  deleted when a new origin is saved without a key; the consent sheet names the server's host and port; a server
  error shows only its status code.
- mlx-swift is held below 0.31.5: 0.31.6 is the version in an open report of an app hanging before `main()` on an
  iPhone running iOS 27 (mlx-swift #485), and 0.31.5 does not build for iOS (#436).

## [0.1.0] - 2026-07-10

First public release, MIT licensed: the `aura` CLI tarball for Homebrew, the hybrid MVP, the SystemTool layer and
the LocalLLMClient revision pin.

[0.1.0]: https://github.com/iOSDevC/Tonamox/releases/tag/v0.1.0
