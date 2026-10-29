import Foundation

// MARK: - BenchmarkWorkload

/// One prompt an ``EngineBenchmark`` sends to every candidate: the same system prompt, user prompt and token budget
/// for each engine.
public struct BenchmarkWorkload: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier: `chat`, `code` or `long` for the built-in workloads.
    public let id: String
    /// Human-readable name for tables and pickers.
    public let title: String
    public let systemPrompt: String
    public let userPrompt: String
    /// Token budget, unless ``BenchmarkSettings/maxTokensOverride`` replaces it.
    public let maxTokens: Int

    public init(id: String, title: String, systemPrompt: String, userPrompt: String, maxTokens: Int) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxTokens = maxTokens
    }

    /// A short conversational question.
    public static let chat = BenchmarkWorkload(
        id: "chat",
        title: "Short chat",
        systemPrompt: "You are a helpful assistant. Answer clearly in one short paragraph.",
        userPrompt: "I am travelling for a week and cannot feed my sourdough starter. "
            + "What are three practical ways to keep it healthy until I return?",
        maxTokens: 128)

    /// A small code-generation task.
    public static let code = BenchmarkWorkload(
        id: "code",
        title: "Code generation",
        systemPrompt: "You are an expert Swift programmer. Reply with Swift code and brief comments only.",
        userPrompt: "Write a Swift function `mergeIntervals(_ intervals: [ClosedRange<Int>]) -> [ClosedRange<Int>]` "
            + "that sorts the ranges and merges any that overlap or touch. Add a short doc comment and three example "
            + "calls with their expected results.",
        maxTokens: 256)

    /// A summary of a fictional annual review of about 3,200 tokens (UTF-8 bytes ÷ 4), built in code from varied,
    /// non-repeating sentences. The model is asked to summarize in its own words, never to copy, so drafters that
    /// predict tokens from the prompt get no more help than real use gives them.
    public static let longDocument = BenchmarkWorkload(
        id: "long",
        title: "Long-document summary",
        systemPrompt: "You summarize documents for busy readers. Use only facts stated in the document.",
        userPrompt: "Summarize the review below for a board member who has five minutes. Write five bullet points "
            + "covering the most important results and risks, in your own words.\n\n" + AnnualReview.text,
        maxTokens: 256)

    /// ``chat``, ``code`` and ``longDocument``, in that order.
    public static let all: [BenchmarkWorkload] = [.chat, .code, .longDocument]
}

// MARK: - AnnualReview

/// The long workload's document: a fictional water cooperative's annual review. Each sentence pairs a different
/// subject, finding, opener and closing clause with its own figures, so no sentence repeats.
enum AnnualReview {

    struct Section {
        let title: String
        /// Four noun phrases; sentence `j` uses `subjects[j % 4]`.
        let subjects: [String]
        /// Five verb phrases with `%A`/`%B` figures; sentence `j` uses `findings[j % 5]`, so the first 20 sentences
        /// never pair the same subject and finding twice.
        let findings: [String]
    }

    static let sentencesPerSection = 12

    static let intro = "Tallis Valley Water Cooperative: annual review for the board. This review covers six areas of "
        + "the cooperative's operations over the last reporting year. Figures are provisional until the audited "
        + "accounts are published in the spring."

    static let openers = [
        "In January", "During the spring thaw", "By the end of March", "Over the dry weeks of July",
        "In late August", "Throughout the autumn", "After the October storms", "In the final quarter",
        "Across the whole year", "Compared with the previous review", "Early in the reporting period",
        "Within six weeks of the budget vote",
    ]

    static let closings = [
        ", a change the finance committee asked staff to track monthly",
        ", which the board discussed at its September meeting",
        ", although auditors cautioned that the sample was small",
        ", largely because two contractors finished ahead of schedule",
        ", and the figure was confirmed by an independent laboratory",
        ", prompting a revision of the five-year maintenance plan",
        ", while neighbouring utilities reported the opposite trend",
        ", even though rainfall stayed close to the long-term average",
        ", a result attributed mostly to newer metering hardware",
        ", which freed money for the school outreach programme",
        ", though the improvement was uneven between the valleys",
        ", after residents in Harwick Ridge had raised repeated complaints",
        ", which inspectors from the state regulator later endorsed",
        ", a pace the operations director called sustainable",
    ]

