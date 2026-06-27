require "securerandom"
require "json"

class DocumentsController < ApplicationController
  # Uploads come from a fetch() call with the CSRF token in the header.
  protect_from_forgery with: :exception

  def index
    st = LmStudio.status
    @model = st[:model]
    @online = st[:online]
  end

  # Health check polled by the UI (single call to LM Studio).
  def status
    render json: LmStudio.status
  end

  # POST /rename — receives one or more files, returns proposed names.
  def rename
    files = Array(params[:files]).reject(&:blank?)
    return render(json: { error: "Aucun fichier reçu." }, status: :unprocessable_entity) if files.empty?

    renamer = DocumentRenamer.new
    results = []

    files.each do |upload|
      id = SecureRandom.uuid
      original = sanitize_basename(upload.original_filename)
      ext = File.extname(original)
      stored = work_dir.join(id)

      File.binwrite(stored, upload.read)

      text = DocumentTextExtractor.extract(path: stored.to_s, original_name: original)
      result = renamer.propose_name(original_name: original, text: text, file_path: stored.to_s)
      proposed = "#{result.name}#{ext}"

      manifest[id] = {
        "original" => original, "ext" => ext, "proposed" => proposed,
        "status" => result.status, "message" => result.message
      }
      results << {
        id: id, original: original, proposed: proposed,
        status: result.status, message: result.message
      }
    end

    save_manifest
    render json: { results: results }
  rescue DocumentRenamer::LlmUnavailable => e
    render json: { error: "LM Studio n'a pas répondu (serveur arrêté ou génération trop lente). Vérifie qu'il tourne (onglet Developer) puis réessaie.", detail: e.message },
           status: :service_unavailable
  end

  # GET /download/:id?name=... — single renamed file.
  def download
    entry = manifest[params[:id]]
    return head(:not_found) unless entry

    path = work_dir.join(params[:id])
    return head(:not_found) unless File.exist?(path)

    send_file path, filename: final_name(params[:name], entry), disposition: "attachment"
  end

  # POST /download_all — zip of all renamed files. Body: { names: { id => name } }
  def download_all
    names = params.fetch(:names, {}).to_unsafe_h
    return head(:not_found) if manifest.empty?

    require "zip"
    buffer = Zip::OutputStream.write_buffer do |zip|
      used = Hash.new(0)
      manifest.each do |id, entry|
        path = work_dir.join(id)
        next unless File.exist?(path)

        name = dedupe(final_name(names[id], entry), used)
        zip.put_next_entry(name)
        zip.write(File.binread(path))
      end
    end
    buffer.rewind

    send_data buffer.read, filename: "documents_renommes.zip", type: "application/zip", disposition: "attachment"
  end

  private

  def final_name(requested, entry)
    candidate = requested.to_s.strip
    candidate = entry["proposed"] if candidate.empty?
    base = File.basename(candidate, ".*")
    base = sanitize_basename(base)
    base = "document" if base.empty?
    "#{base}#{entry['ext']}"
  end

  # Avoid clobbering when two files end up with the same name in the zip.
  def dedupe(name, used)
    ext = File.extname(name)
    base = File.basename(name, ".*")
    used[name] += 1
    return name if used[name] == 1

    "#{base}_#{used[name] - 1}#{ext}"
  end

  def sanitize_basename(name)
    File.basename(name.to_s).gsub(%r{[/\\]}, "_").gsub(/[\x00-\x1f]/, "").strip
  end

  def session_token
    session[:doc_token] ||= SecureRandom.hex(16)
  end

  def work_dir
    @work_dir ||= Rails.root.join("tmp", "doc_renamer", session_token).tap do |dir|
      FileUtils.mkdir_p(dir)
    end
  end

  def manifest_path
    work_dir.join("manifest.json")
  end

  def manifest
    @manifest ||= File.exist?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}
  end

  def save_manifest
    File.write(manifest_path, JSON.pretty_generate(manifest))
  end
end
