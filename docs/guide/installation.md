---
layout: docs
title: Installation
parent: Guide
nav_order: 1
description: "Add Tonamox to your iOS, macOS, or visionOS project via Swift Package Manager."
---

# Installation
{: .no_toc }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

{: .important }
> Tonamox is licensed under **AGPL-3.0-or-later**, or under a commercial license from the copyright holder.
> Under the AGPL, an app or package that links it and is distributed must be released under AGPL-3.0-compatible
> terms, with its source available, and if you modify Tonamox and let people use it over a network, you must
> offer them the source of your version too. The AGPL's conditions conflict with the App Store's terms; a
> closed-source app, an App Store release, or a network service whose source you don't publish needs the
> commercial license. Models you download carry their own licenses. See
> [License]({{ '/license' | relative_url }}).

## Requirements

| Requirement | Minimum |
|-------------|---------|
| iOS | 18.0+ |
| macOS | 15.0+ |
| visionOS | 2.0+ |
| Xcode | 16.3+ (Swift 6.1); Xcode 27 for `TonamoxAppleIntelligence` and `TonamoxAgents`; Xcode 26.4 for `TonamoxImageGen` and the `tonamox` CLI |
| Swift | 6.1 toolchain (your manifest can stay at tools-version 6.0) |

{: .important }
> Tonamox requires a **Swift 6.1** toolchain, because its pinned dependencies declare tools-version 6.1, and **C++ interoperability mode**, because the llama.cpp backend (`LocalLLMClient`) contains C++ headers. Every target that imports `TonamoxCore`, or a module built on it, must enable C++ interop. `TonamoxAppleIntelligence` and `TonamoxAgents` import FoundationModels, so they build only with the iOS 27 / macOS 27 SDK (Xcode 27), and their APIs require iOS 27, macOS 27 or visionOS 27 at run time. `TonamoxImageGen`, and the `tonamox` CLI built on it, use `ImagePlaygroundOptions`, which first appears in the 26.4 SDKs (Xcode 26.4).

---

## Swift Package Manager

### Xcode (recommended)

1. Open your project in Xcode
2. **File → Add Package Dependencies…**
3. Enter the repository URL:
   ```
   https://github.com/iOSDevC/Tonamox
   ```
