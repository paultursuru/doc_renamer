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

  PLAIN_EXTENSIONS = %w[.txt .md .markdown .csv .tsv .json .xml .html .htm .log .yml .yaml].freeze
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
      when ".xlsx"           then from_xlsx(path)
      when ".xls"            then from_xls(path)
      when ".doc", ".rtf"    then from_textutil(path)
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

  # A .xlsx is also a zip. The cell text lives in xl/sharedStrings.xml (the
  # string table) and as inline values in the worksheets. We only pull the
  # contents of <t> (text) and <v> (value) elements to skip the XML noise.
  def from_xlsx(path)
    require "zip"
    parts = []
    Zip::File.open(path) do |zip|
      shared = zip.find_entry("xl/sharedStrings.xml")
      parts << shared.get_input_stream.read if shared
      zip.glob("xl/worksheets/*.xml").each { |sheet| parts << sheet.get_input_stream.read }
    end
    return nil if parts.empty?

    parts.join(" ").scan(%r{<(?:t|v)[^>]*>(.*?)</(?:t|v)>}m).flatten.join(" ")
  end

  # Legacy binary Excel (.xls / BIFF). Read each cell, row by row, until we have
  # enough for a name. Spreadsheet detects the format from the content, so the
  # extension-less stored file is fine.
  def from_xls(path)
    require "spreadsheet"
    Spreadsheet.client_encoding = "UTF-8"
    out = +""
    Spreadsheet.open(path).worksheets.each do |sheet|
      sheet.each do |row|
        out << row.to_a.compact.join(" ") << "\n"
        break if out.length >= MAX_CHARS
      end
      break if out.length >= MAX_CHARS
    end
    out
  end

  # Legacy Word (.doc, OLE binary) and .rtf. macOS `textutil` converts both to
  # plain text and sniffs the format from the content (works without a file
  # extension). On a non-macOS host the command is missing and this returns nil
  # (→ the file falls back to "unreadable"), which is fine for a local tool.
  def from_textutil(path)
    require "open3"
    out, status = Open3.capture2("textutil", "-convert", "txt", "-stdout", path)
    status.success? ? out : nil
  rescue Errno::ENOENT
    nil
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
