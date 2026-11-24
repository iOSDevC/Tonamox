import Foundation
import TonamoxCore
import TonamoxHTTP

/// A validated `POST /v1/chat/completions` body.
struct ChatCompletionRequest: Sendable, Equatable {
    let model: String
    let messages: [ServedMessage]
    let stream: Bool
    let includeUsage: Bool
    let maxTokens: Int
    let reasoning: ReasoningOptions
    /// Accepted but ignored parameters, sorted; reported in `X-Tonamox-Ignored-Params`.
    let ignored: [String]
}

enum ChatCompletionDecoder {
    static let handled: Set<String> = ["model", "messages", "stream", "stream_options", "max_tokens",
                                       "max_completion_tokens", "reasoning_effort", "chat_template_kwargs"]
    /// Reasoning budgets per `reasoning_effort`, before ``ServerLimits/maxReasoningBudget``; `none` disables thinking.
    static let effortBudgets: [String: Int] = ["minimal": 256, "low": 256, "medium": 1024, "high": 4096]
    /// Checked in this order, so the reported `param` is deterministic.
    static let rejected = ["tools", "tool_choice", "functions", "function_call", "response_format", "logprobs",
                           "top_logprobs", "logit_bias", "n", "stop", "audio", "modalities", "prediction"]

    static func decode(_ body: Data, limits: ServerLimits) throws(APIError) -> ChatCompletionRequest {
        guard !JSONDepth.exceeds(body, limit: limits.maxJSONDepth) else {
            throw .invalidJSON("The request body nests deeper than \(limits.maxJSONDepth) levels.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let fields = object as? [String: Any] else { throw .invalidJSON() }
        for name in rejected where isUnsupported(name, fields[name]) {
            throw .unsupported(name)
        }
        guard let model = fields["model"] as? String else { throw .modelNotFound("") }
        let messages = try decodeMessages(fields["messages"], limits: limits)
        let stream = try flag(fields["stream"], name: "stream") ?? false
        let options = fields["stream_options"] as? [String: Any]
        let includeUsage = try flag(options?["include_usage"], name: "stream_options.include_usage") ?? false
        let preferred = try integer(fields["max_completion_tokens"], name: "max_completion_tokens")
        let legacy = try integer(fields["max_tokens"], name: "max_tokens")
        let requested = preferred ?? legacy ?? limits.defaultMaxTokens
        let (reasoning, kwargsIgnored) = try reasoningOptions(fields, limits: limits)
        let ignored = fields.keys.filter { !handled.contains($0) && !rejected.contains($0) } + kwargsIgnored
        return ChatCompletionRequest(model: model, messages: messages, stream: stream, includeUsage: includeUsage,
                                     maxTokens: min(max(requested, 1), limits.maxTokensCap), reasoning: reasoning,
                                     ignored: reportable(ignored))
    }

    /// `reasoning_effort` (`none`, `minimal`, `low`, `medium`, `high`) and `chat_template_kwargs.enable_thinking`.
    /// `none` or `enable_thinking: false` disable thinking; otherwise the effort's budget, or the default one, caps
    /// the reasoning. Other `chat_template_kwargs` keys are ignored and reported.
    static func reasoningOptions(_ fields: [String: Any],
                                 limits: ServerLimits) throws(APIError) -> (ReasoningOptions, ignored: [String]) {
        var effort: String?
        if let value = fields["reasoning_effort"], !(value is NSNull) {
            guard let name = value as? String, name == "none" || effortBudgets[name] != nil else {
                throw .invalidRequest("invalid_reasoning_effort",
                                      "reasoning_effort must be none, minimal, low, medium or high.",
                                      param: "reasoning_effort")
            }
            effort = name
        }
        var enableThinking: Bool?
        var ignored: [String] = []
        if let value = fields["chat_template_kwargs"], !(value is NSNull) {
            guard let kwargs = value as? [String: Any] else {
                throw .invalidJSON("chat_template_kwargs must be an object.", param: "chat_template_kwargs")
            }
            enableThinking = try flag(kwargs["enable_thinking"], name: "chat_template_kwargs.enable_thinking")
            ignored = kwargs.keys.filter { $0 != "enable_thinking" }.map { "chat_template_kwargs." + $0 }
        }
        if enableThinking == true && effort == "none" {
            throw .invalidRequest("conflicting_reasoning",
                                  "reasoning_effort none contradicts chat_template_kwargs.enable_thinking true.",
                                  param: "chat_template_kwargs.enable_thinking")
        }
        if enableThinking == false || effort == "none" { return (.disabled, ignored) }
        let budget = effort.flatMap { effortBudgets[$0] } ?? limits.defaultReasoningBudget
        return (.budgeted(min(max(budget, 0), limits.maxReasoningBudget)), ignored)
    }

    static let reportedKeysLimit = 32
    static let reportedKeyLength = 64

    /// Keys go into a response header: only short token-character names, and a bounded number of them.
    static func reportable(_ keys: [String]) -> [String] {
        let valid = keys.filter { key in
            (1...reportedKeyLength).contains(key.utf8.count) && key.utf8.allSatisfy(HTTPRequestParser.isTokenByte)
        }
        return Array(valid.sorted().prefix(reportedKeysLimit))
    }

    /// `null` counts as absent; neutral values clients send by default (`n: 1`, `stop: []`, text-only formats) pass.
    private static func isUnsupported(_ name: String, _ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        switch name {
        case "n": return (value as? NSNumber)?.intValue != 1 || isBool(value)
        case "logprobs": return !(isBool(value) && (value as? Bool) == false)
        case "stop":
            if let text = value as? String { return !text.isEmpty }
            if let list = value as? [Any] { return !list.isEmpty }
            return true
        case "response_format": return ((value as? [String: Any])?["type"] as? String) != "text"
        case "modalities": return ((value as? [Any])?.compactMap { $0 as? String }) != ["text"]
        case "logit_bias": return !((value as? [String: Any])?.isEmpty ?? false)
        default: return true
        }
    }

    private static func decodeMessages(_ value: Any?, limits: ServerLimits) throws(APIError) -> [ServedMessage] {
        guard let list = value as? [Any], !list.isEmpty else {
            throw .invalidMessages("messages must be a non-empty array.")
        }
        guard list.count <= limits.maxMessages else {
            throw .invalidMessages("At most \(limits.maxMessages) messages are accepted.")
        }
        var messages: [ServedMessage] = []
        messages.reserveCapacity(list.count)
        for entry in list {
            messages.append(try message(entry, limits: limits))
        }
        guard messages.contains(where: { $0.role == .user }) else {
            throw .invalidMessages("At least one user message is required.")
        }
        return messages
    }

    private static func message(_ entry: Any, limits: ServerLimits) throws(APIError) -> ServedMessage {
        guard let fields = entry as? [String: Any], let roleName = fields["role"] as? String else {
            throw .invalidMessages("Each message needs a role and content.")
        }
        guard let role = ServedRole(rawValue: roleName) else {
            if roleName == "tool" || roleName == "developer" || roleName == "function" {
                throw .unsupported("messages.role")
            }
            throw .invalidMessages("Unknown message role.")
        }
        let content = try text(of: fields["content"], role: role)
        guard content.count <= limits.maxCharactersPerMessage else {
            throw .invalidMessages("A message exceeds \(limits.maxCharactersPerMessage) characters.")
        }
        return ServedMessage(role: role, content: content)
    }

    private static func text(of content: Any?, role: ServedRole) throws(APIError) -> String {
        if let text = content as? String { return text }
        if role == .assistant, content == nil || content is NSNull { return "" }
        guard let parts = content as? [Any] else { throw .invalidMessages("Message content must be text.") }
        var pieces: [String] = []
        for part in parts {
            pieces.append(try textPart(part))
        }
        return pieces.joined()
    }

    private static func textPart(_ part: Any) throws(APIError) -> String {
        guard let fields = part as? [String: Any], let type = fields["type"] as? String else {
            throw .invalidMessages("Content parts need a type.")
        }
        guard type == "text" else { throw .unsupported("messages.content.\(WireJSON.printable(type, limit: 32))") }
        guard let text = fields["text"] as? String else { throw .invalidMessages("Text parts need text.") }
        return text
    }

    private static func flag(_ value: Any?, name: String) throws(APIError) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        guard isBool(value), let flag = value as? Bool else { throw .invalidJSON("\(name) must be a boolean.", param: name) }
        return flag
    }

    private static func integer(_ value: Any?, name: String) throws(APIError) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard !isBool(value), let number = value as? NSNumber, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) < 1e9 else {
            throw .invalidJSON("\(name) must be an integer.", param: name)
        }
        return number.intValue
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Nesting depth of a JSON document, counted on the raw bytes so a hostile body never reaches the decoder.
enum JSONDepth {
    static func exceeds(_ data: Data, limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return true }
            case 0x5D, 0x7D: depth -= 1
            default: break
            }
        }
        return false
    }
}

