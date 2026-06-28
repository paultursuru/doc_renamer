require "securerandom"

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

  # POST /rename — store a CHUNK of uploaded files. The first call (no batch_id)
  # creates the batch; later calls append to it. Files are uploaded in small
  # chunks so a single request never holds hundreds of multipart tempfiles open
  # at once (which exhausts the process's file descriptors). No job is enqueued
  # here — the client calls #start once every chunk has been uploaded.
  def rename
    files = Array(params[:files]).reject(&:blank?)
    return render(json: { error: "Aucun fichier reçu." }, status: :unprocessable_entity) if files.empty?

    if params[:batch_id].present?
      batch = current_batch
      return render(json: { error: "Lot introuvable." }, status: :not_found) unless batch
    else
      batch = RenameBatch.create!(session_token: session_token)
    end

    files.each do |upload|
      stored_id = SecureRandom.uuid
      original = sanitize_basename(upload.original_filename)
      File.binwrite(work_dir.join(stored_id), upload.read)

      batch.items.create!(stored_id: stored_id, original: original, ext: File.extname(original))
    end

    render json: { batch_id: batch.id, items: batch.items.order(:created_at).map(&:as_payload) }
  end

  # POST /rename/:batch_id/start — all files uploaded; enqueue one rename job per
  # file. The LLM work happens in the background (see RenameFileJob); the UI then
  # polls #rename_status. Idempotent: a second call won't re-enqueue.
  def start
    batch = current_batch
    return head(:not_found) unless batch
    return render(json: { error: "Aucun fichier à traiter." }, status: :unprocessable_entity) if batch.items.empty?

    if batch.good_job_batch_id.blank?
      gj_batch = GoodJob::Batch.enqueue(on_finish: RenameReportJob, rename_batch_id: batch.id) do
        batch.items.where(state: "pending").each { |item| RenameFileJob.perform_later(item.id) }
      end
      batch.update!(good_job_batch_id: gj_batch.id)
    end

    render json: batch.progress.merge(items: batch.items.order(:created_at).map(&:as_payload))
  end

  # GET /rename/:batch_id/status — progress + per-file results for the UI.
  def rename_status
    batch = current_batch
    return head(:not_found) unless batch

    render json: batch.progress.merge(items: batch.items.order(:created_at).map(&:as_payload))
  end

  # GET /download/:id?name=... — single renamed file (id is a RenameItem id).
  def download
    item = owned_item(params[:id])
    return head(:not_found) unless item && File.exist?(item.stored_path)

    send_file item.stored_path, filename: final_name(params[:name], item), disposition: "attachment"
  end

  # POST /download_all/:batch_id — zip of all renamed files in the batch.
  # Body: { names: { item_id => name } }
  def download_all
    batch = current_batch
    return head(:not_found) unless batch

    names = params.fetch(:names, {}).to_unsafe_h
    require "zip"
    buffer = Zip::OutputStream.write_buffer do |zip|
      used = Hash.new(0)
      batch.items.order(:created_at).each do |item|
        next unless File.exist?(item.stored_path)

        name = dedupe(final_name(names[item.id], item), used)
        zip.put_next_entry(name)
        zip.write(File.binread(item.stored_path))
      end
    end
    buffer.rewind

    send_data buffer.read, filename: "documents_renommes.zip", type: "application/zip", disposition: "attachment"
  end

  private

  def current_batch
    RenameBatch.find_by(id: params[:batch_id], session_token: session_token)
  end

  # Look up an item but only within the current session's batches.
  def owned_item(id)
    RenameItem.joins(:rename_batch)
              .find_by(id: id, rename_batches: { session_token: session_token })
  end

  def final_name(requested, item)
    candidate = requested.to_s.strip
    candidate = item.proposed.to_s if candidate.empty?
    base = sanitize_basename(File.basename(candidate, ".*"))
    base = "document" if base.empty?
    "#{base}#{item.ext}"
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
end
