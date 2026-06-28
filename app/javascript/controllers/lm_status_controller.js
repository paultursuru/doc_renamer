import { Controller } from "@hotwired/stimulus"

// Polls LM Studio's health, but only while it's unreachable — as soon as it
// connects we stop so we don't spam its /v1/models log every few seconds.
export default class extends Controller {
  static targets = ["label"]

  connect() {
    // The server renders the initial state; only start polling if it's offline.
    if (!this.element.classList.contains("ok")) {
      this.timer = setInterval(() => this.poll(), 15000)
    }
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async poll() {
    try {
      const res = await fetch("status")
      const d = await res.json()
      this.element.classList.toggle("ok", d.online)
      this.element.classList.toggle("ko", !d.online)
      this.labelTarget.innerHTML = d.online
        ? `LM&nbsp;Studio connecté — modèle&nbsp;: <code>${this.escapeHtml(d.model)}</code>`
        : "LM&nbsp;Studio injoignable — démarre le serveur (onglet Developer)"
      if (d.online && this.timer) { clearInterval(this.timer); this.timer = null }
    } catch (_) { /* keep polling */ }
  }

  escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }
}
