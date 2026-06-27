# Asks the local LLM (via LM Studio) for a clear, descriptive filename.
# Text documents are renamed from an extracted excerpt; images are renamed by
# letting the (multimodal) model look at them directly.
#
# The model answers with a structured payload (Schema::FilenameSchema): a
# proposed `name`, a `status` (ok / uncertain / unreadable) and an optional
# `message`. This makes failures explicit instead of a silent fallback.
class DocumentRenamer
  class LlmUnavailable < StandardError; end

  MAX_NAME_LENGTH = 80

  # Value returned by #propose_name. `name` is always a safe, non-empty basename
  # (without extension); `status`/`message` describe how confident the model was.
  Result = Data.define(:name, :status, :message)

  SYSTEM_PROMPT = <<~PROMPT.freeze
    Tu es un assistant qui renomme des documents de façon claire et concise, en
    français. À partir du contenu et du nom d'origine, propose un nom de fichier
    court, descriptif et professionnel : mots en snake_case, 8 mots maximum, sans
    extension, et si une date pertinente apparaît, place-la au format AAAA-MM-JJ
    au début.
  PROMPT

  def initialize(model: LmStudio.model)
    @model = model
  end

  # Returns a Result (name without extension + status + message).
  # `file_path` is the raw stored file (used for the vision path on images).
  def propose_name(original_name:, text: nil, file_path: nil)
    # The filename may carry odd bytes (ASCII-8BIT); scrub it to UTF-8 so it can
    # be safely interpolated into the prompt.
    base = File.basename(original_name, ".*").dup.force_encoding("UTF-8").scrub("")

    data =
      if DocumentTextExtractor.image?(original_name) && file_path
        ask_about_image(base, file_path)
      else
        ask_about_text(base, text)
      end

    build_result(data, base)
  end

  private

  def ask_about_text(base, text)
    excerpt = text.presence || "(contenu non extractible)"

    prompt = <<~MSG
      Nom d'origine : #{base}

      Contenu du document (extrait) :
      ---
      #{excerpt}
      ---

      Propose le nouveau nom de fichier.
    MSG

    chat.with_schema(Schema::FilenameSchema).ask(prompt).content
  rescue *CONNECTION_ERRORS => e
    raise LlmUnavailable, e.message
  end

  def ask_about_image(base, file_path)
    prompt = <<~MSG
      Cette image est un document (capture d'écran, photo ou scan) nommé « #{base} ».
      Observe son contenu : type de document, texte visible, éventuelle date.
      Propose le nouveau nom de fichier.
    MSG

    chat.with_schema(Schema::FilenameSchema).ask(prompt, with: file_path).content
  rescue *CONNECTION_ERRORS => e
    raise LlmUnavailable, e.message
  rescue StandardError => e
    # Vision unsupported/failed for this particular image: surface it explicitly
    # rather than failing the whole batch.
    { "status" => "unreadable", "message" => "Analyse de l'image impossible : #{e.message}" }
  end

  CONNECTION_ERRORS = [Faraday::ConnectionFailed, Errno::ECONNREFUSED, Errno::ECONNRESET].freeze

  def chat
    chat = RubyLLM.chat(model: @model, provider: :openai, assume_model_exists: true)
    chat.with_temperature(0.2)
    chat.with_instructions(SYSTEM_PROMPT)
    chat
  end

  # Turn the model's (structured) answer into a Result with a safe filename.
  # `data` is the parsed Hash; if the schema couldn't be honored it may come back
  # as a String, which we treat as an uncertain answer.
  def build_result(data, base)
    structured = data.is_a?(Hash)
    data = {} unless structured

    name    = sanitize(data["name"]).presence
    status  = STATUSES.include?(data["status"]) ? data["status"] : nil
    message = data["message"].presence

    unless structured
      # JSON schema wasn't honored (content came back as a raw string).
      status ||= "uncertain"
      message ||= "Réponse du modèle non structurée."
    end

    if name.nil?
      # No usable name: fall back to the original, but never report "ok" — that
      # would be the silent fallback we're trying to get rid of.
      status = "uncertain" if status.nil? || status == "ok"
      name = sanitize(base).presence || "document"
    end

    status ||= "ok"

    Result.new(name: name, status: status, message: message)
  end

  STATUSES = %w[ok uncertain unreadable].freeze

  # Normalize a model-provided string into a safe filename component.
  # The model returns structured JSON, so we only need filesystem-safety here
  # (ASCII, snake_case, length) — no more heuristic parsing of free-form text.
  def sanitize(name)
    name = name.to_s.strip
    name = name.unicode_normalize(:nfkd).encode("ASCII", replace: "").encode("UTF-8")
    name = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
    name[0, MAX_NAME_LENGTH].to_s.sub(/_\z/, "")
  end
end
