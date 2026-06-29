import { Controller } from "@hotwired/stimulus"

// Drives the document renaming UI: drag & drop, upload, then polls the batch
// status endpoint so the progress bar and per-file badges update while the
// background jobs run. Replaces the old inline <script> block.
export default class extends Controller {
  static targets = [
    "dropzone", "fileInput", "list", "progress", "progressFill", "progressCount",
    "renameBtn", "downloadAllBtn", "clearBtn", "error"
  ]

  // Files are uploaded in small chunks so a single request never holds hundreds
  // of multipart tempfiles open at once (which exhausts the server's file
  // descriptors). 25 keeps each request light on FDs and memory.
  static CHUNK_SIZE = 25

  connect() {
    this.files = []        // File objects queued before renaming
    this.items = []        // { id, original, proposed, status, message, state }
    this.batchId = null
    this.pollTimer = null
    this.uploading = false
    this.csrf = document.querySelector('meta[name="csrf-token"]')?.content
    this.render()
  }

  disconnect() {
    this.stopPolling()
  }

  // --- Drag & drop ---
  openPicker() { this.fileInputTarget.click() }

  pickerKeydown(e) {
    if (e.key === "Enter" || e.key === " ") this.fileInputTarget.click()
  }

  inputChanged() {
    this.addFiles(this.fileInputTarget.files)
    this.fileInputTarget.value = ""
  }

  dragOver(e) { e.preventDefault(); this.dropzoneTarget.classList.add("drag") }
  dragLeave(e) { e.preventDefault(); this.dropzoneTarget.classList.remove("drag") }
  drop(e) {
    e.preventDefault()
    this.dropzoneTarget.classList.remove("drag")
    if (e.dataTransfer?.files?.length) this.addFiles(e.dataTransfer.files)
  }

  addFiles(fileList) {
    this.showError("")
    this.items = []
    this.batchId = null
    this.uploading = false
    this.stopPolling()
    this.files = this.files.concat(Array.from(fileList))
    this.render()
  }

