require "ruby_llm/schema"

module Schema
  # Structured response the LLM must return when proposing a filename. Decoded as
  # JSON by LM Studio, which frees us from parsing free-form text and makes
  # failures explicit via `status` instead of a silent fallback.
  class FilenameSchema < RubyLLM::Schema
    string :name,
           description: "Nom de fichier proposé, en français, snake_case, sans extension. Vide si aucun nom fiable."
    string :status,
           enum: %w[ok uncertain unreadable],
           description: "ok = nom fiable ; uncertain = contenu trop pauvre/ambigu ; unreadable = contenu illisible."
    string :message,
           required: false,
           description: "Courte explication en français quand status n'est pas ok."
  end
end
