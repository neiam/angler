// Full-size photo viewer for post media.
//
// Tiles rendered by `PublicComponents.media_tiles` are buttons carrying
// `data-lightbox-src` (and `-alt`), grouped by their `[data-lightbox-group]`
// grid. One delegated click listener covers every LiveView and stream item,
// so nothing needs a hook or a server round trip. The viewer is a native
// <dialog> appended to <body>, outside the LiveView root, which gives us the
// modal focus trap and Escape-to-close for free.

const icon = path =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`

const ICONS = {
  close: icon("M6 6l12 12M18 6L6 18"),
  prev: icon("M15 18l-6-6 6-6"),
  next: icon("M9 18l6-6-6-6"),
  open: icon("M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"),
}

let dialog, img, caption, counter, original, prevBtn, nextBtn
let items = []
let index = 0
let touchX = null

function build() {
  dialog = document.createElement("dialog")
  dialog.id = "lightbox"
  dialog.className = "lightbox"
  dialog.setAttribute("aria-label", "Photo viewer")
  dialog.innerHTML = `
    <div class="lightbox-bar">
      <span class="lightbox-counter" id="lightbox-counter"></span>
      <a class="lightbox-btn" id="lightbox-original" target="_blank" rel="noopener" title="Open original" aria-label="Open original">${ICONS.open}</a>
      <button type="button" class="lightbox-btn" id="lightbox-close" autofocus title="Close (Esc)" aria-label="Close">${ICONS.close}</button>
    </div>
    <button type="button" class="lightbox-btn lightbox-nav lightbox-prev" id="lightbox-prev" aria-label="Previous photo">${ICONS.prev}</button>
    <figure class="lightbox-figure">
      <img class="lightbox-img" id="lightbox-img" alt="" />
      <figcaption class="lightbox-caption" id="lightbox-caption"></figcaption>
    </figure>
    <button type="button" class="lightbox-btn lightbox-nav lightbox-next" id="lightbox-next" aria-label="Next photo">${ICONS.next}</button>
  `
  document.body.appendChild(dialog)

  img = dialog.querySelector("#lightbox-img")
  caption = dialog.querySelector("#lightbox-caption")
  counter = dialog.querySelector("#lightbox-counter")
  original = dialog.querySelector("#lightbox-original")
  prevBtn = dialog.querySelector("#lightbox-prev")
  nextBtn = dialog.querySelector("#lightbox-next")

  dialog.querySelector("#lightbox-close").addEventListener("click", close)
  prevBtn.addEventListener("click", () => step(-1))
  nextBtn.addEventListener("click", () => step(1))
  img.addEventListener("load", () => img.classList.remove("is-loading"))

  // Clicking the backdrop (anything that isn't the photo or a control) closes.
  dialog.addEventListener("click", e => {
    if (!e.target.closest(".lightbox-img, .lightbox-btn, .lightbox-caption")) close()
  })

  dialog.addEventListener("keydown", e => {
    if (e.key === "ArrowLeft") { e.preventDefault(); step(-1) }
    if (e.key === "ArrowRight") { e.preventDefault(); step(1) }
  })

  dialog.addEventListener("touchstart", e => { touchX = e.touches[0].clientX }, {passive: true})
  dialog.addEventListener("touchend", e => {
    if (touchX === null) return
    const dx = e.changedTouches[0].clientX - touchX
    touchX = null
    if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1)
  })

  dialog.addEventListener("close", () => {
    document.documentElement.classList.remove("lightbox-open")
    img.removeAttribute("src")
  })
}

function show(i) {
  index = (i + items.length) % items.length
  const item = items[index]

  img.classList.add("is-loading")
  img.src = item.src
  if (img.complete) img.classList.remove("is-loading")
  img.alt = item.alt
  caption.textContent = item.alt
  caption.hidden = item.alt === ""
  original.href = item.src

  const many = items.length > 1
  counter.textContent = many ? `${index + 1} / ${items.length}` : ""
  prevBtn.hidden = !many
  nextBtn.hidden = !many

  // Warm the neighbours so stepping through an album feels instant.
  if (many) {
    for (const n of [index + 1, index - 1]) {
      new Image().src = items[(n + items.length) % items.length].src
    }
  }
}

function step(delta) {
  if (items.length > 1) show(index + delta)
}

function open(tile) {
  const group = tile.closest("[data-lightbox-group]") || tile.parentElement
  const tiles = [...group.querySelectorAll("[data-lightbox-src]")]
  items = tiles.map(t => ({src: t.dataset.lightboxSrc, alt: t.dataset.lightboxAlt || ""}))

  if (!dialog) build()
  show(Math.max(tiles.indexOf(tile), 0))
  document.documentElement.classList.add("lightbox-open")
  dialog.showModal()
}

function close() {
  if (dialog && dialog.open) dialog.close()
}

export function installLightbox() {
  document.addEventListener("click", e => {
    const tile = e.target.closest("[data-lightbox-src]")
    // Leave modified clicks alone (new tab etc. on a wrapping link).
    if (!tile || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
    e.preventDefault()
    open(tile)
  })

  // A live navigation away shouldn't leave the viewer up over the next page.
  window.addEventListener("phx:page-loading-start", close)
}