  // --- Rename: upload files in chunks, start processing, then poll ---
  async rename() {
    if (!this.files.length) return
    this.showError("")
    this.uploading = true
    this.batchId = null
    this.items = []
    this.uploadTotal = this.files.length
    this.uploadDone = 0
    this.render()

    const queued = this.files
    const size = this.constructor.CHUNK_SIZE

    try {
      for (let i = 0; i < queued.length; i += size) {
        const chunk = queued.slice(i, i + size)
        const fd = new FormData()
        if (this.batchId) fd.append("batch_id", this.batchId)
        chunk.forEach((f) => fd.append("files[]", f))

        const res = await fetch("rename", { method: "POST", headers: { "X-CSRF-Token": this.csrf }, body: fd })
        const data = await res.json()
        if (!res.ok) throw new Error(data.error || "Erreur serveur.")
        this.batchId = data.batch_id
        this.items = data.items
        this.uploadDone = Math.min(i + size, queued.length)
        this.render()
      }

      // Everything uploaded: kick off the background jobs.
      const res = await fetch(`rename/${this.batchId}/start`, {
        method: "POST", headers: { "X-CSRF-Token": this.csrf }
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.error || "Erreur serveur.")
      this.items = data.items
      this.files = []
      this.uploading = false
      this.render()
      this.startPolling()
    } catch (err) {
      this.uploading = false
      this.showError(err.message)
      this.render()
    }
  }

  startPolling() {
    this.stopPolling()
    this.pollTimer = setInterval(() => this.poll(), 1000)
  }

  stopPolling() {
    if (this.pollTimer) { clearInterval(this.pollTimer); this.pollTimer = null }
  }

  async poll() {
    if (!this.batchId) return
    try {
      const res = await fetch(`rename/${this.batchId}/status`)
      if (!res.ok) return
      const data = await res.json()
      this.items = data.items
      this.finished = data.finished
      this.progressDone = data.done
      this.progressTotal = data.total
      if (data.finished) this.stopPolling()
      this.render()
    } catch (_) { /* transient: keep polling */ }
  }

  // --- Download a single file (uses the edited name) ---
  downloadOne(e) {
    e.preventDefault()
    const id = e.currentTarget.dataset.id
    const row = e.currentTarget.closest(".row")
    const item = this.items.find((i) => i.id === id)
    const ext = this.extOf(item.proposed)
    const base = row.querySelector("input.name")?.value.trim() || this.baseOf(item.proposed)
    window.location = `download/${id}?name=${encodeURIComponent(base + ext)}`
  }

  // --- Download all as a zip (POST with the edited names) ---
  downloadAll() {
    if (!this.batchId) return
    const form = document.createElement("form")
    form.method = "POST"
    form.action = `download_all/${this.batchId}`
    form.appendChild(this.hiddenField("authenticity_token", this.csrf))

    this.listTarget.querySelectorAll(".row").forEach((row) => {
      const id = row.dataset.id
      const item = this.items.find((i) => i.id === id)
      if (!item || !item.proposed) return
      const ext = this.extOf(item.proposed)
      const base = row.querySelector("input.name")?.value.trim() || this.baseOf(item.proposed)
      form.appendChild(this.hiddenField(`names[${id}]`, base + ext))
    })

    document.body.appendChild(form)
    form.submit()
    form.remove()
  }

  clear() {
    this.files = []
    this.items = []
    this.batchId = null
    this.uploading = false
    this.finished = false
    this.stopPolling()
    this.showError("")
    this.render()
  }

  // --- Rendering ---
  render() {
    const hasFiles = this.files.length > 0
    const hasItems = this.items.length > 0
    const processing = this.batchId && !this.finished && !this.uploading
    const showProgress = this.uploading || processing
    // Per-file rows are only useful once processing starts. While importing
    // (files queued, or uploading hundreds of them) they're just noise — the
    // count on the button + the progress bar are enough.
    const showList = hasItems && !this.uploading

    this.listTarget.hidden = !showList
    this.renameBtnTarget.disabled = !hasFiles || this.uploading || processing
    this.renameBtnTarget.innerHTML =
      this.uploading ? '<span class="spinner"></span> Envoi…'
        : processing ? '<span class="spinner"></span> Renommage en cours…'
          : hasFiles ? `✨ Renommer (${this.files.length})` : "✨ Renommer"
    this.clearBtnTarget.hidden = !(hasFiles || hasItems)

    // Download all only once the batch is finished.
    this.downloadAllBtnTarget.hidden = !(this.batchId && this.finished)

    this.renderProgress(showProgress)
    this.renderList(showList)
  }

  renderProgress(active) {
    this.progressTarget.hidden = !active
    if (!active) return

    let done, total, label
    if (this.uploading) {
      done = this.uploadDone || 0
      total = this.uploadTotal || this.files.length
      label = `Envoi ${done}/${total} fichiers…`
    } else {
      total = this.progressTotal || this.items.length
      done = this.progressDone || 0
      label = `${done}/${total} fichiers traités`
    }
    const pct = total ? Math.round((done / total) * 100) : 0
    this.progressFillTarget.style.width = `${pct}%`
    this.progressCountTarget.textContent = label
  }

  renderList(show) {
    this.listTarget.innerHTML = ""
    if (!show) return

    this.items.forEach((item) => this.listTarget.appendChild(this.itemRow(item)))
  }

  itemRow(item) {
    const row = document.createElement("div")
    row.className = "row"
    row.dataset.id = item.id

    const done = item.state === "done"
    const ext = this.extOf(item.proposed)
    const base = this.baseOf(item.proposed)

    const editor = done
      ? `<div class="new">
           <input class="name" type="text" value="${this.escapeHtml(base)}">
           <span class="ext">${this.escapeHtml(ext)}</span>
         </div>`
      : ""

    const action = done
      ? `<a class="dl" href="#" data-action="renamer#downloadOne" data-id="${this.escapeHtml(item.id)}">⬇️ Télécharger</a>`
      : this.stateBadge(item)

    row.innerHTML = `
      <div>
        <div class="orig">Original&nbsp;: ${this.escapeHtml(item.original)}</div>
        ${editor}
        ${done ? this.statusBadge(item) : ""}
      </div>
      ${action}`
    return row
  }

  // Badge for a not-yet-done file (pending / processing / error).
  stateBadge(item) {
    const labels = { pending: "en attente", processing: "en cours", error: "erreur" }
    const label = labels[item.state] || item.state
    const spinner = item.state === "processing" ? '<span class="spinner"></span> ' : ""
    const title = item.message ? ` title="${this.escapeHtml(item.message)}"` : ""
    return `<span class="badge ${item.state}"${title}>${spinner}${this.escapeHtml(label)}</span>`
  }

  // Small status badge under a done file (ok / uncertain / unreadable + tooltip).
  statusBadge(item) {
    if (!item.status || item.status === "ok") return ""
    const title = item.message ? ` title="${this.escapeHtml(item.message)}"` : ""
    return `<div class="new"><span class="badge ${this.escapeHtml(item.status)}"${title}>${this.escapeHtml(item.status)}</span></div>`
  }

  // --- Helpers ---
  hiddenField(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    return input
  }

  extOf(name) {
    if (!name) return ""
    const i = name.lastIndexOf(".")
    return i >= 0 ? name.slice(i) : ""
  }

  baseOf(name) {
    const ext = this.extOf(name)
    return ext ? name.slice(0, -ext.length) : (name || "")
  }

  showError(msg) {
    this.errorTarget.textContent = msg
    this.errorTarget.hidden = !msg
  }

  escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }
}
