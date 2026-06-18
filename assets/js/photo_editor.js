// Client-side photo touch-up for the web composer. Owns a file picker, a
// <canvas> preview, brightness/contrast/saturation sliders and a few presets.
// "Add to post" exports the edited canvas and pushes it into the LiveView
// `:media` upload via this.upload/2, so the server only ever sees edited bytes.

const PRESETS = {
  none: {brightness: 100, contrast: 100, saturation: 100, sepia: 0, grayscale: 0},
  mono: {brightness: 100, contrast: 105, saturation: 100, sepia: 0, grayscale: 100},
  warm: {brightness: 105, contrast: 100, saturation: 115, sepia: 35, grayscale: 0},
  cool: {brightness: 100, contrast: 105, saturation: 90, sepia: 0, grayscale: 0, hue: 200},
  vivid: {brightness: 105, contrast: 115, saturation: 150, sepia: 0, grayscale: 0},
}

export const PhotoEditor = {
  mounted() {
    const $ = role => this.el.querySelector(`[data-role='${role}']`)
    this.uploadName = this.el.dataset.uploadName || "media"
    this.img = null
    this.extra = {sepia: 0, grayscale: 0, hue: 0}

    const fileInput = $("file")
    const stage = $("stage")
    const canvas = $("canvas")
    const ctx = canvas.getContext("2d")
    const sliders = ["brightness", "contrast", "saturation"].map($)

    const filterString = () => {
      const [b, c, s] = sliders.map(el => parseInt(el.value, 10))
      const {sepia, grayscale, hue} = this.extra
      return `brightness(${b}%) contrast(${c}%) saturate(${s}%) sepia(${sepia}%) ` +
        `grayscale(${grayscale}%) hue-rotate(${hue || 0}deg)`
    }

    const redraw = () => {
      if (!this.img) return
      ctx.filter = filterString()
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      ctx.drawImage(this.img, 0, 0, canvas.width, canvas.height)
    }

    fileInput.addEventListener("change", () => {
      const file = fileInput.files && fileInput.files[0]
      if (!file) return
      const img = new Image()
      img.onload = () => {
        // Cap the working resolution so large photos stay responsive.
        const max = 1600
        const scale = Math.min(1, max / Math.max(img.width, img.height))
        canvas.width = Math.round(img.width * scale)
        canvas.height = Math.round(img.height * scale)
        this.img = img
        this.extra = {sepia: 0, grayscale: 0, hue: 0}
        sliders.forEach(el => (el.value = 100))
        stage.classList.remove("hidden")
        redraw()
      }
      img.src = URL.createObjectURL(file)
    })

    sliders.forEach(el => el.addEventListener("input", redraw))

    this.el.querySelectorAll("[data-preset]").forEach(btn => {
      btn.addEventListener("click", () => {
        const p = PRESETS[btn.dataset.preset] || PRESETS.none
        $("brightness").value = p.brightness
        $("contrast").value = p.contrast
        $("saturation").value = p.saturation
        this.extra = {sepia: p.sepia || 0, grayscale: p.grayscale || 0, hue: p.hue || 0}
        redraw()
      })
    })

    $("add").addEventListener("click", () => {
      if (!this.img) return
      canvas.toBlob(blob => {
        if (!blob) return
        const name = (fileInput.files[0] && fileInput.files[0].name || "photo").replace(/\.\w+$/, "") + ".jpg"
        const file = new File([blob], name, {type: "image/jpeg"})
        // Push the edited file into the LiveView upload.
        this.upload(this.uploadName, [file])
        // Reset for the next photo.
        this.img = null
        stage.classList.add("hidden")
        fileInput.value = ""
      }, "image/jpeg", 0.92)
    })
  },
}
