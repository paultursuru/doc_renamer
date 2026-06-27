# Extracts a short text excerpt from an uploaded document so the LLM has
# enough context to propose a meaningful filename. Everything stays local.
#
# Images return nil here on purpose — they're handled by the vision path in
# DocumentRenamer (the model "looks" at the picture instead of reading bytes).
module DocumentTextExtractor
  module_function

  # Excerpt length fed to the LLM. Kept small on purpose: a local model spends
  # most of its time on prompt processing, so a 4k-char excerpt makes naming a
  # PDF time out. ~1.5k chars (header / first page) is plenty to name a document.
  MAX_CHARS = 1_500

  PLAIN_EXTENSIONS = %w[.txt .md .markdown .csv .tsv .json .xml .html .htm .log .rtf .yml .yaml].freeze
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif .bmp .heic .heif .tiff].freeze

  def image?(name)
    IMAGE_EXTENSIONS.include?(File.extname(name.to_s).downcase)
  end

  # `path` is the raw stored file, `original_name` is the user's filename.
  def extract(path:, original_name:)
    ext = File.extname(original_name).downcase
    return nil if image?(original_name)

    text =
      case ext
      when ".pdf"            then from_pdf(path)
      when ".docx"           then from_docx(path)
      when *PLAIN_EXTENSIONS then from_text(path)
      else from_unknown(path) # best effort, but never on binary
      end

    clean(text)
  rescue StandardError
    nil
  end

  def from_pdf(path)
    require "pdf/reader"
    out = +""
    PDF::Reader.new(path).pages.each do |page|
      out << page.text << "\n"
      break if out.length >= MAX_CHARS
    end
    out
  end

  # A .docx is a zip; the body lives in word/document.xml.
  def from_docx(path)
    require "zip"
    xml = nil
    Zip::File.open(path) do |zip|
      entry = zip.find_entry("word/document.xml")
      xml = entry&.get_input_stream&.read
    end
    return nil unless xml

    xml.gsub(%r{</w:p>}, "\n").gsub(/<[^>]+>/, " ")
  end

  def from_text(path)
    File.binread(path, MAX_CHARS * 2)
  end

  # Unknown extension: read a chunk but bail out if it looks binary, so we
  # never feed raw bytes (e.g. an unrecognised image) into the prompt.
  def from_unknown(path)
    raw = File.binread(path, MAX_CHARS * 2)
    binary?(raw) ? nil : raw
  end

  # Heuristic: a NUL byte in the first KB almost always means binary content.
  def binary?(bytes)
    return false if bytes.nil? || bytes.empty?

    bytes.byteslice(0, 1024).to_s.include?("\x00".b)
  end

  def clean(text)
    return nil if text.nil?

    # Force a known encoding and drop any invalid sequences before we ever
    # interpolate this into a UTF-8 prompt string.
    text = text.to_s.dup.force_encoding("UTF-8").scrub(" ")
    text = text.gsub(/[ \t]+/, " ").gsub(/\n{2,}/, "\n").strip
    return nil if text.empty?

    text[0, MAX_CHARS]
  end
end
