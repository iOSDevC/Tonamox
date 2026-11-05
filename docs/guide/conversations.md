---
layout: docs
title: Conversations & History
parent: Guide
nav_order: 5
description: "Persistent multi-turn chat history with ConversationStore, context window management, auto-title, and summarization."
---

# Conversations & History
{: .no_toc }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## ConversationStore

`ConversationStore` is an actor-backed SQLite store (no external dependencies). All reads and writes are serialized automatically — safe to call from any task.

```swift
import TonamoxCore

let store = ConversationStore.shared

// Create a conversation
let conv = try await store.createConversation(
    model: .qwen3_1_7b,
    title: "Finance assistant"
)

// List all conversations
let conversations = try await store.allConversations()

// Full-text search: turns containing any of the words, best match first
let results = try await store.search("VAT Mexico")

// Delete
try await store.deleteConversation(id: conv.id)
```

### Where the history is stored

`ConversationStore.shared`, like any `ConversationStore(directory: nil)`, keeps its database at
`<Application Support>/AuraLocal/conversations.sqlite`. `ConversationStore(directory:)` takes another folder. Every
call opens the database when needed, so `open()` is optional.

With `TonamoxSharedStorage.configure(appGroup:)` (see
[Sharing storage between apps]({{ '/guide/models' | relative_url }}#sharing-storage-between-apps-app-group)), the
default store lives in the App Group's container on iOS (and in a sandboxed Mac app entitled to the group), and
every app of the group sees one history:

- **Existing history is copied, not moved.** Before the shared file is first opened in a process, the app's
  private `conversations.sqlite` is snapshotted read-only, WAL included. If the group has no store yet, the
  snapshot becomes it. Otherwise its conversations and turns are added with `INSERT OR IGNORE`, so rows the group
  already has stay as they are, and the added turns become searchable. A
  `conversations.sqlite.merged-into-group` marker next to the private file stops any later merge, so a
  conversation deleted from the shared store does not come back. The private file is never changed, and an older
  build of the app keeps reading it.
- **Two apps at once.** Each connection waits up to 3 s (`busy_timeout`) for another app's write lock instead of
  failing with `SQLITE_BUSY`. This applies to every store, shared or not.
- **In the background** (iOS and iPadOS). When the app enters the background, the default store closes its idle
  connection inside a background task, because iOS kills a suspended app that still holds an SQLite lock in a
  shared container. Until the app returns to the foreground, every call on a `ConversationStore` opens the
  database, runs inside its own background task and closes it again. A write made while backgrounded is not
  refused, for example the partial reply that a generation stopped by backgrounding saves.
- **Change signal.** Every write (`createConversation`, `updateTitle`, `deleteConversation`, `appendTurn`,
  `deleteTurn`, `pruneAndSummarize`) posts `TonamoxSharedStorage.didChangeNotification` with
  `.conversations`. With a group, it reaches the other running apps of the group too. Nothing in the SDK reloads
  on it: observe it, and reload when the scene becomes active, to keep a conversation list current.

On a Mac without App Sandbox the store stays at `~/Library/Application Support/AuraLocal/conversations.sqlite`,
which the `tonamox` CLI and every other non-sandboxed process of the user already share.

---

## Multi-Turn Chat

Pass a `conversationID` to any `chat` or `stream` call — context is loaded automatically:

```swift
let llm = try await Tonamox.text(.qwen3_1_7b)

let reply1 = try await llm.chat("What is 2+2?", in: conv.id)
let reply2 = try await llm.chat("Why?", in: conv.id)  // has full context

// Streaming with history
for try await token in llm.stream("Tell me more", in: conv.id) {
    print(token, terminator: "")
}
```

Before each call Tonamox loads the newest turns that fit `maxContextTokens` (default 3072, estimated at ~4 characters per token). When older turns have to be dropped, it snaps the oldest kept turn to a stride of up to 4 turns, which can drop up to 3 extra old turns. Between moves the window's start stays byte-identical, so the GGUF backends can keep their KV cache and decode only the new turns; a turn on which the start moves prefills the whole window ([Reusing the KV cache]({{ '/guide/backends' | relative_url }}#multi-turn-conversations-gguf)).

The user turn is saved before the model runs. If the call throws, the conversation keeps one reply per prompt:
a `GenerationInterrupted` that carries text (the app moved to the background, or the device guard stopped it)
saves that text as the assistant turn; any other error removes the user turn again.

Cancelling the task that runs a `stream(_:in:)` loop (a Stop button), or leaving the loop early, cancels the
generation and settles the conversation the same way: the text generated so far is saved as the reply, or the user
turn is removed when there was none. Leaving the loop cancels only once nothing else holds the stream; if you keep it
in a variable or property, stop it by cancelling the task. Those writes finish after your loop has ended, so the next
`chat(_:in:)` or `stream(_:in:)` on the same `Tonamox` waits for them before saving its prompt.

On a GGUF model loaded with tools whose call format runs on LocalLLMClient's `LlamaClient` (for example Llama 3.1's
or Mistral's), the reply is cut and saved at once, but llama.cpp keeps decoding until the end of generation or a full
context window, and the next turn on that instance waits for it. With `<tool_call>` JSON templates (Qwen2.5's, and
templates without tool support) the decode stops as without tools: after at most one more token, or when a running
prefill ends. See
[Multi-turn conversations]({{ '/guide/backends' | relative_url }}#multi-turn-conversations-gguf).

{: .note }
> MLX and GGUF models receive the turns with their roles. On GGUF every system turn, a `summarizeAndPrune` summary included, merges into one leading system turn, so the summary is added to your system prompt rather than replacing it. If the window still exceeds the model's context, the GGUF backends drop the oldest exchanges until it fits, keeping the system turn and your new message. See [Multi-turn conversations]({{ '/guide/backends' | relative_url }}#multi-turn-conversations-gguf). MLX trims nothing: past its KV window (`maxKVSize`) it overwrites the oldest tokens without an error, and `llm.lastContextOverflow` then says how many no longer fit. Qwen 3.5 text models, Gemma 3 and 4, and LFM2 ignore the window and leave it `nil` (see [Memory › MLX KV window]({{ '/guide/memory' | relative_url }}#mlx-kv-window)).

---

## Auto-Title

Generate a title from the first message automatically:

```swift
try await llm.autoTitle(conversationID: conv.id)
// Updates the conversation title in ConversationStore
```

---

## Context Window Management

When a conversation grows long, `summarizeAndPrune` replaces older turns with a compact LLM-generated summary — preserving semantic continuity without truncation:

```swift
try await llm.summarizeAndPrune(
    conversationID: conv.id,
    keepLastN: 10,           // always keep 10 most recent turns
    maxContextTokens: 4096   // prune when conversation exceeds this
)
```

Nothing calls it for you: `chat(_:in:)`, `stream(_:in:)` and `ModelManager` never prune. Call it yourself after a reply (TonamoxUI's `TextChatTab` does this after every turn) or before switching models.

---

## One-Liner with Auto-Conversation

```swift
// Creates a new conversation automatically, returns the ID
let (reply, conversationID) = try await Tonamox.chat(
    "Hello",
    model: .qwen3_1_7b
)
```

---

## SwiftUI Integration

```swift
import SwiftUI
import TonamoxCore

struct ChatView: View {
    @State private var messages: [Turn] = []
    @State private var llm: Tonamox?
    let conversationID: UUID

    var body: some View {
        List(messages) { turn in
            Text(turn.content)
        }
        .task {
            llm = try? await Tonamox.text(.qwen3_1_7b)
            messages = (try? await ConversationStore.shared.turns(for: conversationID)) ?? []
        }
    }

    func send(_ text: String) async {
        guard let llm else { return }
        _ = try? await llm.chat(text, in: conversationID)
        messages = (try? await ConversationStore.shared.turns(for: conversationID)) ?? []
    }
}
```
