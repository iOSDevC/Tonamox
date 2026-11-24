---
layout: docs
title: Local server
parent: Guide
nav_order: 9.5
description: "TonamoxServer: an OpenAI-compatible API on 127.0.0.1 (or, opt-in, one Wi-Fi, hotspot or wired interface) for the on-device model an app or the tonamox CLI runs, plus an opt-in browser chat page with pairing, command-output ingest and helper scripts. Foreground only, credentials required."
---

# Local server (`TonamoxServer`)
{: .no_toc }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## What it is

`TonamoxServer` exposes an on-device model (GGUF or MLX loaded through `Tonamox`, or Apple Intelligence) through a small
OpenAI-compatible HTTP API, so tools on the same machine (curl, editors, scripts, the OpenAI SDKs) can use it.

This release (plan phases 1 to 4) is deliberately narrow:

- By default it listens on **127.0.0.1 only**. Nothing on the network can reach it. Over USB, a forwarder on the
  computer that binds 127.0.0.1 is the path (see [Host names](#host-names-and-usb-forwarders)); that path is not
  verified on a physical iPhone yet. An app can instead choose one interface for one start
  ([Network exposure](#network-exposure-wi-fi-hotspot-wired)); traffic there is **not encrypted**.
- It serves **on-device models only**: GGUF or MLX through `LocalServedModel`, and Apple Intelligence through
  `AppleIntelligenceServedModel` ([below](#apple-intelligence)). No remote provider, no egress: a request is answered
  on the device or refused.
- The [browser page](#browser-page-and-pairing), [output ingest](#output-ingest) and [helper scripts](#helper-scripts)
  exist and are off unless the app turns them on.
- It runs **in the foreground only** (see [Foreground rule](#foreground-rule)).

## Serving a model from an app

```swift
import TonamoxCore
import TonamoxServer

let llm = try await ModelManager.shared.load(.qwen3_1_7b)          // no tools
let turnstile = GenerationTurnstile()                               // share it with your own chat UI
let served = try LocalServedModel(llm, id: "qwen3-1.7b", displayName: "Qwen3 1.7B", turnstile: turnstile)

let server = TonamoxServer(configuration: ServerConfiguration(serverName: "My app"),
                           models: [served.served])
let endpoint = try await server.start()                             // http://127.0.0.1:47830
let key = try server.issueAPIKey(label: "editor")                   // key.secret is shown once
```

- `LocalServedModel` throws `ServedModelError.toolsNotAllowed` for an instance loaded with tools: a served prompt must
  never drive the app's own tools. Load a separate, tool-free instance for serving.
- The model sees the full message list with its roles (`system`, `user`, `assistant`).
- Run your own chat generations on the same model through `turnstile.run { … }` (or take it back with
  `server.turnstile(for:)`), so the app and the server never decode on one context at the same time. Inside the
  body use `llm.generate(_:systemPrompt:maxTokens:onPiece:)`, which returns only after the decode stopped: leaving a
  `stream` loop early ends the turn while the cancelled decode is still running.
- `server.state`, `server.clients` (keys without secrets) and `server.activity` (requests without content) are
  observable; `server.states()` and `server.events()` give a new `AsyncStream` per call for non-SwiftUI hosts.

### Apple Intelligence

```swift
if #available(iOS 27, macOS 27, visionOS 27, *) {
    let apple = try AppleIntelligenceServedModel(turnstile: turnstile)   // id "apple-intelligence"
    server.setModels([apple.served])
}
```

- `AppleIntelligenceServedModel` serves FoundationModels' `SystemLanguageModel.default`, which runs on the device
  (`egress: .onDevice`). It needs iOS 27, macOS 27 or visionOS 27; OS 26 is not supported. Its `init` throws `ServedModelError.notLoaded` when the model is not available right now
  (device not eligible, Apple Intelligence off, model not ready); a request that finds it unavailable later gets 503
  `model_unavailable`.
- Each request opens a fresh `LanguageModelSession`: the system messages, joined, become its instructions, the
  earlier user and assistant turns its transcript (inline `<think>` reasoning removed from assistant turns), and the
  last message, which must be a user message, the prompt (otherwise 400 `unsupported_parameter`, param `messages`).
  `max_tokens` becomes `maximumResponseTokens`; `temperature:` on the `init` (default `nil`, the model's own) applies
  to every request.
- The model does not reason: `reasoning_effort` and `enable_thinking` are ignored and no `reasoning_content` is sent.
- `contextLength` is `SystemLanguageModel.contextSize`, read once when the model is made.
- Usage comes from the framework's own counts (the stream snapshot's `usage`); when the framework reports no output
  tokens it stays unknown and is not estimated. `finish_reason` is `length` when that usage shows `max_tokens`
  reached, and `stop` otherwise, including when usage is unknown.
- Guardrail violations and refusals are not errors: as with OpenAI, the reply is a 200 with `finish_reason`
  `content_filter` and the text produced before it (empty when the model declined at once); a stream sends that
  `finish_reason` in its last chunk, then `[DONE]`. The browser page shows a short notice under such a reply.
- Failures map to the [error table](#errors): an unsupported language is 400 `unsupported_language`, a context overflow is 400 `context_length_exceeded`, rate
  limits, timeouts and concurrent requests are 429 `server_busy`, missing model assets are 503 `model_unavailable`.
- Share the app's `GenerationTurnstile`, so the app's own Apple Intelligence turns and served requests take turns.

## API keys

Every route needs `Authorization: Bearer <key>`. Keys are issued by the host app or the CLI, never through HTTP.

- Format: `tnx_` followed by 43 base64url characters (256 random bits).
- The server keeps only the SHA-256 digest. `IssuedAPIKey.secret` exists once, in the value `issueAPIKey` returns.
- Default lifetime 7 days (`lifetime:`), revocable with `revoke(_:)`. Scopes: `.chat`, `.models`.
- Stores: `InMemoryServerCredentials` (default, process lifetime) or `KeychainServerCredentials` (digests and metadata in
  a `WhenUnlockedThisDeviceOnly` keychain item, service `dev.tonamox.server`, never synced). An app that shares an App
  Group or keychain group with other apps passes its own group as `accessGroup:`: on iOS a query without one also
  matches items in every group the app can read, so a sibling app could plant a key list. With `accessGroup:` the
  queries also set `kSecUseDataProtectionKeychain`, so on macOS the item goes to the data-protection keychain (a
  signed app with that group in its entitlements); without it macOS uses the file-based keychain, where the access
  group and accessibility class are not enforced as on iOS.
- `issueAPIKey` saves before it returns the secret: if the store throws, no key is issued. It also drops expired keys
  from the store in that save. `revoke(_:)` removes the key from memory even when the store's write fails (logged
  only). "Last used" and the peer are saved at most once a minute per key, counted from the last write.
- If the store cannot be read when the server is created, `credentialLoadFailure` holds the error and `clients` is
  empty. `issueAPIKey` and `revoke(_:)` read the store again first; `issueAPIKey` throws while it still fails, so a
  save never replaces a list the server could not read.
- Give a key to curl through a header file, not on the command line: `curl -H @keyfile` reads
  `Authorization: Bearer tnx_…` from a 0600 file (curl 7.55+). A key in argv (`-H "…$(cat file)"`, a shell
  variable) is visible to every local user through `ps`. `IssuedAPIKey.headerLine` is that line.

## Routes

| Method | Path | Scope | Body |
|---|---|---|---|
| GET | `/v1/models` | `.models` | none |
| GET | `/v1/models/{id}` | `.models` | none |
| POST | `/v1/chat/completions` | `.chat` | JSON, at most 1 MiB |
| POST | `/i/{ticket}` | one-time ticket (feature `.ingest`) | any bytes, at most the ticket's `maxBytes` |
| GET | `/s/tnx-run.sh` | none (feature `.scripts`) | none |
| GET | `/`, `/app.js`, `/app.css` | none (feature `.browserPage`) | none |
| POST | `/pair` | none; own `Origin`, armed window (feature `.browserPage`) | JSON, at most 1 KiB |
| POST | `/pair/{id}` | the pending request id and the typed code, same address | JSON, at most 1 KiB |
| GET | `/api/session` | `.session` | none |
| POST | `/api/session/logout` | `.session` | `Content-Length: 0` |

Anything else, an unknown ticket and a route whose feature is off are 404 with one fixed body. A known path with another method (including `OPTIONS` and `HEAD`) is 405
with `Allow` and no CORS headers. There is no health, version or other unauthenticated route.

Each model in `/v1/models` carries a `tonamox` object: `egress` (`{"kind":"on_device"}` in this release) and
`context_length` when known.

## Browser page and pairing

With `configuration.features.insert(.browserPage)` and a `PairingPresenter`, `GET /` serves a chat page with a guide
to this server. The page is in Spanish and English (see [Page languages](#page-languages)).

```swift
final class PairingSheet: PairingPresenter {                      // @MainActor
    func present(_ request: PairingRequest) async { /* show request.displayCode, request.peer, Deny */ }
    func dismiss(_ id: PairingRequest.ID) { /* hide the sheet */ }
}

var configuration = ServerConfiguration(serverName: "Mi iPhone")
configuration.features.insert(.browserPage)
let server = TonamoxServer(configuration: configuration, models: [served.served], pairing: sheet)
server.openPairingWindow()                                        // 120 s, one browser
```

Pairing, step by step:

1. The person arms pairing on the device with `openPairingWindow()`. Outside an armed window `POST /pair` answers 403
   `pairing_closed` and nothing is shown, so another process cannot spam the device or hold the pending slot.
2. The page sends `POST /pair {"name": …}` with its own `Origin` (a request without `Origin` is refused). The server
   makes a 128-bit request id and an 8-character Crockford code (about 40 bits), valid 120 s, and calls
   `present(_:)`. The response holds only the id: **the code is never sent to the browser**. One request is pending
   at a time (409 `pairing_busy`); 3 requests per minute per address, 20 in all (429).
3. The person types the code shown on the device into the page: `POST /pair/{id} {"code": …}`, from the same address.
   Case, `-`, `I`/`L` (read as 1) and `O` (read as 0) do not matter. Three wrong codes, `denyPairing(_:)`, a claim
   from another address or expiry end the request; `denyPairing` also closes the window.
4. Success answers once with a browser token, its session (scopes `chat`, `models`, `session`, expiry) and the
   capability hello, and closes the window.

Browser tokens have the API-key format, are kept as digests in memory only, expire after 30 minutes without use or 8
hours in all, and are bound to the address that paired: a token presented from another address is revoked.
`pairedBrowsers` lists them (no secrets); `revoke(_:)` ends one, `disconnectAllSessions()` all; `stop()` ends them
and any pending pairing. The page keeps its token in `sessionStorage` and sends it only in `Authorization`, so no
cookie or other ambient credential exists for a cross-site page to ride on.

The capability hello (in the pairing answer and in `GET /api/session`) describes this instance only: server name,
features that are on, exposure (`loopback` or `interface`, with the interface's name, kind, address, peer lock and
idle limit), whether traffic is observable on a network (the page then shows its "not encrypted" banner), the models with their egress
class (`on_device`, `local_network` with host, `cloud` with provider and retention note), limits, who runs the server
(`"host": "app"` or `"cli"` from `ServerConfiguration.hostedBy`, with `foreground` and the API key delivery: shown once
on the device, or the header file `tonamox serve` writes), API key defaults,
and, when on, the ingest limits and the helper scripts with their hashes. No hello is sent before pairing; the page
files themselves hold no server data.

The page:

- chat with streamed answers (`fetch` + `ReadableStream` over `POST /v1/chat/completions`), a Stop button that aborts
  the request (the server cancels the generation), a model picker; the conversation lives only in the tab;
- a banner when the chosen model leaves the device, and a "not encrypted" banner when the page is not on
  `127.0.0.1`/`localhost` or the hello says traffic is observable;
- a guide built from the hello: where the server listens, the models and where they run, limits, how to connect an
  API client (`curl -H @file`, OpenAI base URL), the ingest suffix and script fetch lines when enabled, and what is set
  on the device. Nothing is configured from the browser;
- chat first: after pairing the transcript fills the screen between a compact top bar (server name, served model,
  language switch, **Guía** / **Guide**) and the composer, and only the transcript scrolls; on a viewport too short
  for the bars (phone in landscape, keyboard open) the chat area keeps a minimum height and scrolls as a whole, so the
  composer is never cut off. The guide opens over the
  chat in a modal `<dialog>` (a full-height sheet on phones, a side panel on wide screens) from the Guía / Guide
  button, or by opening the page as `/#guia` or `/#guide`; Esc, a click outside it (a text selection dragged out of
  it does not count), Cerrar / Close or Back from a `#guia` address closes it and returns focus to the button, and
  closing drops the hash from the address without a reload. The guide carries its own language switch, since the page
  behind it is inert while it is open. The guide exists only
  after pairing (it is built from the hello), so the pairing screen has no Guide button; a `#guia` link opened before
  pairing opens the guide once pairing succeeds. The page already needs JavaScript, so `<dialog>` has no fallback;
- a model's reasoning (`reasoning_content`) above its answer, in a native `<details>` block that starts collapsed.
  Its summary reads "Pensando…" / "Thinking…" while the reasoning streams, then "Pensó durante N segundos" /
  "Thought for N seconds" (singular for 1, "Pensó un momento" / "Thought for a moment" under a second), timed in the
  page from the first reasoning delta to the first answer delta or the end of the stream, and redrawn on a language
  switch. When the server's reasoning budget closed the block (`tonamox.reasoning.cut`), it reads "Razonamiento
  recortado tras N segundos" / "Reasoning cut after N seconds" ("Razonamiento recortado" / "Reasoning cut short"
  under a second). Expanded, the text is dimmer with a rule on the left. Opening or closing it while the reply streams sticks.
  Only the answer goes back to the server as the assistant turn. A server that sends `<think>` inside `content`
  instead is not parsed: the tags show as plain text in the answer and are sent back with it;
- two compact menus next to the model menu, each with a visually hidden label (the options carry the name): "Razonar" / "Reasoning" (no / bajo / medio / alto, sent as `reasoning_effort` `none`,
  `low` 256, `medium` 1024 or `high` 4096 tokens, the last capped by `maxReasoningBudget`; default medio) and
  "Longitud" / "Length" (512, 1024, 2048 or 4096 tokens, sent as `max_tokens`; only values up to the hello's
  `maxTokensCap` are offered, the cap itself when it is below 512; default the largest within `maxTokensDefault`).
  Both are kept only in this tab, like the language; a tab that stored the old checkbox's "off" starts at "no".
  The server refuses a prompt plus `max_tokens` over the model's context (`context_length_exceeded`) and lowers
  the reasoning budget to what is left, so «alto» with 4096 tokens on an 8192-token window reasons less;
- answers rendered from a safe Markdown subset, built from elements and text nodes only: paragraphs, **bold**,
  *italics*, inline code, fenced code blocks, bullet and numbered lists. A link shows as its text followed by the
  address in parentheses and is never clickable; HTML in an answer is shown as text. A LaTeX `\boxed{…}` shows its
  content in bold (code untouched). Under a finished answer a Copiar / Copy button copies it as shown: no `\boxed`
  wrappers, Markdown marks or escapes. On a page the browser does not count as secure (a LAN address over HTTP) the
  clipboard API is missing, so the button copies through a hidden, selected text field instead; if the browser
  refuses that too it reads "No se pudo copiar" / "Could not copy". A streamed answer is redrawn at most once a
  frame. The transcript sent back to the server keeps the answer as the model wrote it;
- when the device stops answering (app in the background), `GET /api/session` is retried after 1, 2, 4, 8, 15, then
  every 30 s;
- light and dark mode from `prefers-color-scheme`, only the embedded CSS.

### Page languages

Every text the page shows exists in Spanish and English, in one table in `app.js` (`STRINGS`, keyed by id with
`es` and `en`). The language is chosen in the browser, without asking the server:

- **Default:** the first entry of the browser's preferred languages (`navigator.languages`, else
  `navigator.language`) that is Spanish or English: `es` or `es-*` (`es-MX`, `es-419`) gives Spanish, `en` or `en-*`
  gives English, so `ca-ES, es-ES` opens in Spanish. No Spanish or English entry, or no language, gives English.
- **Switch:** **Español** / **English** in the page header, two buttons with `aria-pressed` (each name in its own
  language, `lang` set on each). Switching redraws the text in place: the transcript, a half-typed message, the
  pairing step and any request in flight stay as they are, nothing is fetched, and `<html lang>` and the title
  follow the choice.
- **Remembered:** the choice is kept in `sessionStorage` (`tonamox.lang`), the same per-tab store as the token: it
  survives a reload and is gone with the tab. No cookie or `localStorage` is used.
- **Not translated:** model output, the server name, model ids and the browser label are shown as the server sent
  them (an empty label, which the server stores as `browser`, reads "este navegador (sin nombre)" / "this browser
  (no name given)"). A cloud model's retention note is the integrator's own text: the page quotes it apart, after
  "Nota del proveedor…" / "Provider note…", with an unknown `lang`. Scope ids (`chat`, `models`, `session`) get page
  names. Every error code the server sends to the page (pairing, busy, consent, size, message limits, malformed
  request, scope…) has page text; only a code the page does not know shows the server's own API message, which is
  English, inside "El servidor respondió: …" / "The server replied: …".
- **Limits:** the page refuses to post past the hello's `maxMessages` and says so in the chosen language; an
  `invalid_messages` answer names both limits from the hello. Counts that need it use `Intl.PluralRules`
  ("1 intento" / "3 intentos"). The pairing window and request lifetimes are configurable and not in the hello, so
  the page text gives no number for them.
- **Screen readers:** a switch mutes the transcript (`aria-live`) and the unencrypted alert for half a second while
  their text is redrawn, then a hidden status line says "Idioma: español" / "Language: English".
- **Without JavaScript:** `index.html` holds a short bilingual fallback ("Conectando con el servidor…" and
  "Connecting to the server…", plus a `<noscript>` line), so the page is not blank if `app.js` never runs.
- **Host wording:** before pairing the page cannot know who runs the server (the hello is sent only after
  pairing), so it says "where the server runs: the phone app or the `tonamox serve --browser` terminal". After
  pairing it follows the hello's `host` (`app` reads "the phone", `cli` reads "this computer"). An `app` host that
  is a Mac app still reads "the phone".
- Times and numbers use the chosen language (`Intl` formatters built once per language); ports and code lines are
  never reformatted.

The server renders no HTML of its own (`/pair` and `/pair/{id}` answer JSON; `/i/*` answers plain text for curl), so
it reads no `Accept-Language`. The OpenAI-compatible API keeps its English messages.

Every model or server string reaches the page through `textContent`; the HTML has no inline script, style or event
handler and references only `/app.js` and `/app.css`; tests scan the three files for these rules. The HTML response
carries `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self';
img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, `X-Frame-Options: DENY` and
`Cross-Origin-Opener-Policy: same-origin`. A request with `Sec-Fetch-Site` other than `same-origin` or `none` (for
example a link from another site) is 403, the same rule as every route.

`tonamox serve --browser` serves the page on 127.0.0.1, prints each pairing code in the terminal and opens a new
window on Enter.

## OpenAI compatibility

- Honoured: `model` (exact id), `messages` (roles `system`, `user`, `assistant`; content as a string or `text` parts),
  `stream`, `stream_options.include_usage`, `max_completion_tokens` (preferred) or `max_tokens`, clamped to
  1…4096 (default 1024).
- Accepted and ignored, listed in the `X-Tonamox-Ignored-Params` response header (only names of RFC 9110 token characters, at most 64 bytes each, first
32 in sort order): `temperature`, `top_p`, `seed` and any
  other key the server does not handle. Sampling is fixed per loaded `Tonamox` instance.
- Refused with 400 `unsupported_parameter` (and `param`): `tools`, `tool_choice`, `functions`, `function_call`,
  `response_format` other than text, `logprobs`, `top_logprobs`, `logit_bias`, `n` other than 1, a non-empty `stop`,
  `audio`, `modalities` other than `["text"]`, `prediction`, image or audio parts, roles `tool`, `developer`,
  `function`. `null` counts as absent.
- Non-stream: a `chat.completion` object; `usage` only when the backend reported counts.
- Reasoning: a model's leading `<think>`/`<thought>` block is sent apart from the answer, as `reasoning_content`
  (`delta.reasoning_content` when streaming, `message.reasoning_content` otherwise, only when non-empty); `content`
  is the answer alone. Details and edge cases in the [API reference]({{ '/api/server' | relative_url }}#reasoning).
- Reasoning control: `reasoning_effort` (`none`, `minimal`, `low`, `medium`, `high`) and
  `chat_template_kwargs.enable_thinking`. Without either, a GGUF model reasons as its template sets and the
  reasoning is closed after 1024 tokens, on top of `max_tokens` for the answer; `none` or `enable_thinking: false`
  turn thinking off. A reply whose budget closed the reasoning carries `"tonamox": {"reasoning": {"cut": true,
  "tokens": N}}`. Mapping and errors in the [API reference]({{ '/api/server' | relative_url }}#reasoning-control).
- Stream: `text/event-stream`; a role chunk, content chunks, a finish chunk, a usage chunk (`choices: []`) only with
  `include_usage` and known usage, then `data: [DONE]`. While a request waits for its turn the server sends
  `: keep-alive` every 15 s. An error after the response head is one `data: {"error":{…}}` line and the connection
  closes without `[DONE]`.

Clients that worked in tests: Tonamox's own `OpenAICompatibleProvider` (streaming and not) and curl.

```bash
curl -sS -H @"$HOME/Library/Application Support/tonamox/server-key.header" \
     -H 'Content-Type: application/json' \
     -d '{"model":"scripted","messages":[{"role":"user","content":"hi"}]}' \
     http://127.0.0.1:47830/v1/chat/completions
```

OpenAI SDKs: base URL `http://127.0.0.1:47830/v1`, the key as the API key. Not tested with the official SDKs.

## Output ingest

With `configuration.features.insert(.ingest)` the app can ask a computer to send back a command's output. The app
makes a one-time ticket and types the command with a suffix; the computer's curl posts the output to the phone.

```swift
let ticket = try await server.ingest.makeTicket(label: "build")      // 10 min, 1 MiB by default
let line = "make test" + ticket.curlSuffix(on: endpoint)
// make test 2>&1 | curl -sS --data-binary @- http://127.0.0.1:47830/i/<43 characters>

for await output in server.ingest.outputs {                          // one consumer: the app
    let prompt = output.untrustedBlock().rendered                    // framed as untrusted data
}
```

- A ticket is 256 random bits, single use, valid for `ttl` (default 10 minutes), `maxBytes` up to 16 MiB or the
  in-flight body budget if smaller (8 MiB on iOS; default 1 MiB), at most 32 live. `label` is filtered to `[A-Za-z0-9 ._-]`, 40 characters. `cancel(_:)` ends one; `stop()`
  ends all; a suspension keeps them (their lifetime keeps running); a resume that loses its port ends them.
- The ticket is reserved when a post's head is accepted and consumed when the whole body arrived. A second post while
  the first is in progress gets 409 `ticket_in_use` (another process raced the ticket); a post after a delivered one
  gets 409 `ticket_used` (treat the delivered result as possibly forged). Both refusals are also yielded on
  `ingest.refusals` as `IngestRefusal(ticketID:reason:)`, so the app can flag that ticket. A body that does not
  complete releases the reservation, so running the same line again can still deliver.
- Refused before the body is read, leaving the ticket as it was: any `Origin` or `Sec-Fetch-*` header (403, so a web
  page cannot post), more than 30 posts per minute from one address (429; on loopback every local process shares one
  address), a malformed `X-Tonamox-Exit-Status` (400 `invalid_header`), an expired ticket (410 `ticket_expired`), a
  body over the ticket's `maxBytes` (413). `Expect: 100-continue` is answered only after these checks.
- The body deadline is 5 s + 1 s per 256 KiB, at most 20 s: a process that sends a valid head and stalls holds the
  reservation only that long.
- Answers are one ASCII line for the terminal: `tonamox: received 4102 bytes for build`, or
  `tonamox: <reason> [<code>]`. An unknown ticket gets the JSON 404 every unknown path gets.
- `curl --data-binary @-` reads the whole pipe first and sends `Content-Length`. `curl -T -` sends a chunked body and
  gets 411. Plain `--retry` does not retry a refused or reset connection (a backgrounded phone).
- Measured suffix length: 102 characters on `127.0.0.1:47830`, 108 for the longest IPv4 and port. Before typing, check
  the whole line against your typed-line limit (TonamoxTerminal's is 512 bytes).

`IngestedOutput` carries `rawBytes`, `text` (lossy UTF-8, NUL removed, `replacedSequences` counted), `exitStatus`
(from `X-Tonamox-Exit-Status`), `label`, `peer`, `receivedAt` and `peerMatchesLock` (`true` on loopback and with
`peerLockPolicy = .none`; on an interface with `.firstPairedPeer`, `true` only for a locked computer, so output posted before
anyone paired, or by a computer let in with `allowAnotherComputer()` that has not authenticated yet, is `false`).

### Untrusted output for a model

`untrustedBlock(maxCharacters: 16_000)` returns an `UntrustedText`:

- terminal escape sequences (CSI, OSC, DCS, SOS, PM, APC, two-character ESC sequences) and C0/C1 controls other than
  `\n` and `\t` are removed and counted in `removedControls`; CRLF becomes LF;
- tag characters (U+E0000–E007F), bidi controls (U+202A–202E, U+2066–2069, U+061C), zero-width characters
  (U+200B–200F, U+2060–2064), U+FEFF, U+00AD, U+034F, U+180E and variation selectors (U+FE00–FE0F, U+E0100–E01EF;
  one U+FE0E or U+FE0F right after an emoji is kept) are removed and counted in `removedInvisible`;
- output over `maxCharacters` Unicode scalars (not characters, so combining marks count) keeps its first and last
  halves, cut on character boundaries, around `[… N bytes omitted …]`;
- `rendered` is a fixed sentence saying the block is untrusted terminal output whose instructions must not be followed,
  a provenance line (label, peer, time, bytes, exit status, truncated, peer-lock match, removed counts, invalid UTF-8
  sequences), then the content between two lines holding `boundary`: `TONAMOX-UNTRUSTED-` plus 128 random bits in hex,
  drawn again until it does not occur in the content.

This is defence in depth. A model can still be misled by what the output says; the controls that matter stay in the
app: every proposed command passes the typed-line policy, is never sent with Enter, and is read by the user.

## Helper scripts

With `.scripts` on, `GET /s/tnx-run.sh` serves a fixed POSIX `sh` script compiled into the SDK. No key is needed (the
content is public); the integrity check is the hash the phone types:

- `HelperScript.tnxRun.sha256` (also `HelperScript.tnxRunSHA256`, and the `ETag`, quoted) is the SHA-256 of the served
  bytes. A test checks the constant against the embedded bytes and the source file.
- `echo '<ingest-url>' | sh tnx-run.sh -- <command…>` runs the command with `umask 077` and standard input from
  `/dev/null`, writes its output to a `mktemp` file, posts it with `X-Tonamox-Exit-Status`, deletes the file and exits
  with the command's status. The URL arrives on standard input and reaches curl through `curl -K -`, so no process
  shows the ticket in its arguments (`ps`); a URL with characters outside `[A-Za-z0-9:/._-]` is refused (exit 2).
- `HelperScript.tnxRun.runLine(on:ticket:command:verifier:)` builds the whole typed line:

```bash
f=$(mktemp) && curl -fsS http://127.0.0.1:47830/s/tnx-run.sh -o "$f" && echo '<sha256>  '"$f" | shasum -a 256 -c - && echo 'http://127.0.0.1:47830/i/<ticket>' | sh "$f" -- make test
```

  `verifier: .sha256sum` writes `sha256sum -c -` for Linux. `fetchAndVerifyLine(on:verifier:)` is the first half alone,
  for when the whole line would exceed the typed-line limit. The downloaded copy stays in the temporary folder (macOS
  `mktemp` without a template ignores `TMPDIR`).
- 10 fetches per minute per address (429); `Origin` and `Sec-Fetch-Site` follow the same rules as the API routes.

## Errors

`{"error":{"message","type","param","code"}}`; messages are fixed text, never request content. Ingest answers the same
codes as one line, `tonamox: <message> [<code>]`.

| HTTP | code | When |
|---|---|---|
| 400 | `invalid_json`, `invalid_messages`, `unsupported_parameter`, `context_length_exceeded`, `bad_request`, `invalid_header` | Body or head refused |
| 400 | `unsupported_language` | The model does not support the request's language |
| 401 | `invalid_api_key`, `expired_api_key` | Missing, unknown, revoked or expired key or browser token |
| 403 | `insufficient_scope`, `origin_not_allowed`, `cross_site`, `pairing_closed`, `invalid_pairing_code` | Scope, `Origin` or `Sec-Fetch-Site`; no armed pairing window; wrong code or claim from another address |
| 404 | `not_found`, `model_not_found` | Unknown path or model |
| 405 | `method_not_allowed` | Known path, other method |
| 409 | `ticket_in_use`, `ticket_used`, `pairing_busy` | Ingest ticket being posted, or already delivered; another pairing pending |
| 410 | `ticket_expired`, `pairing_expired` | Ingest ticket or pairing request past its lifetime |
| 413 / 415 | `request_too_large`, `unsupported_media_type` | Body over the route limit (checked before it is read); not `application/json` |
| 421 | `misdirected_request` | `Host` not in the allowlist |
| 429 | `rate_limited`, `server_busy` | 30 chats per minute per key; 30 ingest posts or 10 script fetches per minute per address; the model's queue is full or the 30 s queue wait ran out; failed-key flood. With `Retry-After` |
| 503 | `server_busy`, `app_backgrounded`, `model_unavailable`, `model_changed` | Request-body budget, suspension, model failure, model removed by `setModels` |
| 500 | `internal` | Anything else |

Malformed request heads get the parser's status (400, 411, 414, 417, 431, 501, 505).

## Host names and USB forwarders

On loopback `Host` must be exactly `127.0.0.1:<port>` or `localhost:<port>`; on an interface only
`<interface IPv4>:<port>`; or, on either, an entry of `extraHostNames` (exact `host:port`);
anything else is 421, which stops DNS rebinding. A forwarder that listens on another local port (for example
`iproxy -s 127.0.0.1 8000:47830`) needs `extraHostNames = ["127.0.0.1:8000"]`; one that listens on 47830 needs nothing.
A present `Origin` must be `http://` plus an allowed host; a present `Sec-Fetch-Site` must be `same-origin` or `none`.

## Network exposure (Wi-Fi, hotspot, wired)

```swift
guard let wifi = ServerInterface.available().first(where: { $0.kind == .wifi }) else { return }
var configuration = ServerConfiguration(serverName: "My app")
configuration.exposure = .interface(wifi)            // ask for this every time; never store it as a default
configuration.features = [.openAIAPI, .browserPage]
let server = TonamoxServer(configuration: configuration, models: [served.served], pairing: presenter)
let endpoint = try await server.start()              // http://192.168.1.5:47830, endpoint.isObservableByNetwork == true
```

- **What can be chosen.** `ServerInterface.available()` lists interfaces that are up with an RFC 1918 (10/8, 172.16/12,
  192.168/16) or link-local (169.254/16) IPv4 address. It never lists cellular (`pdp_ip*`), VPN and tunnels (`utun*`,
  `ipsec*`, `ppp*`, `gif*`, `stf*`, `tun*`, `tap*`), peer-to-peer (`awdl*`, `llw*`), loopback, CGNAT (100.64/10, as
  Tailscale-style VPNs use) or public addresses. `kind` is guessed from the name (`en0` Wi-Fi, `bridge*` Personal
  Hotspot, other `en*` wired); hotspot naming is not verified on a device. `ServerInterface` has no public init.
- **Binding.** The listener binds that interface's IPv4 address with `requiredLocalEndpoint`, never `0.0.0.0` and never
  by interface type alone (measured not to filter). `start()` and `resume()` re-read the interface list and fail with
  `ServerFailure.interfaceUnavailable(name)` when the interface no longer has the chosen address.
- **Who may connect.** Every connection is checked again: the peer must be on the interface's subnet (IPv6 and
  off-link peers are closed without an answer). With `peerLockPolicy = .firstPairedPeer` (default) the first computer that
  pairs or uses an API key becomes the only one admitted (`lockedPeers`, event `.peerLocked`); others are closed at
  accept. `allowAnotherComputer()` admits one more for `limits.pairingWindow` (120 s). `stop()` clears the lock.
- **Per-address limits** apply on an interface only (on loopback every client is 127.0.0.1): 4 connections per
  address, and 5 wrong credentials per minute from one address block it for 5 minutes (429, valid keys included).
- **Interface loss.** An `NWPathMonitor` re-reads the interface list on every path change. If the bound interface lost
  or changed its address, the server suspends with `.suspended(.interfaceLost(name))`; it never rebinds to a new
  address by itself. Call `resume()` when the address is back, or `stop()` and start again with a new choice.
- **Idle shutdown.** With no authenticated work for `idleShutdown` (15 minutes by default; `nil` turns it off) the
  server suspends with `.suspended(.idle)`. Authenticated work is a request with a valid key or browser token, a
  delivered ingest post or a completed pairing, plus any generation or body upload still running; unauthenticated
  page and script fetches do not count. Loopback never idles.
- **Not encrypted.** `endpoint.isObservableByNetwork` is `true`, the hello says `"observable": true` and the browser
  page shows a "Conexión sin cifrar" / "Unencrypted connection" banner naming the network. Show the same on the device for as long as it listens.
  What this does not protect is listed in [SECURITY.md](../SECURITY.md#local-server).
- Listening needs no Local Network permission on iOS (TN3179), so the app's explicit choice is the only gate; update
  `NSLocalNetworkUsageDescription` anyway. On macOS 27 a test process without Local Network access completed the TCP
  handshake on a LAN address but Network framework never handed the connection to the server; a host app may need
  that permission to actually serve on an interface (not checked on a device).

## Foreground rule

On iOS the server observes `BackgroundLifecycle`. When the app moves to the background the listener and every
connection close (a suspended app's socket would accept and never answer), running streams end with
`app_backgrounded`, and `state` becomes `.suspended(.appBackgrounded)`. Back in the foreground the server binds the
**same** port again; if another process took it, `state` becomes `.failed(.portInUse(port))` and every ingest ticket
ends. Keys and live tickets survive a suspension. On macOS and visionOS call `suspend(.appBackgrounded)` and `resume()` from `scenePhase`. `stop()` ends
everything and closes the port.

## Limits

| Limit | Default (`ServerLimits`) |
|---|---|
| Connections / still reading the head | 16 / 8 |
| Connections per address (interface only) | 4 |
| Idle shutdown (interface only) | 15 min without authenticated work |
| Head deadline | 5 s |
| Body deadline | 10 s + 1 s per 64 KiB, at most 60 s |
| Request bodies being read at once | 32 MiB on macOS, 8 MiB elsewhere |
| Write stall before a stream is dropped | 30 s |
| Chat body / messages / characters per message / JSON depth | 1 MiB / 256 / 200,000 / 16 |
| `max_tokens` default / cap | 1024 / 4096 |
| Reasoning budget default / cap | 1024 / 4096 tokens, on top of `max_tokens` |
| Generations running / queued / queue wait | 1 / 2 / 30 s per `GenerationTurnstile` |
| Chats per key | 30 per minute |
| Failed keys | 30 per minute across all clients, then 429 for unknown keys for 60 s; valid keys keep working. On an interface also 5 per minute per address, then that address gets 429 for 5 min |
| Ingest tickets | 10 min, 1 MiB default (16 MiB cap, or the in-flight body budget if smaller), 32 live; 30 posts per minute per address |
| Ingest body deadline | 5 s + 1 s per 256 KiB, at most 20 s |
| Script fetches | 10 per minute per address |
| Pairing | window 120 s, one pending request (TTL 120 s, 3 codes), 3 per minute per address, 20 per minute in all, body 1 KiB |
| Browser token | 30 min idle, 8 h in all, bound to the pairing address, memory only |

Only a presented, well-formed key that matches nothing (or has expired) counts as a failure; a missing header does not,
so a web page that fires requests at 127.0.0.1 cannot lock out the CLI or an editor.

A prompt is checked against the model's context before it runs, with an estimate of 3 UTF-8 bytes per token plus 4 per
message, when the model has a context length (`contextLength:` on `LocalServedModel`, else the loaded window
`Tonamox.contextWindow`, else `Model.maxContextLength`; `SystemLanguageModel.contextSize` for
`AppleIntelligenceServedModel`; read once when the served model is made). The prompt plus
`max_tokens` must fit, or the request is refused; the reasoning budget is then lowered to the rest, less 48 tokens for
the forced close. Without a context length the check is skipped and an MLX model may drop the oldest context silently.
The estimate can undercount numeric or multibyte text, and a GGUF reply that fills the window ends like a normal one.

## TonamoxTerminal

The Terminal example app (`Sources/TonamoxExample/TonamoxTerminal`, `WebServerController.swift` and
`WebServerView.swift`) is the first host app. Its **Servidor web** screen opens from the globe button next to the
connection dot; a dot on the button shows while the server listens, or will reopen after a trip to the background.

- **Model.** It serves the chat's selected on-device model (GGUF or MLX) as `LocalServedModel`, using ModelManager's
  cached tool-free instance with the chat's sampling, so no second copy of the weights is loaded. With Apple
  Intelligence selected it serves `AppleIntelligenceServedModel` (id `apple-intelligence`, the chat's temperature)
  on iOS 27 when the model is available on this iPhone; before iOS 27, or with the model unavailable, it refuses
  with the reason. The chat's own turns, Apple
  Intelligence's included, run through the same `GenerationTurnstile` (`Tonamox.generate`, or for Apple Intelligence
  `AISession.streamDeltas`, inside `run`; both return only once the decode stopped), so the phone and a web client
  never generate at once; a chat turn that finds the queue full says so in Spanish. Remote engines
  and the DEBUG echo engine are refused with a message pointing to **Modelo**. Changing the model while listening
  calls `setModels`; back from the background the instance (evicted with the others) is taken again.
- **Start.** Only **Iniciar** starts it, in this launch; nothing is saved, so the next launch starts stopped on
  127.0.0.1 with the default options. Port 47830 by default, 1024–65535. **Dónde escucha** offers "Solo este iPhone y
  cable USB (127.0.0.1)" or each `ServerInterface.available()` entry by name (Wi-Fi, punto de acceso personal, cable)
  with its address; choosing one shows that anyone on that network can read the conversation and what the peer lock
  does, and **Iniciar** asks again. States shown: stopped, starting (with the model's load progress), listening (the
  URL in large selectable text, plus an "unencrypted" warning on a network), suspended with its reason, failed with
  its reason (`portInUse` names the port).
- **Pantalla.** **Mantener la pantalla encendida mientras sirve** (on by default, saved across launches, shown in any
  state) keeps Auto-Lock off while the server starts or listens and the app is in front, so the screen does not lock
  by itself and background the app. Its footer says it uses more battery and that leaving the app or locking the
  iPhone still closes the port. It is released on **Detener**, on a failure, on a pause that needs **Detener**, when
  the app goes to the background and when the toggle goes off. It goes through TonamoxUI's
  `ScreenAwakeCoordinator`, which the Mac-helper connection and downloads also use, so none turns the screen off
  under another. Not yet verified on a device.
- **Features.** Toggles for the browser page, output ingest and scripts, off except the page; the OpenAI API is always
  on and needs a key.
- **Pairing.** **Emparejar un navegador** arms the 120 s window with a countdown. The request sheet (presented from
  the chat's root, so it appears over any screen of the app) shows the code as `XXXX-XXXX`, the requester's address,
  the page's name labelled as not verified, the request's countdown and **Rechazar**; swiping it away also refuses.
  Paired browsers are listed with when they paired and expire, and **Revocar**; **Permitir otro equipo** appears once
  the peer lock holds a computer.
- **API keys.** Created with a sanitised name (accents folded, ASCII letters, digits, space, `.`, `_`, `-`, 40
  characters). Only the digest and metadata are kept, through `KeychainServerCredentials` (account
  `terminal.apikeys`) pinned to the app's own keychain access group, read with the pairing store's probe
  (`PairingStore.ownAccessGroup`), so the four sibling apps in the App Group cannot read or plant the list; device-only,
  never synced, readable while unlocked. Keys survive a relaunch. If the group cannot be read the app falls back to
  memory for the launch and the section says so in orange. A key the keychain refuses is not issued (the SDK saves
  first) and the error is shown; a revocation it refuses is reported, the key no longer authenticates in this launch
  and is hidden from later loads, and the next successful write removes it, but it would come back after a relaunch
  before that. Start is refused while the stored list cannot be read (the first new key would overwrite it), both
  before the model loads and when the new server's own read fails (`credentialLoadFailure`); **Revocar todas** clears
  it. The probe refuses a default group that is an App Group (`OwnKeychainGroup.isOwn`), so a build signed without
  the application-identifier entitlement falls back to memory instead of the shared group; the chosen group is logged
  (subsystem `io.iosdevc.TonamoxTerminal`, category `pairing`). The stored metadata includes the address of the last
  computer that used each key, and the footer says so. At most 20 unexpired keys; expired ones are removed on the next issue. The section lists stored
  keys before any start and revokes them, one or all (with a confirmation), with the server stopped; creating a key
  needs a listening server. The secret is shown once with a copy
  button (the `Authorization` header line, two minutes on the pasteboard, Universal Clipboard allowed) and the lines
  `(umask 077; pbpaste > ~/.tonamox-key)`, `curl -sS -H @"$HOME/.tonamox-key" <base>/v1/models` and the OpenAI base
  URL. The list shows expiry and last use, with **Revocar**.
- **Ingest.** With ingest on, **Recibir una salida** makes a ticket and shows `<tu orden>` plus its `curlSuffix` as
  selectable text for you to type on the computer. While the server listens with ingest on, each proposed command's
  **Más** menu also offers **Enviar salida al iPhone por red**: the app makes a one-time ticket labelled
  `<reply>.<line> <program>` and shows **Se enviará:** with the whole line (command plus suffix) and its byte count.
  That line then goes through the same channels and checks as any other (helper, Bluetooth keyboard, **Copiar para
  pegar**; text policy, risky-command warnings and confirmations; never Enter). Before the ticket exists the command
  is checked with the capture's refusal rules (`cd`, `export`, assignments, compound lines, redirections, comments,
  open quotes, interactive or endless programs) and Windows is refused; after, a line over 512 bytes is refused with
  both sizes. Capture and network send are exclusive, and either can change only while no channel has sent the
  line. The row shows the ticket's state in Spanish: open with its expiry (and that the link shows in the computer's
  `ps` while the command runs and travels through Universal Clipboard if copied), expired, used (when the output
  arrived; flagged in orange when the server then refused another post with it) or cancelled because the server
  stopped; turning the option off cancels the ticket. A used ticket stays "used" after **Detener**. A pause for idle
  time or a lost interface ends the tickets in the app too, since only a background pause reopens the port. On
  **Solo este iPhone** the row and the server screen add the `iproxy -s 127.0.0.1 PORT:PORT` forward the computer
  needs, without which curl posts to the computer's own 127.0.0.1.
- **Received outputs.** Each output that arrives opens the same **Pegar salida** preview as the clipboard path: one
  mapping in the kit (`NetworkPaste`) sends the SDK's decoded `text` through `PastedOutput.sanitize` (same sanitiser
  and 4096-byte cap) and `PastedOutputPrompt` (same nonce-delimited prompt); the SDK's `untrustedBlock` is not used, so
  the model sees one framing. The preview adds **De dónde viene** (ticket name, sender address, bytes received, exit
  status when sent, invalid UTF-8 replaced, whether it was cut), a warning when `peerMatchesLock` is false, and a
  warning when the server refused another post with the same ticket (`ingest.refusals`; raised even after the
  preview opened); the command offered as context is the line that carried the ticket. Nothing goes to the model until **Enviar al
  modelo**. An output opens at once only when no sheet or confirmation is showing and nothing else waits; otherwise it
  waits behind an orange **N salidas recibidas: revisar** button above **Pegar salida** (also listed on the server
  screen with **Revisar** and **Descartar**), oldest first, at most 16 (past that the oldest is dropped and the badge
  says so). Waiting outputs stay in memory after **Detener**; every ticket ends.
- **Activity.** Paired browsers and keys counted, and the newest 20 of the server's content-free activity entries.
  The SDK does not expose open connections, so there is no live connection count.
- **Sheets.** The chat's root shows one sheet at a time (Kit `SheetQueue`): the browser pairing code first, then a
  consent request, the paste preview, and the sheets opened from the toolbar. The one on screen is never replaced; when
  it closes the next waiting one opens, so a pairing request or consent request arriving over another sheet is not
  lost.
- **Model switches.** Changing the model while listening stops serving the old one first, then loads the new one
  while holding the turnstile (so nothing decodes on the old model during the load); a newer change cancels and waits
  for the one in progress, and only the newest selection is served. The chat's own load also waits in the turnstile
  and says **Esperando: el servidor web está usando el modelo…** while a web request holds it. A load failure shows
  under the state and does not keep **Iniciar** disabled.
- **Lifecycle.** The SDK suspends on background and rebinds on return. A failed start or rebind clears the run's
  tickets, pairing request and shown key. Leaving the screen or the app going to the background drops a shown API
  key, and the key is masked while the app is not active (app-switcher snapshot); it cannot be selected as text. On
  `willTerminate` the app starts `stop()` in a task that usually does not run before the process exits; the system
  closes the sockets anyway, so termination is not a verified stop.
- Not verified: everything above on a device or in a running app (it was built for the simulator only): the
  screen itself, a browser pairing, a key used from a Mac, a Wi-Fi, hotspot or cable bind, background and return,
  `portInUse`, ingest from a real shell, a suffixed line typed over Bluetooth or the helper, and the chat and a web
  client waiting for each other, the single-sheet queue with real competing sheets, the "posted again" warning from a
  real second post.

## Known limits

- One request per connection, `Connection: close`, HTTP/1.1 only; no keep-alive, chunked request bodies, compression
  or HTTP/2.
- Traffic is plain HTTP: a process allowed to capture loopback traffic (root) can read it; any local process holding
  the key can use the model. On an interface anyone on that network can read and alter everything, keys included.
- Interface exposure is tested with injected interface lists and in-memory peers; a real Wi-Fi, hotspot or USB-Ethernet
  bind on an iPhone (H2-H4) has not been run. Any local process or page can fill the 16 connections (denial of service, no data).
- `tonamox serve` and the tests run only on macOS. iOS is built but its USB path (H1) is not verified.
- The page has not been checked by hand in Safari, Chrome or Firefox yet; its tests read the files and drive the
  routes, not a browser. On loopback every local process shares 127.0.0.1, so the token's address binding adds
  nothing there; pairing still needs the code shown on the device.
- A served stream does not pause the decode while the client reads slowly; the 4096-token cap bounds what is buffered.
- Apple Intelligence serving is tested with a stand-in for the system model only: no reply from
  `SystemLanguageModel` has been served yet (the Mac used reports the model not ready), and cancellation relies on the
  framework stopping when the iterating task is cancelled.
