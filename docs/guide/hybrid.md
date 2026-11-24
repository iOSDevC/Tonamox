---
layout: docs
title: Hybrid Inference
parent: Guide
nav_order: 2.5
description: "Local-first inference with optional, consent-gated escalation to a bigger local or cloud model — llama-server/Ollama/Magnitude, Anthropic, OpenAI, or Gemini — with token-saving compression and cost accounting."
---

# Hybrid Inference (local + remote)
{: .no_toc }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Overview

Tonamox is **on-device first**. The hybrid line adds an *optional*, **consent-gated**
path to escalate a request to a more powerful model — your own `llama-server`/Ollama box
on the LAN, or a cloud provider (Anthropic, OpenAI, Gemini) — only when the local
model isn't enough.

{: .note }
> Escalation through `routeAndEscalate` is **off by default** (`EscalationPolicy.off`):
> nothing leaves the device until you set a policy, and cloud sends go through your
> `ConsentGate` first. `escalate(to:)` is the low-level call. It checks neither a policy
> nor consent and sends immediately, so gate it yourself.
> `Tonamox.stream()` drives the **local** backends; escalation runs through
> `HybridEscalator` and an internal remote `InferenceBackend`, which shares the *same
> streaming contract* — so the pipeline is *mixed*, not cloud.

The design goal is to **cut the tokens sent to the remote**: stay local by default, and
when you do escalate, compress the context, optionally redact obvious secrets, and cache repeats.

## Token savings — the headline

| Technique | Effect |
|---|---|
| Local-first routing | Most turns never leave the device — **$0**, no tokens sent |
| Selective-context compression | Trims the context toward the remote's budget — **fewer tokens, input-dependent** (no fixed ratio; a context that already fits is passed through unchanged) |
| Response cache | A repeated request (same provider, model, messages and `maxTokens`) returns from memory — **$0** |
| PII redaction | Strips obvious secrets before the payload is sent: on `routeAndEscalate` per `EscalationPolicy.piiRedaction` (cloud targets by default), on `escalate(to:)` only with `redactPII: true` |
| Cost ledger | Per-escalation token + dollar accounting; an unpriced model counts as unknown, not $0 |

Every escalation returns what a receipt needs: `HybridEscalator.Result` carries `providerName`,
`usage` (input/output tokens), `compression` (`originalTokens`, `compressedTokens`, `factor`),
`redactedPIICount` and `fromCache`. The library prints nothing; the Example app's Hybrid tab
formats them as *"via llama-server (local) · &lt;model&gt; · 800 in / 240 out · compressed 6000→1500 (4.0×)"*.

## Detect local providers

Discover a running Ollama (`http://localhost:11434`), llama.cpp `llama-server`
(`http://127.0.0.1:8080/v1`) or Magnitude (`http://127.0.0.1:10100/inference/v1`) on **this
machine** and the models each one exposes. The probes are dependency-free `URLSession` calls that
run concurrently with a 2 s timeout and never throw (a server that is down is a normal result).
llama-server and Magnitude are read from `GET {base}/models`; the context length comes from
llama-server's `meta.n_ctx_train` or Magnitude's `context_length`, and neither reports a version.

```swift
import TonamoxCore

let providers = await LocalProviderDetector.detectAll()
for p in providers where p.isAvailable {
    print(p.kind, p.baseURL, p.models.map(\.name))
}
```

Nothing scans the network: `detectAll()`, `HybridEscalator.bestLocalTarget()` and
`routeAndEscalate` without `targets:` only find a server on the same machine, and on an iPhone
those addresses are the phone itself. For a server on another machine, probe its address, or build
its target with `AskTargetResolver.resolve` and pass it in `routeAndEscalate(targets:)`:

```swift
let mac = LocalProviderEndpoint(kind: .llamaServer, baseURL: URL(string: "http://192.168.1.20:8080/v1")!)
let statuses = await LocalProviderDetector.detectAll(endpoints: [mac])

let target = try AskTargetResolver.resolve(
    .local, model: "qwen3-32b", baseURL: "http://192.168.1.20:8080/v1",
    environment: ProcessInfo.processInfo.environment,
    readKey: KeychainStore.read(for:),
    localProviders: [])                           // ignored when baseURL is set
let result = try await HybridEscalator().routeAndEscalate(
    policy: EscalationPolicy(mode: .autoWithConsentMemory),   // a LAN target escalates without asking
    context: longContext, question: "What's the safest fix?",
    localAnswer: draftFromLocalModel,
    targets: [target])
```

Magnitude on another machine only answers once its Network access is turned on, and then wants
its key as `Authorization: Bearer`; a probe sends no key, so build that target directly:

```swift
let magnitude = OpenAICompatibleProvider(
    id: "lan.magnitude", displayName: "Magnitude (Mac Studio)",
    baseURL: URL(string: "http://192.168.1.30:10100/inference/v1")!,
    apiKey: magnitudeKey)
let target = RemoteTarget(provider: magnitude, modelID: "qwen3.5:4b", origin: .localNetwork(.magnitude))
```

{: .note }
> Magnitude is a separate desktop app, not part of Tonamox. Its update check sends hardware
> information, and `magnitude server setup` installs a self-updating background service. Tonamox
> only talks to the server you run.

Ollama also lists **cloud models** (`deepseek-v4-pro:cloud`, `gpt-oss:120b-cloud`) that it forwards
to `ollama.com`. They carry `remoteHost` and `runsLocally == false`. `bestLocalTarget()` and
`AskTargetResolver.resolve` without a `baseURL` skip them, so the target they pick never forwards
the prompt to Ollama's cloud. A `baseURL` is classified by its host only: a local URL serving a
`:cloud` model named with `model:` still counts as `.localNetwork`.

{: .note }
> On iOS, connecting to a model server on another machine of your network needs the user's Local
> Network permission. Add `NSLocalNetworkUsageDescription` to the app's Info.plist with the reason.
> The Example app uses "Connects to a model server on your local network, such as Ollama or
> llama-server on your Mac."

## Escalate a request

`HybridEscalator` compresses the context toward the remote's budget, checks the response
cache, streams the answer, and records cost. `routeAndEscalate` (and so `AgentCrew`) redacts obvious
secrets/PII per `EscalationPolicy.piiRedaction`: cloud targets by default (`.cloudOnly`), every target
with `.allTargets`, none with `.never`. `escalate(to:)` redacts only with `redactPII: true`.

```swift
import TonamoxCore

let escalator = HybridEscalator()

// Route by policy: stays local, or escalates / asks consent per the router's rules.
let result = try await escalator.routeAndEscalate(
    policy: EscalationPolicy(mode: .askEachTime, allowCloud: true),
    context: longContext,
    question: "What's the safest fix?",
    localAnswer: draftFromLocalModel,   // enables the low-confidence trigger
    consent: myConsentGate              // presents the payload + projected cost
) { partial in
    // cumulative tokens — same contract as Tonamox.stream()
}

if let result {
    print(result.answer)
    print(result.usage as Any, result.compression.factor, result.fromCache)
} // nil → the router kept it local; a declined offer (by default, any over the cap) throws TonamoxError.escalationDeclined
```

The router (`EscalationRouter`) is a pure decision function (rules R1–R7): it stays local
unless there's a size overflow or a low-confidence local answer (a sensitive domain only
raises the bar for the latter).

- Without a `localAnswer`, only size overflow can fire: the estimated prompt exceeds 90 % of
  `localContextWindow` (default 8192).
- With one, size is not checked. The answer counts as low-confidence when it is under 40
  characters, contains a refusal phrase (English such as "I can't" or "as an AI"; Spanish such
  as "no sé", "no puedo" or "como modelo de lenguaje" — the unaccented "no se" does not count),
  or, for the `.security` / `.medicine` domains, is under 120 characters.
- Cloud targets are always offered to your `ConsentGate`, never escalated silently; only a LAN
  target under `.autoWithConsentMemory` escalates without asking.