4. Under **Dependency Rule** choose **Commit** and paste a commit SHA from `main` (or choose **Branch** `main` to follow it). Version rules do not resolve; see [Pin a commit](#pin-a-commit).
5. Add the modules you need to your target
6. In your app target's **Build Settings**, set **C++ and Objective-C Interoperability** to **C++ / Objective-C++** (`SWIFT_OBJC_INTEROP_MODE = objcxx`). Every target that imports `TonamoxCore`, or a module built on it, needs it.

### Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/iOSDevC/Tonamox", revision: "<commit SHA from development>"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "TonamoxCore", package: "Tonamox"),
                .product(name: "TonamoxUI",   package: "Tonamox"),   // optional
                .product(name: "TonamoxVoice", package: "Tonamox"),  // optional
                .product(name: "TonamoxDocs", package: "Tonamox"),   // optional
            ],
            swiftSettings: [
                // Required — LocalLLMClient (llama.cpp) contains C++ headers
                .interoperabilityMode(.Cxx),
            ]
        ),
    ]
)
```

{: .warning }
> The `.interoperabilityMode(.Cxx)` setting is **mandatory**. Without it the build fails with `module 'TonamoxCore' was built with C++ interoperability enabled, but current compilation does not enable C++ interoperability` (the message names the Tonamox module you import).

### Pin a commit

Tonamox depends on LocalLLMClient by revision, so SwiftPM rejects a version requirement (`from:` or `exact:`) on Tonamox. Put a commit SHA from `main` in `revision:`. `branch: "main"` also resolves, but it moves with every push.

---

## Dependencies

Tonamox pulls in six dependencies automatically — you do not need to add them manually:

| Package | Purpose |
|---------|---------|
| [LocalLLMClient](https://github.com/tattn/LocalLLMClient) 0.5.0 | Swift wrapper for llama.cpp: GGUF inference. Upstream 0.5.0 bundles build b8851; this branch builds against a local, unpublished fork on b12407 (`../LocalLLMClient-tonamox`), so it does not resolve outside the maintainer's machine yet |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.31.3 or later | MLX GPU inference for `.mlx` models |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) 0.31.3 up to, not including, 0.31.5 | The MLX arrays and Metal kernels under mlx-swift-lm. 0.31.5 does not build for iOS (mlx-swift #436) and 0.31.6 is the version in an open report of an app hanging before `main()` on iOS 27 (#485); a resolve without Tonamox's lockfile gets 0.31.4 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) 1.3.0 or later | Tokenizers for MLX models and for the Core ML text-embedding tool (multilingual-e5) |
| [swift-jinja](https://github.com/huggingface/swift-jinja) 2.3.5 or later | Renders each GGUF model's chat template, so llama.cpp turns get real roles and Tonamox decides itself when the KV cache can be kept |
| [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) 1.1.1 (exact) | Core ML Stable Diffusion for `TonamoxImageGen` on iOS and macOS (not linked on visionOS) |

---

## Entitlements

Add the following to your `.entitlements` file. Without it the OS will terminate your app when loading models larger than ~500 MB.

```xml
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
<key>com.apple.developer.kernel.extended-virtual-addressing</key>
<true/>
```

For macOS apps using GGUF models stored outside the sandbox:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

---

## App Groups (sharing storage between apps)

Optional. Several apps of yours can share Tonamox's models, records, conversations, document index and (iOS) keys
through one App Group. What is shared, what moves and what is copied are described in
[Sharing storage between apps]({{ '/guide/models' | relative_url }}#sharing-storage-between-apps-app-group).

1. **Entitlement.** Add the group to each app's iOS entitlements:

   ```xml
   <key>com.apple.security.application-groups</key>
   <array>
       <string>group.com.example.apps</string>
   </array>
   ```

   On a device, the group must be registered for your team and included in each app's provisioning profile.
   Automatic signing does this when the capability is enabled. Simulator builds need no profile, because the
   Simulator reads the entitlements embedded in the binary. Keychain items need no `keychain-access-groups`
   entry: on iOS an App Group identifier is also a keychain access group.
2. **Configure first.** In each app, call `TonamoxSharedStorage.configure(appGroup:)` in `App.init`, before any
   other Tonamox call. The first storage access fixes the configuration, and a later `configure` is ignored:

   ```swift
   init() {
       let result = TonamoxSharedStorage.configure(appGroup: "group.com.example.apps")
       // .applied(.appGroup(identifier:container:)) on iOS with the entitlement
       // .unavailable(appGroup:) without it: storage stays private, nothing moves
       // .ignored(current:firstUse:) if storage was already used
       DownloadRecords.standard.registerDownloaded()
   }
   ```

3. **Refresh.** Observe `TonamoxSharedStorage.didChangeNotification` to reload what another app changed, and
   reload as well when the scene becomes active, because a suspended app misses these signals. TonamoxUI's
   `ModelDownloadCenter` and TonamoxDocs' `DocsTab` already observe it.

On macOS:

- **App without App Sandbox:** no entitlement is needed. `configure` returns `.applied(.userWide(identifier:))`.
  Files stay in `~/Library/Application Support`, which every process of the user already shares. Only the
  download and image-model records change place: each app copies its own into a shared file there. TonamoxExample's Mac builds work this way and
  carry no App Group.
- **Sandboxed app:** the group must be in `com.apple.security.application-groups`. Tonamox reads it from the code
  signature, and without it `configure` returns `.unavailable`. On macOS, a `group.`-prefixed identifier needs a
  provisioning profile that includes it. Keychain items are not shared: the login keychain has no access groups.

The `tonamox` CLI and `swift test` never call `configure`, so they keep the paths they have always used.

---

## Permissions (Voice)

If you use `TonamoxVoice`, add these keys to `Info.plist`:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Used for voice input to the local AI assistant.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used to capture your voice for the AI assistant.</string>
```

