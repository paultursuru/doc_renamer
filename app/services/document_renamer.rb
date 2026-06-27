# Asks the local LLM (via LM Studio) for a clear, descriptive filename.
# Text documents are renamed from an extracted excerpt; images are renamed by
# letting the (multimodal) model look at them directly.
class DocumentRenamer
  class LlmUnavailable < StandardError; end

  MAX_NAME_LENGTH = 80

  SYSTEM_PROMPT = <<~PROMPT.freeze
    Tu es un assistant qui renomme des documents de façon claire et concise.
    À partir du contenu et du nom d'origine d'un fichier, propose UN SEUL nom
    de fichier court, descriptif et professionnel, en français.

    Règles strictes :
    - Réponds UNIQUEMENT par le nom proposé, rien d'autre.
    - N'inclus PAS l'extension du fichier.
    - Pas de guillemets, pas de phrase, pas d'explication.
    - Utilise des mots séparés par des underscores (snake_case).
    - Si tu identifies une date pertinente, mets-la au format AAAA-MM-JJ au début.
    - Maximum 8 mots.
  PROMPT

  def initialize(model: LmStudio.model)
    @model = model
  end

  # Returns a sanitized base name (without extension).
  # `file_path` is the raw stored file (used for the vision path on images).
  def propose_name(original_name:, text: nil, file_path: nil)
    base = File.basename(original_name, ".*")

    raw =
      if DocumentTextExtractor.image?(original_name) && file_path
        ask_about_image(base, file_path)
      else
        ask_about_text(base, text)
      end

    sanitize(raw).presence || sanitize(base).presence || "document"
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

    chat.ask(prompt).content.to_s
  rescue *CONNECTION_ERRORS => e
    raise LlmUnavailable, e.message
  end

  def ask_about_image(base, file_path)
    prompt = <<~MSG
      Cette image est un document (capture d'écran, photo ou scan) nommé « #{base} ».
      Observe son contenu : type de document, texte visible, éventuelle date.
      Propose le nouveau nom de fichier.
    MSG

    chat.ask(prompt, with: file_path).content.to_s
  rescue *CONNECTION_ERRORS => e
    raise LlmUnavailable, e.message
  rescue StandardError
    # Vision unsupported/failed for this particular image: keep the original
    # name rather than failing the whole batch.
    base
  end

  CONNECTION_ERRORS = [Faraday::ConnectionFailed, Errno::ECONNREFUSED, Errno::ECONNRESET].freeze

  def chat
    chat = RubyLLM.chat(model: @model, provider: :openai, assume_model_exists: true)
    chat.with_temperature(0.2)
    chat.with_instructions(SYSTEM_PROMPT)
    chat
  end

  # Turn the model's answer into a safe filename component.
  def sanitize(name)
    name = name.to_s.strip
    # The model sometimes wraps the answer or adds a label; keep the last line.
    name = name.lines.map(&:strip).reject(&:empty?).last.to_s
    name = name.sub(/\A(nom|filename|fichier)\s*[:\-]\s*/i, "")
    name = name.delete('"').delete("'").delete("`")
    name = name.unicode_normalize(:nfkd).encode("ASCII", replace: "").encode("UTF-8")
    name = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
    name[0, MAX_NAME_LENGTH].sub(/_\z/, "")
  end
end
