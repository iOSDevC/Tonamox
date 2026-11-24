import Foundation
import Testing
@testable import TonamoxCore

@Suite("Tonamox.streamMessages")
@MainActor
struct StreamMessagesTests {
    @Test func streamMessagesCancelsDecodeOnTermination() async throws {
        let notifications = NotificationCenter()
        let lifecycle = BackgroundLifecycle(notificationCenter: notifications, didEnterBackground: nil,
                                            willEnterForeground: nil)
        let backend = SlowFakeBackend()
        let llm = Tonamox(engine: TonamoxEngine(model: .dolphin3_qwen25_1_5b_gguf, backend: backend,
                                                lifecycle: lifecycle))
        var received = 0
        for try await _ in llm.streamMessages([["role": "user", "content": "x"]], maxTokens: 100_000) {
            received += 1
            if received == 3 { break }
        }
        try await waitUntil { !backend.isGenerating }
        #expect(backend.producedTokens < 100_000)
        #expect(backend.generations == 1)
        #expect(!llm.isToolEnabled)
    }

    @Test func generateReturnsOnlyAfterTheCancelledDecodeStopped() async throws {
        let notifications = NotificationCenter()
        let lifecycle = BackgroundLifecycle(notificationCenter: notifications, didEnterBackground: nil,
                                            willEnterForeground: nil)
        let backend = SlowFakeBackend()
        let llm = Tonamox(engine: TonamoxEngine(model: .dolphin3_qwen25_1_5b_gguf, backend: backend,
                                                lifecycle: lifecycle))
        var pieces: [String] = []
        let task = Task { @MainActor in
            try await llm.generate("x", maxTokens: 100_000) { pieces.append($0) }
        }
        try await waitUntil { pieces.count >= 3 }
        task.cancel()
        _ = await task.result
        #expect(!backend.isGenerating, "the call returned while the backend was still decoding")
        #expect(backend.producedTokens < 100_000)
        #expect(pieces.first == "t0 ")
    }
}
