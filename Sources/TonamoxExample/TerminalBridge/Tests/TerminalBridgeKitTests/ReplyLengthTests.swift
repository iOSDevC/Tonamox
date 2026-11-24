import Foundation
import Testing
@testable import TerminalBridgeKit

@Suite struct ReplyLengthTests {
    @Test func storedValueDefaultsToShort() {
        #expect(ReplyLength.stored(nil) == .short)
        #expect(ReplyLength.stored("basura") == .short)
        #expect(ReplyLength.stored("long") == .long)
        #expect(ReplyLength.allCases.map(\.tokens) == [400, 800, 1600])
        #expect(ReplyLength.allCases.map(\.title)
            == ["Corta (400 tokens)", "Media (800 tokens)", "Larga (1600 tokens)"])
    }

    @Test func reportText() {
        #expect(ReplyLength.reportText(1600) == "Longitud de respuesta: hasta 1600 tokens.")
        #expect(ReplyLength.reportText(nil) == "Longitud de respuesta: hasta 400 tokens (fija en informes anteriores).")
    }

    @Test func probeTimeLimitGrowsWithTheBudgets() {
        #expect(ReplyLength.probeTimeLimit(answerTokens: 400, reasoningTokens: 512) == 120)
        #expect(ReplyLength.probeTimeLimit(answerTokens: 1600, reasoningTokens: 1024) == 328)
        #expect(ReplyLength.probeTimeLimit(answerTokens: 1600, reasoningTokens: nil) == 200)
        #expect(ReplyLength.probeTimeLimit(answerTokens: -5, reasoningTokens: -1) == 120)
        #expect(ReplyLength.timeoutReason(seconds: 328, tokens: 2624) == "Sin terminar en 328 s, el límite para 2624 tokens.")
    }
}

@Suite struct ReplyBudgetTests {
    private static let margin = ReplyBudget.closeAllowance

    @Test func requestThatFitsIsUnchanged() {
        let budget = ReplyBudget.fitting(answer: 400, reasoning: 512, window: 8192, promptTokens: 700)
        #expect(budget == ReplyBudget(answerTokens: 400, reasoningTokens: 512))
        #expect(budget.limit == nil)
        let exact = ReplyBudget.fitting(answer: 400, reasoning: 512, window: 912 + 100 + Self.margin, promptTokens: 100)
        #expect(exact.limit == nil)
    }

    @Test func withoutAWindowNothingIsClamped() {
        let budget = ReplyBudget.fitting(answer: 1600, reasoning: nil, window: nil, promptTokens: 100_000)
        #expect(budget == ReplyBudget(answerTokens: 1600, reasoningTokens: nil))
    }

    @Test func reasoningShrinksBeforeTheAnswer() {
        let budget = ReplyBudget.fitting(answer: 800, reasoning: 1024, window: 2048, promptTokens: 1000)
        let room = 2048 - 1000 - Self.margin
        #expect(budget.answerTokens == 800)
        #expect(budget.reasoningTokens == room - 800)
        #expect(budget.limit == .reasoning(room - 800))
        #expect(budget.totalTokens == room)
        #expect(budget.limit?.note == "Razonamiento limitado a \(room - 800) tokens por el contexto del modelo.")
    }

