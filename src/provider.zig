//! Provider yang bicara dialek OpenAI (`/chat/completions` dan `/models`).
//! Port 1:1 dari src/provider.rs.

const std = @import("std");

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    /// Nama env var API key. Kosong = tidak butuh key (provider lokal).
    key_env: []const u8,
    default_model: []const u8,
    /// Dipakai selama daftar model asli dari API belum (atau tidak bisa) diambil.
    fallback_models: []const []const u8,

    pub fn isCustom(self: *const Provider) bool {
        return std.mem.eql(u8, self.id, "custom");
    }

    /// Hugging Face Space (Gradio): "model"-nya adalah id Space, bukan nama model.
    pub fn isSpace(self: *const Provider) bool {
        return std.mem.eql(u8, self.id, "hfspace");
    }

    /// Yang harus diset user supaya provider ini siap dipakai.
    pub fn requirement(self: *const Provider) []const u8 {
        if (self.isCustom()) return "CLAUDIA_BASE_URL";
        if (self.isSpace()) return "HF_TOKEN dan id Space lewat /model";
        return self.key_env;
    }
};

pub const ALL = [_]Provider{
    .{ .id = "groq", .name = "Groq", .base_url = "https://api.groq.com/openai/v1", .key_env = "GROQ_API_KEY", .default_model = "llama-3.3-70b-versatile", .fallback_models = &.{ "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b", "openai/gpt-oss-20b" } },
    .{ .id = "openai", .name = "OpenAI", .base_url = "https://api.openai.com/v1", .key_env = "OPENAI_API_KEY", .default_model = "gpt-4o-mini", .fallback_models = &.{ "gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini" } },
    .{ .id = "anthropic", .name = "Anthropic", .base_url = "https://api.anthropic.com/v1", .key_env = "ANTHROPIC_API_KEY", .default_model = "claude-sonnet-5-5", .fallback_models = &.{ "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" } },
    .{ .id = "gemini", .name = "Google Gemini", .base_url = "https://generativelanguage.googleapis.com/v1beta/openai", .key_env = "GEMINI_API_KEY", .default_model = "gemini-2.5-flash", .fallback_models = &.{ "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash" } },
    .{ .id = "openrouter", .name = "OpenRouter", .base_url = "https://openrouter.ai/api/v1", .key_env = "OPENROUTER_API_KEY", .default_model = "meta-llama/llama-3.3-70b-instruct", .fallback_models = &.{ "meta-llama/llama-3.3-70b-instruct", "deepseek/deepseek-chat", "google/gemini-2.5-flash", "qwen/qwen-2.5-72b-instruct" } },
    .{ .id = "deepseek", .name = "DeepSeek", .base_url = "https://api.deepseek.com/v1", .key_env = "DEEPSEEK_API_KEY", .default_model = "deepseek-chat", .fallback_models = &.{ "deepseek-chat", "deepseek-reasoner" } },
    .{ .id = "mistral", .name = "Mistral", .base_url = "https://api.mistral.ai/v1", .key_env = "MISTRAL_API_KEY", .default_model = "mistral-small-latest", .fallback_models = &.{ "mistral-small-latest", "mistral-large-latest", "open-mistral-nemo" } },
    .{ .id = "xai", .name = "xAI (Grok)", .base_url = "https://api.x.ai/v1", .key_env = "XAI_API_KEY", .default_model = "grok-3-mini", .fallback_models = &.{ "grok-3-mini", "grok-3", "grok-4" } },
    .{ .id = "together", .name = "Together AI", .base_url = "https://api.together.xyz/v1", .key_env = "TOGETHER_API_KEY", .default_model = "meta-llama/Llama-3.3-70B-Instruct-Turbo", .fallback_models = &.{ "meta-llama/Llama-3.3-70B-Instruct-Turbo", "Qwen/Qwen2.5-72B-Instruct-Turbo", "deepseek-ai/DeepSeek-V3" } },
    .{ .id = "fireworks", .name = "Fireworks", .base_url = "https://api.fireworks.ai/inference/v1", .key_env = "FIREWORKS_API_KEY", .default_model = "accounts/fireworks/models/llama-v3p3-70b-instruct", .fallback_models = &.{ "accounts/fireworks/models/llama-v3p3-70b-instruct", "accounts/fireworks/models/deepseek-v3" } },
    .{ .id = "cerebras", .name = "Cerebras", .base_url = "https://api.cerebras.ai/v1", .key_env = "CEREBRAS_API_KEY", .default_model = "llama-3.3-70b", .fallback_models = &.{ "llama-3.3-70b", "llama3.1-8b" } },
    .{ .id = "sambanova", .name = "SambaNova", .base_url = "https://api.sambanova.ai/v1", .key_env = "SAMBANOVA_API_KEY", .default_model = "Meta-Llama-3.3-70B-Instruct", .fallback_models = &.{ "Meta-Llama-3.3-70B-Instruct", "DeepSeek-V3-0324" } },
    .{ .id = "nvidia", .name = "NVIDIA NIM", .base_url = "https://integrate.api.nvidia.com/v1", .key_env = "NVIDIA_API_KEY", .default_model = "meta/llama-3.3-70b-instruct", .fallback_models = &.{ "meta/llama-3.3-70b-instruct", "nvidia/llama-3.1-nemotron-70b-instruct" } },
    .{ .id = "deepinfra", .name = "DeepInfra", .base_url = "https://api.deepinfra.com/v1/openai", .key_env = "DEEPINFRA_API_KEY", .default_model = "meta-llama/Llama-3.3-70B-Instruct", .fallback_models = &.{ "meta-llama/Llama-3.3-70B-Instruct", "deepseek-ai/DeepSeek-V3" } },
    .{ .id = "hyperbolic", .name = "Hyperbolic", .base_url = "https://api.hyperbolic.xyz/v1", .key_env = "HYPERBOLIC_API_KEY", .default_model = "meta-llama/Llama-3.3-70B-Instruct", .fallback_models = &.{ "meta-llama/Llama-3.3-70B-Instruct", "deepseek-ai/DeepSeek-V3" } },
    .{ .id = "perplexity", .name = "Perplexity", .base_url = "https://api.perplexity.ai", .key_env = "PERPLEXITY_API_KEY", .default_model = "sonar", .fallback_models = &.{ "sonar", "sonar-pro", "sonar-reasoning", "sonar-reasoning-pro", "sonar-deep-research" } },
    .{ .id = "moonshot", .name = "Moonshot (Kimi)", .base_url = "https://api.moonshot.ai/v1", .key_env = "MOONSHOT_API_KEY", .default_model = "kimi-k2-0905-preview", .fallback_models = &.{ "kimi-k2-0905-preview", "moonshot-v1-8k" } },
    .{ .id = "zai", .name = "Z.ai (GLM)", .base_url = "https://api.z.ai/api/paas/v4", .key_env = "ZAI_API_KEY", .default_model = "glm-4.5", .fallback_models = &.{ "glm-4.5", "glm-4.5-air" } },
    .{ .id = "siliconflow", .name = "SiliconFlow", .base_url = "https://api.siliconflow.com/v1", .key_env = "SILICONFLOW_API_KEY", .default_model = "Qwen/Qwen2.5-72B-Instruct", .fallback_models = &.{ "Qwen/Qwen2.5-72B-Instruct", "deepseek-ai/DeepSeek-V3" } },
    .{ .id = "venice", .name = "Venice AI", .base_url = "https://api.venice.ai/api/v1", .key_env = "VENICE_API_KEY", .default_model = "venice-uncensored", .fallback_models = &.{"venice-uncensored"} },
    .{ .id = "huggingface", .name = "Hugging Face", .base_url = "https://router.huggingface.co/v1", .key_env = "HF_TOKEN", .default_model = "openai/gpt-oss-20b", .fallback_models = &.{ "openai/gpt-oss-20b", "openai/gpt-oss-120b", "meta-llama/Llama-3.3-70B-Instruct", "Qwen/Qwen3-235B-A22B" } },
    // Space Gradio, bukan dialek OpenAI: id Space (owner/nama) diisi lewat /model atau env HF_SPACE.
    .{ .id = "hfspace", .name = "HF Space", .base_url = "", .key_env = "HF_TOKEN", .default_model = "", .fallback_models = &.{} },
    .{ .id = "ollama", .name = "Ollama (lokal)", .base_url = "http://localhost:11434/v1", .key_env = "", .default_model = "llama3.2", .fallback_models = &.{ "llama3.2", "qwen2.5", "gemma3" } },
    .{ .id = "lmstudio", .name = "LM Studio (lokal)", .base_url = "http://localhost:1234/v1", .key_env = "", .default_model = "local-model", .fallback_models = &.{} },
    .{ .id = "custom", .name = "Custom (CLAUDIA_BASE_URL)", .base_url = "", .key_env = "CLAUDIA_API_KEY", .default_model = "gpt-4o-mini", .fallback_models = &.{} },
};

/// Cari indeks provider dari id atau nama (tanpa peduli huruf besar/kecil).
pub fn find(query: []const u8) ?usize {
    const q = std.mem.trim(u8, query, " \t\r\n");
    for (ALL, 0..) |p, i| {
        if (std.ascii.eqlIgnoreCase(p.id, q) or std.ascii.eqlIgnoreCase(p.name, q)) return i;
    }
    return null;
}

test "find is case insensitive" {
    try std.testing.expectEqual(@as(?usize, 0), find("GROQ"));
    try std.testing.expectEqual(@as(?usize, 1), find("openai"));
    try std.testing.expectEqual(@as(?usize, null), find("tidak-ada"));
}
