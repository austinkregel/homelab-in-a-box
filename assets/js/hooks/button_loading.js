// ButtonLoading — drives a button through root → gerund → past-tense states off
// LiveView's automatic loading-class lifecycle.
//
// While a phx-submit / phx-click round-trip is in flight LiveView adds a
// `phx-submit-loading` / `phx-click-loading` class to the element (and disables
// it). We watch for that class: on entry we show a spinner and swap the label to
// the gerund ("Saving"); on exit we briefly show the past tense ("Saved") before
// reverting to the root ("Save").
//
// All three forms are precomputed server-side (Homelab.Inflect) and provided via
// data attributes, so this hook has no NLP and no dependencies.

const LOADING_CLASS = /\bphx-(?:submit|click)-loading\b/
const SAVED_DURATION_MS = 1200

const ButtonLoading = {
  mounted() {
    this.root = this.el.dataset.labelRoot
    this.gerund = this.el.dataset.labelGerund
    this.past = this.el.dataset.labelPast
    this.labelEl = this.el.querySelector("[data-label]")
    this.spinnerEl = this.el.querySelector("[data-spinner]")
    this.loading = LOADING_CLASS.test(this.el.className)

    this.observer = new MutationObserver(() => this.syncState())
    this.observer.observe(this.el, {attributes: true, attributeFilter: ["class"]})
  },

  syncState() {
    const loading = LOADING_CLASS.test(this.el.className)
    if (loading === this.loading) return
    this.loading = loading

    if (loading) {
      this.clearSavedTimer()
      this.showSpinner(true)
      this.setLabel(this.gerund)
    } else {
      // Round-trip finished — flash the past tense, then revert.
      this.showSpinner(false)
      this.setLabel(this.past)
      this.savedTimer = setTimeout(() => this.setLabel(this.root), SAVED_DURATION_MS)
    }
  },

  setLabel(text) {
    if (this.labelEl && text) this.labelEl.textContent = text
  },

  showSpinner(show) {
    if (this.spinnerEl) this.spinnerEl.classList.toggle("hidden", !show)
  },

  clearSavedTimer() {
    if (this.savedTimer) {
      clearTimeout(this.savedTimer)
      this.savedTimer = null
    }
  },

  destroyed() {
    this.clearSavedTimer()
    if (this.observer) this.observer.disconnect()
  },
}

export default ButtonLoading