    @Test func answerIsCutOnceTheReasoningIsGone() {
        let budget = ReplyBudget.fitting(answer: 1600, reasoning: 512, window: 2048, promptTokens: 1000)
        let room = 2048 - 1000 - Self.margin
        #expect(budget == ReplyBudget(answerTokens: room, reasoningTokens: 0,
                                      limit: .answer(room, withoutReasoning: true)))
        #expect(budget.limit?.note == "Respuesta limitada a \(room) tokens, sin razonamiento, por el contexto del modelo.")
    }

    @Test func reasoningSqueezedToNothingSaysSo() {
        let budget = ReplyBudget.fitting(answer: 400, reasoning: 512, window: 400 + 100 + Self.margin, promptTokens: 100)
        #expect(budget == ReplyBudget(answerTokens: 400, reasoningTokens: 0, limit: .answer(400, withoutReasoning: true)))
        #expect(budget.limit?.note == "Respuesta limitada a 400 tokens, sin razonamiento, por el contexto del modelo.")
        let one = ReplyBudget.fitting(answer: 400, reasoning: 512, window: 401 + 100 + Self.margin, promptTokens: 100)
        #expect(one.limit == .reasoning(1))
    }

    @Test func answerWithoutReasoningBudgetIsCut() {
        let budget = ReplyBudget.fitting(answer: 1600, reasoning: nil, window: 1024, promptTokens: 300)
        let room = 1024 - 300 - Self.margin
        #expect(budget == ReplyBudget(answerTokens: room, reasoningTokens: nil,
                                      limit: .answer(room, withoutReasoning: false)))
        #expect(budget.limit?.note == "Respuesta limitada a \(room) tokens por el contexto del modelo.")
        #expect(budget.limit?.refusal == nil)
    }

    @Test func promptThatFillsTheWindowIsRefused() {
        let budget = ReplyBudget.fitting(answer: 400, reasoning: 512, window: 2048, promptTokens: 2048)
        #expect(budget.limit == .noRoom(window: 2048))
        #expect(budget.answerTokens == 0)
        #expect(budget.reasoningTokens == 0)
        #expect(budget.limit?.note == nil)
        #expect(budget.limit?.refusal?.hasPrefix("El mensaje no deja sitio") == true)
        let tight = ReplyBudget.fitting(answer: 400, reasoning: nil, window: 1000,
                                        promptTokens: 1000 - Self.margin - ReplyBudget.minimumAnswer + 1)
        #expect(tight.limit == .noRoom(window: 1000))
        let enough = ReplyBudget.fitting(answer: 400, reasoning: nil, window: 1000,
                                         promptTokens: 1000 - Self.margin - ReplyBudget.minimumAnswer)
        #expect(enough.answerTokens == ReplyBudget.minimumAnswer)
    }

    @Test func budgetNeverExceedsTheWindow() {
        for window in stride(from: 256, through: 8192, by: 256) {
            for prompt in stride(from: 0, through: 9000, by: 450) {
                let budget = ReplyBudget.fitting(answer: 1600, reasoning: 1024, window: window, promptTokens: prompt)
                if budget.limit != .noRoom(window: window) {
                    #expect(prompt + budget.totalTokens + Self.margin <= window)
                    #expect(budget.answerTokens >= ReplyBudget.minimumAnswer)
                }
            }
        }
    }

    @Test func hugeOrNegativeRequestsDoNotOverflow() {
        let huge = ReplyBudget.fitting(answer: .max, reasoning: .max, window: 4096, promptTokens: 0)
        #expect(huge.totalTokens <= 4096)
        let negative = ReplyBudget.fitting(answer: -5, reasoning: -1, window: 4096, promptTokens: 0)
        #expect(negative == ReplyBudget(answerTokens: 0, reasoningTokens: 0))
    }

    @Test func planPassesTheClampedBudgetOnlyWhenTheBackendEnforcesIt() {
        let enforced = ReplyBudget.planned(answer: 800, reasoning: .long, enforcesBudget: true, window: 2048,
                                           promptTokens: 1000)
        let room = 2048 - 1000 - Self.margin
        #expect(enforced.budget.reasoningTokens == room - 800)
        #expect(enforced.reasoningRequest == room - 800)
        let ignored = ReplyBudget.planned(answer: 800, reasoning: .long, enforcesBudget: false, window: 2048,
                                          promptTokens: 1000)
        #expect(ignored.budget == ReplyBudget(answerTokens: 800, reasoningTokens: nil))
        #expect(ignored.reasoningRequest == 1024)
        let off = ReplyBudget.planned(answer: 800, reasoning: .disabled, enforcesBudget: true, window: 2048,
                                      promptTokens: 1000)
        #expect(off.reasoningRequest == nil)
        #expect(off.budget.reasoningTokens == nil)
        let fits = ReplyBudget.planned(answer: 400, reasoning: .medium, enforcesBudget: true, window: 8192,
                                       promptTokens: 700)
        #expect(fits.reasoningRequest == 512)
        #expect(fits.budget.limit == nil)
    }

    @Test func windowFillIsFlaggedOnlyWhenTheWorstCasePromptReachesIt() {
        let prompt = ReplyBudget.maximumPromptTokens(systemPrompt: "abc", prompt: "ñ")
        #expect(prompt == 5 + ReplyBudget.templateAllowance)
        #expect(ReplyBudget.mayHaveFilledWindow(window: 4096, maximumPromptTokens: 3000, decoded: 1100, answered: 300,
                                                answerLimit: 1600))
        #expect(!ReplyBudget.mayHaveFilledWindow(window: 4096, maximumPromptTokens: 1500, decoded: 300, answered: 300,
                                                 answerLimit: 1600))
        #expect(!ReplyBudget.mayHaveFilledWindow(window: 4096, maximumPromptTokens: 3000, decoded: 1600,
                                                 answered: 1600, answerLimit: 1600))
        #expect(!ReplyBudget.mayHaveFilledWindow(window: nil, maximumPromptTokens: 9000, decoded: 10, answered: 10,
                                                 answerLimit: 400))
        let boundary = 4096 - 1000 - Self.margin
        #expect(ReplyBudget.mayHaveFilledWindow(window: 4096, maximumPromptTokens: 1000, decoded: boundary,
                                                answered: 0, answerLimit: 400))
        #expect(!ReplyBudget.mayHaveFilledWindow(window: 4096, maximumPromptTokens: 1000, decoded: boundary - 1,
                                                 answered: 0, answerLimit: 400))
        #expect(ReplyBudget.windowFilledNote(window: 4096).contains("(4096 tokens)"))
    }

    @Test func promptEstimateIsBytesOverTwoPlusTheTemplate() {
        #expect(ReplyBudget.estimatedPromptTokens(systemPrompt: "", prompt: "") == ReplyBudget.templateAllowance)
        #expect(ReplyBudget.estimatedPromptTokens(systemPrompt: "abc", prompt: "") == 2 + ReplyBudget.templateAllowance)
        #expect(ReplyBudget.estimatedPromptTokens(systemPrompt: String(repeating: "x", count: 3000), prompt: "ñ")
            == 1501 + ReplyBudget.templateAllowance)
    }
}