---

## Permissions (local network)

On iOS, reaching a model server on another machine (a `LocalProviderEndpoint` whose `baseURL` points at, for
example, Ollama or `llama-server` on your Mac) shows the Local Network permission prompt with this string.
TonamoxExample declares it:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to a model server on your local network, such as Ollama or llama-server on your Mac.</string>
```

The default endpoints (`localhost:11434`, `127.0.0.1:8080`) are loopback and do not need it.

---

## Privacy manifests

`TonamoxCore` and `TonamoxImageGen` each ship a `PrivacyInfo.xcprivacy` in their resource bundles
(`Tonamox_TonamoxCore.bundle`, `Tonamox_TonamoxImageGen.bundle`), which Xcode reads into your app's privacy report.
Both declare no tracking, no tracking domains and no collected data. The required-reason APIs they declare:

| Module | Category | Reasons | Used by |
|--------|----------|---------|---------|
| `TonamoxCore` | File timestamp | `C617.1`, `3B52.1` | the age of the cached remote catalog in Caches; the fingerprint of the model `CoreMLModelTool` compiles, which can be a file the user picked |
| `TonamoxCore` | Disk space | `E174.1`, `85F4.1` | the free-space check before a model download; the free space `ModelDownloads.availableDiskBytes()` returns for display (TonamoxUI's download views) |
| `TonamoxCore` | User defaults | `CA92.1` | `DownloadRecords` |
| `TonamoxImageGen` | User defaults | `CA92.1` | `CoreMLDiffusionModelStore` |

The other modules use none of these APIs and ship no manifest. With an App Group configured, `DownloadRecords`
and `CoreMLDiffusionModelStore` still read `UserDefaults.standard`, only to copy the app's own records into the
shared file once. That file is plain JSON, not an App Group `UserDefaults` suite, so no `1C8F.1` reason applies.

**What your app declares.** Tonamox sends nothing to its developer. Hybrid escalation sends text (system prompt,
question and compressed context) to the endpoint your app configures, after your `ConsentGate` approves it; model
downloads request files from Hugging Face, with your token for gated repos. Whether that is data your app collects
depends on who runs the endpoint and how long it keeps requests, so declare it in your app's own manifest and App
Store privacy details when it applies, for example `NSPrivacyCollectedDataTypeOtherUserContent` for App
Functionality.

Tonamox's manifests cover its own code only. Of the packages in its `Package.resolved`, only swift-nio and
swift-crypto ship manifests; the rest, including LocalLLMClient with its `llama.framework`, mlx-swift and
mlx-swift-lm, ship none at the pinned versions, so check their API use for your app's manifest.

---

## Verify the Install

```swift
import TonamoxCore

// Should print the display name and size of a model
print(Model.qwen3_1_7b.displayName)       // "Qwen3 1.7B"
print(Model.qwen3_1_7b.approximateSizeMB) // 923

// Check hardware compatibility
let fit = HardwareAnalyzer.assess(.llama3_1_8b_gguf)
print(fit.fitLevel.label) // "Streaming" on an entitled 6 GB iPhone; on a Mac it depends on the
                          // memory free now ("Excellent" above ~8.4 GB)
```

---

## Modules Reference

Import only what you need:

```swift
import TonamoxCore   // needed by every module except TonamoxAppleIntelligence

import TonamoxUI     // prebuilt SwiftUI tabs
import TonamoxVoice  // voice pipeline
import TonamoxDocs   // RAG document library

import TonamoxAgents             // AgentCrew multi-agent pipeline (iOS 27 / macOS 27 / visionOS 27)
import TonamoxAppleIntelligence  // FoundationModels agents; no TonamoxCore dependency (iOS 27 / macOS 27 / visionOS 27)
import TonamoxImageGen           // text-to-image: Core ML Stable Diffusion on device; FLUX via mflux on macOS
```

The `tonamox` command-line tool is a separate executable product. See [CLI]({{ '/guide/cli' | relative_url }}).
