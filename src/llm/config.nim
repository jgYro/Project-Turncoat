## Server-owned inference settings. Credentials never enter browser responses.
import std/[os, strutils, uri, json]

const
  DefaultLlmModel* = "granite4.1:8b"
  MaxChatMessages* = 24
  MaxMessageBytes* = 16_000
  MaxConversationBytes* = 64_000
  MaxContextBytes* = 48_000
  MaxChatRequestBytes* = 128_000
  MaxLlmResponseBytes* = 1_000_000

type LlmConfig* = object
  baseUrl*, model*, apiKey*: string
  timeoutMs*, maxTokens*, maxConcurrent*: int

proc validate*(config: LlmConfig) =
  let url = parseUri(config.baseUrl)
  if url.scheme notin ["http", "https"] or url.hostname.len == 0 or
      url.username.len > 0 or url.password.len > 0 or url.query.len > 0 or
      url.anchor.len > 0 or config.baseUrl.contains({'\r', '\n', '\0'}):
    raise newException(ValueError, "TURNCOAT_LLM_BASE_URL must be an HTTP(S) base URL without credentials, query, or fragment.")
  if config.model.strip.len == 0 or config.model.len > 200 or config.model.contains({'\r', '\n', '\0'}):
    raise newException(ValueError, "TURNCOAT_LLM_MODEL must be a nonempty model identifier of at most 200 bytes.")
  if config.apiKey.contains({'\r', '\n', '\0'}):
    raise newException(ValueError, "TURNCOAT_LLM_API_KEY contains invalid characters.")
  if config.timeoutMs < 1 or config.timeoutMs > 600_000 or
      config.maxTokens < 1 or config.maxTokens > 8192 or
      config.maxConcurrent < 1 or config.maxConcurrent > 4:
    raise newException(ValueError, "LLM timeout must be 1..600000 ms, max tokens 1..8192, and concurrency 1..4.")

proc defaultLlmConfig*(): LlmConfig =
  LlmConfig(baseUrl: "http://127.0.0.1:11434/v1", model: DefaultLlmModel,
    timeoutMs: 120_000, maxTokens: 2048, maxConcurrent: 2)

proc loadLlmConfig*(): LlmConfig =
  result = defaultLlmConfig()
  result.baseUrl = getEnv("TURNCOAT_LLM_BASE_URL", result.baseUrl).strip.strip(leading = false, chars = {'/'})
  result.model = getEnv("TURNCOAT_LLM_MODEL", result.model).strip
  result.apiKey = getEnv("TURNCOAT_LLM_API_KEY")
  try:
    result.timeoutMs = parseInt(getEnv("TURNCOAT_LLM_TIMEOUT_MS", $result.timeoutMs))
    result.maxTokens = parseInt(getEnv("TURNCOAT_LLM_MAX_TOKENS", $result.maxTokens))
    result.maxConcurrent = parseInt(getEnv("TURNCOAT_LLM_CONCURRENCY", $result.maxConcurrent))
  except ValueError:
    raise newException(ValueError, "LLM timeout, max tokens, and concurrency must be integers.")
  result.validate()

proc publicConfig*(config: LlmConfig): JsonNode =
  %*{"baseUrl": config.baseUrl, "model": config.model,
    "apiKeyConfigured": config.apiKey.len > 0, "timeoutMs": config.timeoutMs,
    "maxTokens": config.maxTokens, "maxMessages": MaxChatMessages,
    "maxMessageBytes": MaxMessageBytes, "maxConversationBytes": MaxConversationBytes,
    "maxContextBytes": MaxContextBytes}
