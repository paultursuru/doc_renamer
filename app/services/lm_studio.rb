# Small helper around the local LM Studio server.
module LmStudio
  module_function

  def base_url
    ENV.fetch("LMSTUDIO_URL", "http://localhost:1234/v1")
  end

  def api_key
    ENV.fetch("LMSTUDIO_API_KEY", "lm-studio")
  end

  # The model id to use. If LMSTUDIO_MODEL isn't set, auto-detect the first
  # (non-embedding) model loaded in LM Studio so the app "just works".
  def model
    pick_model(available_models)
  end

  # One-shot status built from a SINGLE call to LM Studio (avoids hammering
  # /v1/models multiple times per request).
  def status
    models = available_models
    { online: models.any?, models: models, model: pick_model(models) }
  end

  def pick_model(models)
    ENV["LMSTUDIO_MODEL"].presence ||
      models.find { |id| !id.to_s.match?(/embed/i) } ||
      models.first ||
      "google/gemma-4-e4b"
  end

  # Returns the list of model ids loaded in LM Studio, or [] if unreachable.
  def available_models
    uri = URI.join(base_url.chomp("/") + "/", "models")
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 5) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{api_key}"
      http.request(req)
    end
    return [] unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body).fetch("data", []).map { |m| m["id"] }.compact
  rescue StandardError
    []
  end

  def online?
    available_models.any?
  end
end
