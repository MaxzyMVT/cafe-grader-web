import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.interval = setInterval(() => {
      this.refresh()
    }, 30000)
  }

  disconnect() {
    clearInterval(this.interval)
  }

  refresh() {
    const frame = document.getElementById("scoreboard")
    if (frame) {
      frame.reload()
    } else {
      window.location.reload()
    }
  }
}