- `costCapUSDPerSession` is compared with what the session has already spent
  (`CostLedger.sessionCostUSD`) plus the projected cost of the current request: the estimated
  tokens of the payload it sends (system prompt plus the compressed, redacted user message) and
  `maxTokens`, at the ledger's price. Size overflow still reads the uncompressed prompt. Over the
  cap, the router offers with the reason `.costCapped`, the default
  `ConsentGate.requestConsent(target:preview:offer:)` declines it, and `routeAndEscalate` throws
  `TonamoxError.escalationDeclined` without sending anything. Implement that method to show the budget
  and let the user go over. A projection of $0, such as any LAN target,
  never trips the cap.
- When the cloud target has no price in the ledger, the router offers with the reason
  `.costUnknown` and the offer's `projectedCostUSD` is `nil`. A priced request under the cap gets the
  same reason while the session holds unpriced calls (`unpricedRecordCount > 0`), because the
  session's spend is then unknown.
- Only the first candidate is tried: a llama-server, Ollama or Magnitude on this machine if one is running,
  otherwise the first cloud key found (Anthropic, then OpenAI, then Gemini), or the first of the `targets:` you
  pass. An error from it, such as HTTP 429, is thrown to the caller; there is no fall-through to the
  next target.

### Consent sees the exact payload

`routeAndEscalate` builds the request once: it redacts per `policy.piiRedaction`, compresses the
context to `policy.keepRatio` of the target's context window minus `maxTokens`, and passes that
`EscalationPayload` to your gate as `offer.payload`, with `offer.projectedCostUSD` priced from it
(`payload.estimatedInputTokens` plus `maxTokens`). Approving sends exactly its messages and
`maxTokens`, with no second compression; when the same provider and model already answered an
identical payload this app session, that answer comes from `ResponseCache` and nothing is sent.
To ask consent in your own flow, do the same in two steps:

```swift
let escalator = HybridEscalator()
let payload = escalator.preparePayload(
    for: target, systemPrompt: system, context: longContext, question: prompt,
    keepRatio: policy.keepRatio, redactPII: policy.redactsPII(for: target))
// Show payload.messages and payload.redactedPIICount; on approval:
let result = try await escalator.escalate(payload, to: target)
```

`escalate(to:context:question:…)` is `preparePayload` with a fixed `keepRatio` of 0.5 followed by
`escalate(_:to:)`; it checks no policy, consent or cost cap.

### A send the user asked for

`routeAndEscalate` picks its own target and stays local unless a trigger fires, so it does not fit a
button such as "Ask a bigger model" or an engine the user chose. Decide those with
`EscalationRouter.decideUserRequested`, priced from the payload you will send:

```swift
let ledger = CostLedger.shared
let payload = HybridEscalator(ledger: ledger).preparePayload(
    for: target, systemPrompt: system, context: "", question: prompt,
    keepRatio: policy.keepRatio, redactPII: policy.redactsPII(for: target))
let decision = EscalationRouter.decideUserRequested(RoutingInput(
    policy: policy, hasCandidateTarget: true, candidateIsCloud: !target.isLocalNetwork,
    online: NetworkMonitor.shared.isOnline,
    projectedCostUSD: ledger.projectedCost(
        target: target, inputTokens: payload.estimatedInputTokens, maxOutput: payload.maxTokens),
    sessionSpentUSD: ledger.sessionCostUSD, unpricedRecordCount: ledger.unpricedRecordCount))
// .refuse(_): send nothing. .ask(reason:): show the payload and ask. .send: escalate(payload, to: target).
```

In order: mode Off refuses; a cloud target refuses without `allowCloud` (a target you picked yourself was
never filtered by `candidateTargets`) or without a network; a priced request that would cross
`costCapUSDPerSession` refuses (exactly at the cap is allowed; a $0 LAN request is never capped); an
unpriced cloud target, or a session with unpriced records, asks with `.costUnknown`; otherwise
"Ask each time" asks and "Auto (LAN)" asks for cloud and sends to the LAN. The Example apps wrap this,
the consent sheet and the send in `RemoteEscalation` (`Sources/TonamoxExample/CommonUI`).

## Cloud targets (BYOK)

