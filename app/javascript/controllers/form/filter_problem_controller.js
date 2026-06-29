import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "useOption", "idSelect", "groupSelect", "tagSelect" ]

  connect() {
    this.dispatchChange()
    if (this.hasIdSelectTarget) $(this.idSelectTarget).on('change', () => { this.dispatchChange() });
    if (this.hasGroupSelectTarget) $(this.groupSelectTarget).on('change', () => { this.dispatchChange() });
    if (this.hasTagSelectTarget) $(this.tagSelectTarget).on('change', () => { this.dispatchChange() });
  }

  filterChanged() {
    this.dispatchChange()
  }

  dispatchChange() {
    window.problemFilterParams = this.params
  }

  get params() {
    const selectedRadio = this.useOptionTargets.find(radio => radio.checked)
    return {
      'probs[use]': selectedRadio ? selectedRadio.value : 'ids',
      'probs[ids]': this.hasIdSelectTarget ? $(this.idSelectTarget).val() : [],
      'probs[group_ids]': this.hasGroupSelectTarget ? $(this.groupSelectTarget).val() : [],
      'probs[tag_ids]': this.hasTagSelectTarget ? $(this.tagSelectTarget).val() : [],
    }
  }
}
