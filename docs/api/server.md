---
layout: docs
title: TonamoxServer
parent: API Reference
nav_order: 6
description: "Public types of the TonamoxServer module: the server, its configuration and state, API keys, browser pairing and sessions, served models, the generation turnstile, output ingest and helper scripts."
---

# TonamoxServer
{: .no_toc }

Product `TonamoxServer` (depends on `TonamoxCore`). Usage and behaviour: [Local server guide]({{ '/guide/server' | relative_url }}).
Members are listed without the `public` keyword.

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## `TonamoxServer`

`@MainActor @Observable final class`.

| Member | Notes |
|---|---|
| `init(configuration: ServerConfiguration, models: [ServedModel], pairing: (any PairingPresenter)? = nil, credentials: any ServerCredentialStore = InMemoryServerCredentials())` | Loads existing keys from `credentials`; without `pairing`, `POST /pair` stays closed |
| `let configuration: ServerConfiguration` | |
| `private(set) var state: ServerState` | `.stopped` until `start()` |
| `internal(set) var clients: [ClientInfo]` | API keys, never their secrets (read-only outside the module) |
| `private(set) var activity: [ServerActivity]` | Last 100 answered requests, without content |
| `private(set) var servedModels: [ServedModelInfo]` | |
| `let ingest: IngestInbox` | Tickets and outputs for `POST /i/{ticket}`; answered only with `.ingest` in `features` |
| `internal(set) var pendingPairing: PairingRequest?` | The browser pairing waiting for its code |
| `internal(set) var pairedBrowsers: [BrowserSessionInfo]` | Paired browsers, never their tokens |
| `var isPairingWindowOpen: Bool` | |
| `internal(set) var lockedPeers: [String]` | Interface exposure with `.firstPairedPeer`: the computers allowed to connect; empty until the first pairing or key use, cleared by `stop()` |
| `func allowAnotherComputer()` | Interface exposure with `.firstPairedPeer`: one more computer may pair or use a key during `limits.pairingWindow`; no-op on loopback or before the first lock |
| `func openPairingWindow()` | Accepts one pairing for `limits.pairingWindow` (120 s); needs a presenter and `.browserPage` |
| `func denyPairing(_ id: PairingRequest.ID)` | Ends the pending request and closes the window |
| `func disconnectAllSessions()` | Ends every browser session; API keys stay |
| `func start() async throws -> ServerEndpoint` | Throws `ServerFailure` (`.portInUse`, `.alreadyRunning`, `.listener`, `.interfaceUnavailable`) |
| `func stop() async` | Closes the port and every connection, ends running generations, every ingest ticket, every browser session and the pending pairing |
| `func suspend(_ reason: SuspendReason) async` | For macOS/visionOS `scenePhase`; iOS does it on backgrounding |
| `func resume() async throws` | Rebinds the same port (and, on an interface, the same address) or fails with `.portInUse` or `.interfaceUnavailable` (both also end every ingest ticket) |
| `func setModels(_ models: [ServedModel])` | A running request on a removed id ends with `model_changed` |
| `func turnstile(for modelID: String) -> GenerationTurnstile?` | |
| `func issueAPIKey(label: String, scopes: ClientScopes = [.chat, .models], lifetime: Duration? = .seconds(7 * 86_400)) throws -> IssuedAPIKey` | Saves the digest through the credential store; after a failed initial read it reads the store again first and throws while that fails |
| `private(set) var credentialLoadFailure: (any Error)?` | Why the credential store could not be read at init; nil once a read succeeded (`clients` is empty meanwhile) |
| `func revoke(_ id: ClientInfo.ID)` | An API key, or a browser session by its `BrowserSessionInfo.id` |
| `func states() -> AsyncStream<ServerState>` | New stream per call, starts with the current state |
| `func events() -> AsyncStream<ServerEvent>` | New stream per call |

## Configuration