@Suite struct MeasuredDecodeTests {
    @Test func costCountsTheReasoningOnlyWhenTheBackendEnforcesIt() {
        let gguf = MeasuredDecode(tokensPerSecond: 50, reasoningCounts: true)
        #expect(gguf.costLine(length: .short, reasoning: .medium)
            == "Una respuesta completa tarda unos 19 s con este modelo (912 tokens a 50 tokens/s, última medida).")
        #expect(gguf.costLine(length: .short, reasoning: .disabled)
            == "Una respuesta completa tarda unos 8 s con este modelo (400 tokens a 50 tokens/s, última medida).")
        let mlx = MeasuredDecode(tokensPerSecond: 50, reasoningCounts: false)
        #expect(mlx.costLine(length: .short, reasoning: .long)?.contains("(400 tokens") == true)
    }

    @Test func longRepliesAreInMinutes() {
        let slow = MeasuredDecode(tokensPerSecond: 10, reasoningCounts: true)
        #expect(slow.costLine(length: .long, reasoning: .long)?.hasPrefix("Una respuesta completa tarda unos 4 min") == true)
    }

    @Test func slowerThanOneTokenPerSecondIsNotRoundedUp() {
        let crawl = MeasuredDecode(tokensPerSecond: 0.4, reasoningCounts: false)
        #expect(crawl.costLine(length: .short, reasoning: .disabled)
            == "Una respuesta completa tarda unos 17 min con este modelo (400 tokens a menos de 1 token/s, última medida).")
    }

    @Test func noUsableSpeedNoLine() {
        #expect(MeasuredDecode(tokensPerSecond: 0, reasoningCounts: true).costLine(length: .short, reasoning: .medium) == nil)
        #expect(MeasuredDecode(tokensPerSecond: .nan, reasoningCounts: true).costLine(length: .short, reasoning: .medium) == nil)
    }

    @Test func archiveRoundTripsAndToleratesGarbage() {
        let entries = ["gguf:a": MeasuredDecode(tokensPerSecond: 42.5, reasoningCounts: true)]
        #expect(MeasuredDecodeArchive.decode(MeasuredDecodeArchive.encode(entries)) == entries)
        #expect(MeasuredDecodeArchive.decode(Data("{".utf8)).isEmpty)
        #expect(MeasuredDecodeArchive.decode(nil).isEmpty)
    }
}