/// Response bodies. Keys are sorted so output is byte-stable.
enum ChatCompletionEncoder {
    /// `reasoning_content` appears only when the model reasoned, so answers without reasoning keep their old bytes;
    /// the `tonamox` member only when the reasoning budget closed the block (`reasoningCut`, its reasoning tokens).
    static func completion(id: String, created: Int, model: String, text: String, reasoning: String = "",
                           finish: FinishReason, usage: ServedUsage?, reasoningCut: Int? = nil) -> Data {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        var object: [String: Any] = [
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": message, "finish_reason": finish.rawValue]],
        ]
        if let usage { object["usage"] = usageObject(usage) }
        if let reasoningCut { object["tonamox"] = tonamoxObject(reasoningCut: reasoningCut) }
        return WireJSON.data(object)
    }

    static func chunk(id: String, created: Int, model: String, delta: [String: Any], finish: FinishReason?,
                      reasoningCut: Int? = nil) -> Data {
        let choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish?.rawValue ?? NSNull()]
        var object: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                                     "choices": [choice]]
        if let reasoningCut { object["tonamox"] = tonamoxObject(reasoningCut: reasoningCut) }
        return event(object)
    }

    private static func tonamoxObject(reasoningCut tokens: Int) -> [String: Any] {
        ["reasoning": ["cut": true, "tokens": tokens] as [String: Any]]
    }

    static func usageChunk(id: String, created: Int, model: String, usage: ServedUsage) -> Data {
        event(["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [Any](),
               "usage": usageObject(usage)])
    }

    static func errorEvent(_ error: APIError) -> Data {
        frame(error.body)
    }

    static let done = Data("data: [DONE]\n\n".utf8)
    static let keepAlive = Data(": keep-alive\n\n".utf8)

    static func models(_ infos: [ServedModelInfo], created: Int) -> Data {
        WireJSON.data(["object": "list", "data": infos.map { modelObject($0, created: created) }])
    }

    static func model(_ info: ServedModelInfo, created: Int) -> Data {
        WireJSON.data(modelObject(info, created: created))
    }

    private static func modelObject(_ info: ServedModelInfo, created: Int) -> [String: Any] {
        var tonamox: [String: Any] = ["egress": egressObject(info.egress)]
        if let context = info.contextLength { tonamox["context_length"] = context }
        return ["id": info.id, "object": "model", "created": created, "owned_by": info.ownedBy, "tonamox": tonamox]
    }

    private static func egressObject(_ egress: ServedModelEgress) -> [String: Any] {
        switch egress {
        case .onDevice: ["kind": "on_device"]
        case .localNetwork(let host): ["kind": "local_network", "host": host]
        case .cloud(let provider, let retention): ["kind": "cloud", "provider": provider, "retention": retention]
        }
    }

    private static func usageObject(_ usage: ServedUsage) -> [String: Any] {
        ["prompt_tokens": usage.promptTokens, "completion_tokens": usage.completionTokens,
         "total_tokens": usage.promptTokens + usage.completionTokens]
    }

    private static func event(_ object: [String: Any]) -> Data {
        frame(WireJSON.data(object))
    }

    private static func frame(_ json: Data) -> Data {
        var bytes = Data("data: ".utf8)
        bytes.append(json)
        bytes.append(contentsOf: [0x0A, 0x0A])
        return bytes
    }
}