| Type | Members |
|---|---|
| `struct ServerConfiguration` | `exposure: ServerExposure = .loopback`, `port: PortChoice = .fixed(47830)`, `limits: ServerLimits`, `features: ServerFeatures = [.openAIAPI]`, `extraHostNames: [String]` (exact `host:port`), `peerLockPolicy: PeerLock = .firstPairedPeer` and `idleShutdown: Duration? = .seconds(900)` (both interface exposure only), `hostedBy: ServerHost = .app`, `serverName: String`; `init(serverName:)` |
| `enum ServerExposure` | `.loopback`, `.interface(ServerInterface)` (that interface's IPv4 only; observable on that network) |
| `struct ServerInterface` | `name`, `ipv4: String`, `prefixLength: Int`, `kind: InterfaceKind`, `id`; `static func available() -> [ServerInterface]` (RFC 1918 or 169.254/16 only; never cellular, VPN/tunnel, peer-to-peer, CGNAT, public or loopback); no public init |
| `enum InterfaceKind` | `.wifi`, `.personalHotspot`, `.wired`, `.other`; guessed from the interface name, not verified |
| `enum PeerLock` | `.none`, `.firstPairedPeer` |
| `enum ServerHost` | `.app` (keys shown once on the device, foreground only), `.commandLine` (`tonamox serve`: key in a 0600 header file); sent in the hello as `host` |
| `enum PortChoice` | `.fixed(UInt16)`, `.preferred(UInt16)` (falls back to an ephemeral port on the first start), `.ephemeral` |
| `struct ServerFeatures: OptionSet` | `.openAIAPI`, `.browserPage` (opt-in), `.ingest` (opt-in), `.scripts` (opt-in) |
| `struct ServerLimits` | Every limit in the guide's table; defaults are the documented ones |
| `struct ClientScopes: OptionSet` | `.chat`, `.models`, `.session` (browser tokens) |

## State and events

| Type | Members |
|---|---|
| `enum ServerState` | `.stopped`, `.starting`, `.listening(ServerEndpoint)`, `.suspended(SuspendReason)`, `.failed(ServerFailure)` |
| `enum SuspendReason` | `.appBackgrounded`, `.interfaceLost(String)`, `.idle` |
| `enum ServerFailure: Error` | `.portInUse(UInt16)`, `.alreadyRunning`, `.listener(String)`, `.interfaceUnavailable(String)` |
| `struct ServerEndpoint` | `host`, `port`, `exposure`, `baseURL`, `isObservableByNetwork` (`true` for `.interface`, `false` on loopback) |
| `enum ServerEvent` | `.stateChanged(ServerState)`, `.authFlood`, `.keyIssued(UUID)`, `.keyRevoked(UUID)`, `.pairingRequested(UUID)`, `.pairingEnded(UUID)`, `.browserPaired(UUID)`, `.browserSessionEnded(UUID)`, `.peerLocked(String)` |
| `struct ServerActivity` | `id`, `answeredAt: Date`, `route`, `status`, `clientLabel`, `modelID` |

## Keys

| Type | Members |
|---|---|
| `struct IssuedAPIKey` | `client: ClientInfo`, `secret: String` (only here), `headerLine` (`Authorization: Bearer …`); `description` hides the secret |
| `struct ClientInfo` | `id`, `label`, `scopes`, `createdAt`, `expiresAt`, `lastUsed`, `lastPeer` |
| `struct StoredAPIKey` | What a store keeps: `keyHash` (SHA-256) and the metadata above; `info` gives the `ClientInfo` |
| `protocol ServerCredentialStore: Sendable` | `loadKeys() throws -> [StoredAPIKey]`, `save(_:) throws` |
| `struct InMemoryServerCredentials` | Default |
| `struct KeychainServerCredentials` | `init(account: String = "server.apikeys", accessGroup: String? = nil)`; service `dev.tonamox.server`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (also reset on update), `kSecAttrSynchronizable` false on every query, `kSecAttrAccessGroup` and `kSecUseDataProtectionKeychain` on every query when `accessGroup` is set (on macOS without a group the file-based keychain applies, where the group and accessibility class do not hold as on iOS) |

## Browser pairing

| Type | Members |
|---|---|
| `protocol PairingPresenter: AnyObject` | `@MainActor`. `present(_ request: PairingRequest) async`, `dismiss(_ id: PairingRequest.ID)`; held strongly by the server |
| `struct PairingRequest` | `id: UUID`, `peer`, `untrustedLabel` (printable, at most 60 characters), `code` (8 Crockford characters), `displayCode` (`XXXX-XXXX`), `expiresAt: Date` |
| `struct BrowserSessionInfo` | `id`, `label`, `peer`, `pairedAt`, `expiresAt` (absolute; idle expiry comes first when unused) |

## Models

| Type | Members |
|---|---|
| `struct ServedModel` | Opaque; built only by SDK adapters. `info: ServedModelInfo` |
| `struct ServedModelInfo` | `id`, `ownedBy`, `contextLength: Int?`, `egress: ServedModelEgress` |
| `enum ServedModelEgress` | `.onDevice`, `.localNetwork(host:)`, `.cloud(providerName:retentionNote:)`; only `.onDevice` models exist in this release |
| `final class LocalServedModel` | `@MainActor`. `init(_ llm: Tonamox, id: String, displayName: String, turnstile: GenerationTurnstile, contextLength: Int? = nil) throws` (throws `.toolsNotAllowed` for a tool-enabled instance; `contextLength` defaults to `llm.contextWindow`, then `llm.model.maxContextLength`), `served: ServedModel`, `info`, `turnstile`, `displayName` |
| `final class AppleIntelligenceServedModel` | `@MainActor`. `init(id: String = defaultID, displayName: String = defaultDisplayName, turnstile: GenerationTurnstile, temperature: Double? = nil) throws` (iOS, macOS, visionOS 27; throws `.notLoaded` when `SystemLanguageModel.default` is not available), `defaultID` (`"apple-intelligence"`), `defaultDisplayName` (`"Apple Intelligence"`), `served: ServedModel`, `info` (`ownedBy` `"apple"`, `contextLength` from `SystemLanguageModel.contextSize`, `.onDevice`), `turnstile`, `displayName`. See [Apple Intelligence](../guide/server.md#apple-intelligence) |
| `final class GenerationTurnstile` | `@MainActor`. `init(maxQueued: Int = 2)`, `run(_:) async throws -> T` (throws `ServedModelError.busy` when the queue is full; the turn ends when the body returns, so the body must await its generation, not break out of a stream), `isBusy`, `queuedCount` |
| `struct ServedChatRequest` | `messages: [ServedMessage]`, `maxTokens`, `client: ClientIdentity`, `stream: Bool` (init default `true`; the server sets the client's choice), `reasoning: ReasoningOptions` (init default `.automatic`; the server decodes it, see [Reasoning control](#reasoning-control)) |
| `struct ServedMessage` | `role: ServedRole` (`.system`, `.user`, `.assistant`), `content` |
| `enum ServedChatEvent` | `.text(String)`, `.reasoning(String)`, `.reasoningCut(tokens: Int)` (the budget closed the block after `tokens` reasoning tokens; sent before `.finished`), `.finished(FinishReason, ServedUsage?)` |
| `enum FinishReason` | `.stop`, `.length`, `.contentFilter` (`"content_filter"`: the model's safety rules stopped the answer; the text before it is kept and the reply is still a 200) |
| `struct ServedUsage` | `promptTokens`, `completionTokens` |
| `enum ServedModelError: Error` | `.busy`, `.notLoaded`, `.interrupted(partial:)`, `.unsupported(String)`, `.toolsNotAllowed`, `.contextLengthExceeded(limit:)`, `.unsupportedLanguage` (400 `unsupported_language`) |
| `struct ClientIdentity` | `clientID`, `label`, `peer` |

### Reasoning

`LocalServedModel` passes the model's text through `ReasoningSplitter` (TonamoxCore, see
[Reasoning and answer]({{ '/api/core' | relative_url }}#reasoning-and-answer)): a leading `<think>`/`<thought>` block becomes
`.reasoning`, the rest `.text`. On `/v1/chat/completions`:

- **Stream:** reasoning goes in `choices[0].delta.reasoning_content`, the answer in `delta.content`, never both in one
  chunk. A client that ignores unknown fields sees only the answer.
- **Non-stream:** `message.content` is the answer only; `message.reasoning_content` holds the reasoning and is present
  only when it is non-empty, so a reply without reasoning has the same bytes as before.
- `usage` and `finish_reason` are unchanged. A reply cut by the token limit inside the reasoning has
  `finish_reason: "length"` and empty `content`.
- When the GGUF's chat template ends the prompt with the opening tag (`Tonamox.promptOpenedReasoningTag`), the server
  feeds that tag first, so the output is reasoning from its first token. MLX templates are not inspected.
- Otherwise a lone closing tag (a block the template opened) is handled per mode. Without streaming the whole output is
  split once, so the text before the tag is `reasoning_content`. A stream cannot take back `content` already sent: from
  there the raw output goes on as `content`, closing tag and whitespace included, so a client can still split it.
  `ServedChatRequest.stream` tells a model which mode it serves.
- An assistant turn in the request history loses an inline leading reasoning block, or the text before a lone closing
  tag, before it reaches a local model: reasoning a client sent back is not fed to the model again.

### Reasoning control

`POST /v1/chat/completions` reads two common client fields and maps them onto `ReasoningOptions` (TonamoxCore, see
[Reasoning control]({{ '/api/core' | relative_url }}#reasoning-control)):

| Request | Reasoning |
|---|---|
| neither field, or `reasoning_effort: null` | thinking as the template sets it, closed after `ServerLimits.defaultReasoningBudget` (1024) tokens |
| `reasoning_effort: "none"` | thinking off |
| `reasoning_effort: "minimal"` or `"low"` | budget 256 |
| `reasoning_effort: "medium"` | budget 1024 |
| `reasoning_effort: "high"` | budget 4096 |
| `chat_template_kwargs: {"enable_thinking": false}` | thinking off, whatever `reasoning_effort` says |
| `chat_template_kwargs: {"enable_thinking": true}` | the effort's budget, or the default one |

- Every budget is capped by `ServerLimits.maxReasoningBudget` (4096). The budget is on top of `max_tokens`, which
  stays the answer's limit: a reply may produce `max_tokens + budget + 1` completion tokens, and `usage` counts them
  all. `finish_reason` is `"length"` when the answer itself reached `max_tokens`, or when the reply used all
  `max_tokens + budget + 1` (a model that kept reopening its reasoning).
- Thinking off renders the GGUF's template with `enable_thinking = false` when that changes the prompt; either way
  any reasoning block the model still opens is closed at once (budget 0), with no `tonamox` member. Nothing is added
  to the user's message.
- When the budget closed the block, the non-stream body and the last stream chunk (the one with `finish_reason`)
  carry `"tonamox": {"reasoning": {"cut": true, "tokens": N}}`, `N` the reasoning tokens before the close. The
  member is absent otherwise, so other replies keep their bytes. The model is fed a sentence before the closing tag;
  `reasoning_content` does not carry it, only the line break before the tag.
- Refused with 400: a `reasoning_effort` that is not one of the five values (`invalid_reasoning_effort`), a
  `chat_template_kwargs` that is not an object or an `enable_thinking` that is not a boolean (`invalid_json`, with
  `param`), and `reasoning_effort: "none"` together with `enable_thinking: true` (`conflicting_reasoning`). Other
  `chat_template_kwargs` keys are ignored and listed in `X-Tonamox-Ignored-Params` as `chat_template_kwargs.<key>`.
- Applies to GGUF models. MLX models ignore it (TD-067). When the model has a context length, a budget that does not
  fit next to the prompt estimate and `max_tokens` (less 48 tokens for the forced close) is lowered to what fits,
  down to 0; only a prompt plus `max_tokens` over the window is refused (`context_length_exceeded`).

## Ingest

| Type | Members |
|---|---|
| `actor IngestInbox` | `makeTicket(label: String, maxBytes: Int? = nil, ttl: Duration = .seconds(600)) throws -> IngestTicket` (throws `IngestError`; `maxBytes` at most `min(limits.ingestMaxBytes, limits.inflightBodyBytes)`), `cancel(_ id: IngestTicket.ID)`, `nonisolated let outputs: AsyncStream<IngestedOutput>` (one consumer; the newest 64 are buffered), `nonisolated let refusals: AsyncStream<IngestRefusal>` (posts refused with 409 because the ticket was in use or used; one consumer, newest 64 buffered) |
| `struct IngestRefusal` | `ticketID: UUID`, `reason: Reason` (`.inUse`, `.used`); no secret |
| `struct IngestTicket` | `id: UUID`, `label`, `expiresAt: Date`, `maxBytes`; `url(on: ServerEndpoint) -> URL`, `curlSuffix(on: ServerEndpoint) -> String`; `description` hides the secret |
| `enum IngestError: Error` | `.tooManyTickets(limit:)`, `.invalidMaxBytes(limit:)`, `.invalidLifetime` |
| `struct IngestedOutput` | `ticketID`, `label`, `peer`, `receivedAt`, `rawBytes: Data`, `text` (lossy UTF-8, NUL removed), `replacedSequences`, `exitStatus: Int32?`, `peerMatchesLock`; `untrustedBlock(maxCharacters: Int = 16_000) -> UntrustedText` |
| `struct UntrustedText` | `boundary`, `rendered`, `removedInvisible`, `removedControls`, `omittedBytes` |

## Helper scripts

| Type | Members |
|---|---|
| `struct HelperScript` | `name`, `sha256` (hex), `id`; `static let tnxRun`, `static let tnxRunSHA256: String`, `static let all: [HelperScript]`; `url(on:) -> URL`, `fetchAndVerifyLine(on:verifier:) -> String`, `runLine(on:ticket:command:verifier:) -> String` |
| `enum HelperScript.Verifier` | `.shasum` (macOS, default), `.sha256sum` (Linux) |

The protocol models conform to, `ServedChatModel`, is `package`: an integrator cannot add a model type, so no one can
declare a remote provider as on-device and serve it without consent.