    static let sections = [
        Section(
            title: "Supply and reservoirs",
            subjects: ["the Kestrel Lake reservoir", "the three upland springs", "the groundwater wells near Ostby",
                       "the emergency intake on the Marrow River"],
            findings: ["delivered %A megalitres more than the planning forecast",
                       "operated %B percent below the licensed abstraction limit",
                       "showed nitrate readings %B percent lower than in the prior year",
                       "needed %A hours of unplanned shutdown for sediment removal",
                       "supplied roughly one household in %B during peak demand"]),
        Section(
            title: "Treatment plants",
            subjects: ["the Fennick filtration works", "the smaller plant at Calder Gap",
                       "the new ultraviolet disinfection line", "the sludge handling unit"],
            findings: ["processed an average of %A megalitres a day without a compliance breach",
                       "cut chemical dosing costs by %B percent",
                       "raised %B turbidity alarms, each cleared within an hour",
                       "was offline for %A hours while engineers replaced worn membranes",
                       "passed every one of the %A scheduled microbiological tests"]),
        Section(
            title: "Distribution network",
            subjects: ["crews in the eastern districts", "the leak detection team", "the pressure management programme",
                       "the contractor relining cast-iron mains"],
            findings: ["repaired %A bursts, most of them on pipes laid before 1960",
                       "reduced estimated leakage by %B percent",
                       "replaced %A kilometres of service pipe",
                       "brought the average response time for reported leaks down to %B hours",
                       "found %B illegal connections, which were either regularised or removed"]),
        Section(
            title: "Customers and billing",
            subjects: ["the call centre", "the online account portal", "the hardship assistance scheme",
                       "the billing team"],
            findings: ["answered %A thousand enquiries with a median wait of %B minutes",
                       "enrolled %A new households, many of them pensioners",
                       "saw complaints about estimated bills fall by %B percent",
                       "agreed %A payment plans with customers in arrears",
                       "settled %B percent of disputes at the first contact"]),
        Section(
            title: "Workforce and safety",
            subjects: ["the field maintenance staff", "the apprenticeship intake", "the health and safety committee",
                       "the laboratory group"],
            findings: ["logged %B lost-time injuries, fewer than the year before",
                       "completed %A hours of confined-space training",
                       "welcomed %B new trainees, several of them from local technical colleges",
                       "carried out %A unannounced site inspections",
                       "reported staff turnover of %B percent, the lowest in a decade"]),
        Section(
            title: "Energy and capital works",
            subjects: ["the pumping stations", "the solar array at Fennick", "the Calder Gap upgrade",
                       "the reservoir dam safety review"],
            findings: ["used %B percent less electricity per megalitre pumped",
                       "generated %A megawatt-hours, covering part of the treatment load",
                       "ran %B percent over the original budget because of foundation work",
                       "reached the detailed design stage after %A days of public consultation",
                       "recommended %B structural repairs to be scheduled over three years"]),
    ]

    static let text: String = {
        let body = sections.enumerated().map { index, section in sectionText(section, index: index) }
        return ([intro] + body).joined(separator: "\n\n")
    }()

    /// The section's heading and two paragraphs.
    static func sectionText(_ section: Section, index: Int) -> String {
        let lines = (0..<sentencesPerSection).map { sentence(in: section, sectionIndex: index, number: $0) }
        let half = sentencesPerSection / 2
        return "## \(section.title)\n\n" + lines[..<half].joined(separator: " ") + "\n\n"
            + lines[half...].joined(separator: " ")
    }

    /// Sentence `number` of a section; the strides keep openers, closings and figures varied across sections.
    static func sentence(in section: Section, sectionIndex: Int, number: Int) -> String {
        let figureA = 12 + (sectionIndex * 37 + number * 23) % 80
        let figureB = 3 + (sectionIndex * 13 + number * 7) % 40
        let finding = section.findings[number % section.findings.count]
            .replacingOccurrences(of: "%A", with: "\(figureA)")
            .replacingOccurrences(of: "%B", with: "\(figureB)")
        let opener = openers[(sectionIndex * 5 + number * 7) % openers.count]
        let closing = closings[(sectionIndex * 3 + number * 5) % closings.count]
        return "\(opener), \(section.subjects[number % section.subjects.count]) \(finding)\(closing)."
    }
}