`HybridEscalator.cloudTargets(allowCloud:)` builds cloud targets from Keychain keys:
`cloud.anthropic` (`AnthropicProvider`, default model `RemoteTarget.defaultAnthropicModel`,
`claude-sonnet-4-5`), `cloud.openai` (OpenAI, `RemoteTarget.defaultOpenAIModel`, `gpt-4o`) and `cloud.gemini`
(`RemoteTarget.gemini(apiKey:model:)`, `RemoteTarget.defaultGeminiModel`, `gemini-3.5-flash-lite`; pass
`geminiModel:` for another), in that order, each only when its key is stored.
Keys are stored in the Keychain, never in source, files, or logs. Save a key once (e.g. from a
settings screen): `try KeychainStore.save(key, for: "cloud.openai")`.
Works from iOS, macOS, and visionOS.

**Gemini** goes through Google's OpenAI-compatible endpoint
(`https://generativelanguage.googleapis.com/v1beta/openai/`, still beta) with the key as a Bearer token. It sends
no `temperature` (Google deprecated it on 2026-07-21), its context length is left unknown (the compressor then
budgets for 8192 tokens), and it has no built-in price, so the router offers it with `.costUnknown`. Its
`retentionNote` states the free tier's terms: Google may use prompts and responses to improve its products and
human reviewers may read them, and apps offered in the EEA, the UK or Switzerland may use only paid keys. When
Gemini reports usage in every streamed chunk, the last complete report counts, never a sum. An error event in the
stream (`data: {"error":{"code","message"}}`, as Gemini sends for quota and rate limits) fails the call with
`TonamoxError.remoteFailed`, so a partial answer is never cached. GitHub Copilot is not a
provider: it has no official OpenAI-compatible chat API (its SDK runs agent sessions only).

