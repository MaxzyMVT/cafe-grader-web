import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Set 30s auto-refresh on the scoreboard page.
    if (this.element.id === "scoreboard-container") {
      this.interval = setInterval(() => {
        this.refresh() 
      }, 30000)
    }
  }

  disconnect() {
    if (this.interval) {
      clearInterval(this.interval)
    }
  }

  async refresh() {
    if (this.element.id === "scoreboard-container") {
      try {
        const response = await fetch(window.location.href, {
          headers: { 'X-Requested-With': 'XMLHttpRequest' }
        })
        if (!response.ok) return
        const htmlText = await response.text()
        
        const parser = new DOMParser()
        const newDoc = parser.parseFromString(htmlText, 'text/html')
        const newContainer = newDoc.getElementById('scoreboard-container')
        
        if (newContainer) {
          // Save inner scrollable element scroll positions
          const scrollPositions = []
          const currentScrollables = this.element.querySelectorAll('.table-responsive, [style*="overflow"]')
          currentScrollables.forEach((el, index) => {
            scrollPositions.push({
              index: index,
              scrollTop: el.scrollTop,
              scrollLeft: el.scrollLeft
            })
          })
          
          // Save main window scroll position
          const winScrollTop = window.scrollY
          const winScrollLeft = window.scrollX
          
          // Inject style to force instant scrolling during restoration.
          // This prevents smooth scroll animations from triggering during restoration
          // when CSS scroll-behavior: smooth is enabled.
          const disableSmoothScrollStyle = document.createElement('style')
          disableSmoothScrollStyle.textContent = '* { scroll-behavior: auto !important; }'
          document.head.appendChild(disableSmoothScrollStyle)
          
          // Replace content
          this.element.innerHTML = newContainer.innerHTML
          
          // Restore inner scrollable element scroll positions
          const newScrollables = this.element.querySelectorAll('.table-responsive, [style*="overflow"]')
          scrollPositions.forEach(pos => {
            if (newScrollables[pos.index]) {
              newScrollables[pos.index].scrollTop = pos.scrollTop
              newScrollables[pos.index].scrollLeft = pos.scrollLeft
            }
          })
          
          // Restore main window scroll position
          window.scrollTo(winScrollLeft, winScrollTop)

          // Remove the style block to restore normal smooth scrolling behavior for user interactions
          disableSmoothScrollStyle.remove()
        }
      } catch (e) {
        console.error('Auto-refresh failed:', e)
      }
    }
  }
}
