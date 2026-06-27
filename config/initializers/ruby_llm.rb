# Configure RubyLLM to talk to a local LM Studio server.
#
# LM Studio exposes an OpenAI-compatible API (default: http://localhost:1234/v1),
# so we use RubyLLM's :openai provider but point it at the local base URL.
#
# Override via environment variables if needed:
#   LMSTUDIO_URL=http://localhost:1234/v1
#   LMSTUDIO_MODEL=google/gemma-3n-e4b   (the model id loaded in LM Studio)
RubyLLM.configure do |config|
  config.openai_api_base = ENV.fetch("LMSTUDIO_URL", "http://localhost:1234/v1")

  # LM Studio ignores the key, but RubyLLM requires a non-nil value.
  config.openai_api_key = ENV.fetch("LMSTUDIO_API_KEY", "lm-studio")

  # Gemma's chat template handles system prompts fine through LM Studio;
  # keep the default behaviour but be tolerant of slow local generations.
  config.request_timeout = ENV.fetch("LMSTUDIO_TIMEOUT", "180").to_i
  config.max_retries = 1

  config.log_level = :warn
end