**Sharing keys between your apps.** On iOS (and visionOS), once `TonamoxSharedStorage.configure(appGroup:)` has
applied an App Group (see
[Sharing storage between apps]({{ '/guide/models' | relative_url }}#sharing-storage-between-apps-app-group)),
`KeychainStore` works in the group's keychain access group, so every app of the group reads the same cloud keys
and Hugging Face token:

- `save` writes to the group.
- At `configure`, the app's existing items (service `dev.auralocal.remote`) are copied into the group once, and the
  private copies stay for older builds. On a locked device the copy waits, and on iOS it is retried when the app
  returns to the foreground. The copy never runs again once it finished (a flag in `UserDefaults.standard`), so a
  key another app deleted is not copied back.
- `read` and `hasKey` look only in the group once that copy finished; until then they fall back to any access
  group the app has. A key cleared in one app is therefore gone in every app, even though another app's private
  copy still exists.
- `delete` removes every copy the app can reach: the group's and its own private ones, not another app's private
  copy.
- `hasKey` reads the item's attributes only, never its secret.

On macOS nothing changes. Items stay in the login keychain, which has no access groups, so another app or the
`tonamox` CLI reading an item an app created may make macOS ask for permission.

{: .note }
> GitHub retired GitHub Models on 2026-07-30. `OpenAICompatibleProvider.gitHubModels(apiKey:)` and
> the `cloudTargets` overload taking `gitHubModelsModel:` are `unavailable` (a compile error that
> names the replacements), and `cloudTargets` no longer reads the `cloud.github-models` Keychain
> account. A key already saved there stays until you delete it with
> `KeychainStore.delete(for: "cloud.github-models")` (the Example app's Hybrid settings offer a button).

## Pick one target (`AskTargetResolver`)

For a one-shot ask, `AskTargetResolver.resolve` turns a provider choice into a single
`RemoteTarget`. It is what `tonamox ask` uses, and a pure function: you pass the environment, a
Keychain reader and the detected local providers, so it does no I/O of its own.

```swift
import TonamoxCore

let target = try AskTargetResolver.resolve(
    .auto,                                        // .auto / .local / .openAI / .anthropic / .gemini
    environment: ProcessInfo.processInfo.environment,
    readKey: KeychainStore.read(for:),            // read only for .openAI / .anthropic / .gemini
    localProviders: await LocalProviderDetector.detectAll())
let result = try await HybridEscalator().escalate(
    to: target, context: "", question: prompt, redactPII: !target.isLocalNetwork)
```

Without a `baseURL:`, `.auto` and `.local` return your llama-server, else Ollama, else Magnitude,
and never a cloud target; they throw `AskTargetResolver.Failure.noLocalProvider` when none runs.
`.openAI` / `.anthropic` take the key from `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`, else the Keychain; `.gemini`
from `GOOGLE_API_KEY`, else `GEMINI_API_KEY`, else the Keychain `cloud.gemini`. Each throws `.missingAPIKey`
without one. `baseURL:` (with `model:`) targets any OpenAI-compatible server;
a loopback or private-network host gets the origin `.localNetwork(.llamaServer)`, any other
host `.cloud`. Each `Failure` has an `errorDescription` that says what to do next.

## Per-step escalation (agent orchestration)

Escalation isn't only for the top-level answer. In `AgentCrew`, the Architect step's local
draft goes through `routeAndEscalate(localAnswer:)` and escalates only when it looks weak;
the Extractor, Reviewer and Reporter steps always stay local. It reuses the same compression,
consent, and cost machinery, and redacts per the policy's `piiRedaction` (cloud targets by
default). Fail-closed: any error or a *stay-local* decision keeps the local draft. It passes no
`targets:`, so it escalates only to a llama-server, Ollama or Magnitude on the same machine, or to a cloud key.

The reusable pipeline lives in the **`TonamoxAgents`** module (requires iOS 27 / macOS 27 / visionOS 27 and
the Xcode 27 SDK):

```swift
import TonamoxAgents

let crew = AgentCrew(store: .shared, library: .shared)
// Inject the escalation policy + consent gate; the Architect step escalates when weak.
await crew.run(topic: "Q3 security posture", policy: policy, consent: myConsentGate)
```

The agents call three read-only FoundationModels tools: `queryDocuments` (the Extractor and Reviewer),
`readAgentMemory` (this run's earlier outputs) and `recallPastTasks` (turns of earlier `AgentCrew:` runs).
`queryDocuments` uses `DocumentLibrary.search(_:topK:)`, so it needs the library opened and configured with an
embedding provider but no loaded GGUF or MLX model: Apple Intelligence is the only model in memory. A tool asks for
1 to 4 results and the count is clamped to that range. A tool's content is capped at 1,200 Unicode scalars (about
1,500 with the framing): each listed result, with its document title or task topic cut to 60, gets an equal share so
all of them show, and anything still longer is cut in the middle. The content is framed as untrusted data (escapes,
invisible characters and variation selectors removed, random boundary lines). Each crew step gets a fixed tool set
(`CrewToolbox`).

## Privacy & cost

- **BYOK keys** live only in the Keychain (`WhenUnlockedThisDeviceOnly`), never synced to iCloud. With an App
  Group configured on iOS, the apps of the group share them (see [Cloud targets](#cloud-targets-byok)).
- Your **`ConsentGate`** is called before an offered escalation with the `target` (including
  `target.provider.retentionNote`), the `preview` (`CompressionResult`) and an `EscalationOffer`:
  the router's `reason`, `projectedCostUSD` (`nil` when the model is unpriced), `sessionSpentUSD`,
  `unpricedRecordCount`, `costCapUSD` and `payload`, the exact request: `systemPrompt`,
  `userMessage`, `maxTokens`, `redactionEnabled` and `redactedPIICount`. `preview` is
  `payload.compression`, whose `keptText` is the context as sent. A gate must implement
  `requestConsent(target:preview:projectedCostUSD:)`. `routeAndEscalate` calls
  `requestConsent(target:preview:offer:)`, whose default declines `.costCapped` and passes any other
  offer to the first; only a gate that implements the offer method sees the question and system
  prompt. Tonamox ships no consent UI; the Example app's `UIConsentGate` (Hybrid settings)
  implements both and shows the exact payload with its redaction count, "Cost unknown" for `nil`,
  the session spend against the cap, and a warning when sending goes over it.
- **`PIIRedactor`** strips obvious secrets/PII (code-safe, high-precision patterns) from the
  context and the question before compression, so the sentence split cannot break an email apart.
  `routeAndEscalate` runs it per `policy.piiRedaction`, `escalate(to:)` with `redactPII: true`.
  The system prompt is never redacted.
- **`CostLedger`** records per-escalation token usage and cost. Local-network targets cost exactly
  $0. Built-in prices cover only the default cloud models, `claude-sonnet-4-5` on `cloud.anthropic`
  ($3 in / $15 out per 1M tokens) and `gpt-4o` on `cloud.openai` ($2.50 / $10), as approximate list
  prices. Every other cloud model (another Anthropic or OpenAI model, every Gemini model, any custom
  `OpenAICompatibleProvider`, a public `AskTargetResolver` base URL, whose provider id is
  `custom.<host>` or `custom.<host>:<port>`) is unpriced: its record has `costUSD == nil`, as does
  any cloud call whose provider reports no usage, or only one of the two token counts. A call that
  throws after it streamed text or reasoning (a cancel, a dropped stream) is still recorded, with the
  usage the provider reported before failing; without one it is recorded at a conservative estimate
  (`estimatedUsage`: the payload's estimated input plus `maxTokens`, `isEstimated == true`), priced
  when the target is, so the cost cap counts it; the router still treats it like an unpriced record
  (the next cloud send asks with `.costUnknown`). A call that fails before any output is not recorded.
  `sessionCostUSD` sums the priced records since the session started, `unpricedRecordCount` counts
  the others and `sessionRecordCount` counts both; `startNewSession()` restarts them and keeps
  `records`. The Example app's Hybrid settings show these totals and a **Start new session** button.
- **`ResponseCache`** avoids paying twice for a repeated request. `HybridEscalator` keys it on
  the provider's `cacheIdentity` (for `OpenAICompatibleProvider` and `AnthropicProvider`, the id plus
  the base URL's scheme, host, port and path, never the key), model id, the whole payload: the system
  prompt, the user message (context + question) and `maxTokens`, and a non-default `temperature`.
  Pass `temperature:` to `escalate` or `routeAndEscalate` to sample at other than 0.7. It is held in memory (64 entries, FIFO, cleared on relaunch). An empty
  or whitespace-only answer, such as a reasoning model's that spent `maxTokens` thinking, is not
  cached, so the same request is sent again.

Set prices on the ledger your `HybridEscalator` uses (`HybridEscalator(ledger:)`, `.shared` by
default), in USD per 1M tokens. A model-specific price wins over a provider-wide one:

```swift
import TonamoxCore

let ledger = CostLedger.shared
ledger.setPrice(TokenPrice(inputUSDPerMillion: 1, outputUSDPerMillion: 4),
                provider: "cloud.openai", model: "my-openai-model")
ledger.setPrice(TokenPrice(inputUSDPerMillion: 0.5, outputUSDPerMillion: 1.5),
                provider: "my-gateway")                  // every model of that provider
ledger.setPrice(nil, provider: "my-gateway")             // back to unpriced

let price = ledger.price(provider: "cloud.openai", model: "my-openai-model")
let escalator = HybridEscalator(ledger: ledger)
```

## What's included

| Area | Type(s) |
|---|---|
| Discovery | `LocalProviderDetector`, `LocalProviderStatus` |
| Providers | `RemoteLLMProvider`, `OpenAICompatibleProvider` (llama-server / Ollama / Magnitude / OpenAI / Gemini), `AnthropicProvider` |
| Transport | internal (`RemoteBackend` adapts a `RemoteLLMProvider` to `InferenceBackend`; not public API) |
| Routing | `EscalationRouter` (R1–R7), `EscalationPolicy`, `RoutingDecision`, `HybridEscalator`, `AskTargetResolver` |
| Compression | `ContextCompressor` + pluggable `SelfInfoScorer` |
| Privacy & cost | `ConsentGate`, `KeychainStore`, `PIIRedactor`, `CostLedger`, `ResponseCache`, `NetworkMonitor` |

See also the [CLI]({{ '/guide/cli' | relative_url }}): `tonamox ask` resolves its target with
`AskTargetResolver` and sends it through `HybridEscalator.escalate(to:)`.
