import Foundation

// Taken from mlx-swift-lm 3.31.3 and llama.cpp b12407 (local LocalLLMClient 0.5.0 fork). When a pin moves,
// scripts/regen_pinned_runtimes.sh prints the new sets; ModelCompatibilityTests diffs the MLX ones.

/// Model types and architectures the pinned runtimes accept.
public enum PinnedRuntimes {

    public static let mlxSwiftLMVersion = "3.31.3"
    public static let llamaCppBuild = "b12407"

    /// `model_type` values `LLMModelFactory` can instantiate (text).
    public static let mlxLLMModelTypes: Set<String> = [
        "acereason", "afmoe", "apertus", "baichuan_m1", "bailing_moe", "bitnet", "cohere", "deepseek_v3",
        "ernie4_5", "exaone4", "falcon_h1", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4",
        "gemma4_text", "glm4", "glm4_moe", "glm4_moe_lite", "gpt_oss", "granite", "granitemoehybrid", "internlm2",
        "jamba_3b", "lfm2", "lfm2_moe", "lille-130m", "llama", "mimo", "mimo_v2_flash", "minicpm", "minimax",
        "mistral", "mistral3", "nanochat", "nemotron_h", "olmo2", "olmo3", "olmoe", "openelm", "phi", "phi3",
        "phimoe", "qwen2", "qwen3", "qwen3_5", "qwen3_5_moe", "qwen3_5_text", "qwen3_moe", "qwen3_next",
        "smollm3", "starcoder2",
    ]

    /// `model_type` values `VLMModelFactory` can instantiate (image + text).
    public static let mlxVLMModelTypes: Set<String> = [
        "fastvlm", "gemma3", "gemma4", "glm_ocr", "idefics3", "lfm2-vl", "lfm2_vl", "llava_qwen2", "mistral3",
        "paligemma", "pixtral", "qwen2_5_vl", "qwen2_vl", "qwen3_5", "qwen3_5_moe", "qwen3_vl", "smolvlm",
    ]

    /// Model types whose implementation hands `rope_scaling` / `rope_parameters` to `initializeRope`.
    static let mlxRopeModelTypes: Set<String> = [
        "afmoe", "apertus", "bailing_moe", "bitnet", "deepseek_v3", "ernie4_5", "exaone4", "falcon_h1", "gemma3",
        "gemma3_text", "gemma4", "gemma4_text", "glm4", "glm4_moe", "glm4_moe_lite", "granite", "granitemoehybrid",
        "llama", "mimo", "minicpm", "mistral", "mistral3", "olmo2", "olmo3", "olmoe", "qwen3_5", "qwen3_5_text",
        "qwen3_next",
    ]

    /// Rope types `initializeRope` accepts; anything else hits `fatalError("Unsupported RoPE type")`.
    static let mlxRopeTypes: Set<String> = [
        "default", "linear", "proportional", "llama3", "yarn", "deepseek_yarn", "telechat3-yarn", "longrope", "mrope",
    ]

    /// Architectures llama.cpp b12407 knows (`general.architecture`).
    public static let llamaCppArchitectures: Set<String> = [
        "llama", "llama4", "deci", "falcon", "grok", "gpt2", "gptj", "gptneox", "mpt", "baichuan", "starcoder",
        "refact", "bert", "modern-bert", "nomic-bert", "nomic-bert-moe", "neo-bert", "jina-bert-v2", "jina-bert-v3",
        "eurobert", "bloom", "stablelm", "qwen", "qwen2", "qwen2moe", "qwen2vl", "sensenova_u1", "qwen3", "flint",
        "qwen3moe", "clover_moe", "qwen3next", "qwen3vl", "qwen3vlmoe", "qwen35", "qwen35moe", "clef",
        "vllm-decision2", "qwen4exp", "phi2", "phi3", "phimoe", "plamo", "plamo2", "plamo3", "codeshell", "orion",
        "internlm2", "minicpm", "minicpm3", "gemma", "gemma2", "gemma3", "gemma3n", "gemma4", "gemma4-assistant",
        "gemma-embedding", "gemma-embedding2", "starcoder2", "mamba", "mamba2", "maple", "jamba", "falcon-h1",
        "xverse", "command-r", "cohere2", "cohere2moe", "dbrx", "olmo", "olmo2", "olmoe", "muse-glimmer", "muse-spark",
        "openelm", "arctic", "deepseek", "deepseek2", "deepseek2-ocr", "deepseek32", "deepseek4", "deepseek41",
        "xing4_0", "chatglm", "glm4", "glm4moe", "glm-dsa", "bitnet", "t5", "t5encoder", "jais", "jais2", "nemotron",
        "nemotron_h", "nemotron_h_moe", "metis16", "exaone", "exaone4", "exaone-moe", "rwkv6", "rwkv6qwen2", "rwkv7",
        "arwkv7", "granite", "granitemoe", "granitehybrid", "graniteswitch", "granite_swa", "chameleon",
        "wavtokenizer-dec", "plm", "bailingmoe", "bailingmoe2", "bailingmoe3", "dots1", "dots3note", "arcee", "afmoe",
        "laguna", "ernie4_5", "ernie4_5-moe", "hunyuan-moe", "hunyuan-dense", "hunyuan_vl", "hy_v3", "hy_v4",
        "smollm3", "gpt-oss", "lfm2", "lfm2moe", "lfm3", "dream", "smallthinker", "llada", "llada-moe", "seed_oss",
        "grovemoe", "apertus", "minimax-01", "hrm_text", "limite", "minimax-m2", "minimax-m3", "cogvlm", "rnd1",
        "pangu-embedded", "mistral3", "eagle3", "dflash", "mistral4", "mistral-large4", "paddleocr", "mimo2", "step35",
        "spark2_5", "llama-embed", "maincoder", "maion-coder", "kimi-linear", "kimi-k3", "kimi-k31", "glm5-next",
        "talkie", "mellum", "nanbeige", "qwen3tts", "pockettts", "k2-horizon", "beam", "kolibri1", "ricursive",
        "inkling2",
    ]

    /// b12407 architectures that load but cannot answer a chat prompt through LocalLLMClient, with the reason.
    static let llamaCppNonChatArchitectures: [String: String] = {
        let encoder = "an encoder / embedding model — it produces vectors, not text"
        let diffusion = "a diffusion language model — llama.cpp flags it `llm_arch_is_diffusion` and generates it "
            + "only through its diffusion example, not the autoregressive loop LocalLLMClient drives"
        let tts = "a text-to-speech model, not a chat model"
        // gemma4-assistant always needs `ctx_other` (the target's context); eagle3 and dflash need it when they ship
        // without their own embeddings or output head, as they usually do (src/llama-context.cpp).
        let draft = "a speculative-decoding draft head that runs only next to its target model"
        return [
            "bert": encoder, "modern-bert": encoder, "nomic-bert": encoder, "nomic-bert-moe": encoder,
            "neo-bert": encoder, "jina-bert-v2": encoder, "jina-bert-v3": encoder, "eurobert": encoder,
            "t5encoder": encoder, "gemma-embedding": encoder, "gemma-embedding2": encoder, "llama-embed": encoder,
            "t5": "an encoder-decoder model — it needs `llama_encode`, which LocalLLMClient never calls",
            "wavtokenizer-dec": "an audio-token decoder used by text-to-speech pipelines, not a chat model",
            "qwen3tts": tts, "pockettts": tts,
            "eagle3": draft, "dflash": draft, "gemma4-assistant": draft,
            "dream": diffusion, "llada": diffusion, "llada-moe": diffusion, "rnd1": diffusion,
        ]
    }()

    /// Architectures added to llama.cpp after b12407: first build that knows them. Empty until one is reported.
    static let laterLlamaCppArchitectures: [String: LlamaCppMilestone] = [:]
}

/// A llama.cpp release that changed what loads.
struct LlamaCppMilestone: Sendable, Equatable {
    let build: String
    let date: String
    let change: String
}
