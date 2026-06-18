// Browser-side glue for the WebAuthn ceremony. Two LiveView hooks:
//   * "WebauthnRegister"     — the "add a security key" button (settings)
//   * "WebauthnAuthenticate" — the "use a security key" button (2FA challenge)

const b64uToBuf = s => {
  const norm = s.replace(/-/g, "+").replace(/_/g, "/")
  const pad = norm.length % 4 === 0 ? "" : "=".repeat(4 - (norm.length % 4))
  const bin = atob(norm + pad)
  const buf = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i)
  return buf.buffer
}

const bufToB64u = buf => {
  const bytes = new Uint8Array(buf)
  let bin = ""
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

const postJson = async (path, body) => {
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": csrfToken(),
      accept: "application/json",
    },
    credentials: "same-origin",
    body: JSON.stringify(body || {}),
  })
  if (!res.ok) {
    const text = await res.text()
    throw new Error(`${res.status}: ${text}`)
  }
  return res.json()
}

const decodeCreationOptions = opts => {
  opts.challenge = b64uToBuf(opts.challenge)
  opts.user.id = b64uToBuf(opts.user.id)
  if (opts.excludeCredentials) {
    opts.excludeCredentials = opts.excludeCredentials.map(c => ({...c, id: b64uToBuf(c.id)}))
  }
  return opts
}

const decodeRequestOptions = opts => {
  opts.challenge = b64uToBuf(opts.challenge)
  if (opts.allowCredentials) {
    opts.allowCredentials = opts.allowCredentials.map(c => ({...c, id: b64uToBuf(c.id)}))
  }
  return opts
}

const setStatus = (el, msg, kind) => {
  const target = (el.closest("section, form, body") || document.body)
    .querySelector("[data-status-for='webauthn']")
  if (target) {
    target.textContent = msg
    target.className = kind === "error" ? "text-error text-xs" : "text-success text-xs"
  } else {
    console.log("[webauthn]", msg)
  }
}

export const WebauthnRegister = {
  mounted() {
    this.el.addEventListener("click", async ev => {
      ev.preventDefault()
      if (!window.PublicKeyCredential) {
        setStatus(this.el, "Your browser doesn't support security keys.", "error")
        return
      }

      const startUrl = this.el.dataset.startUrl || "/api/webauthn/register/start"
      const finishUrl = this.el.dataset.finishUrl || "/api/webauthn/register/finish"

      try {
        setStatus(this.el, "Touch your security key to confirm…")

        const start = await postJson(startUrl, {})
        const publicKey = decodeCreationOptions(start.publicKey)
        const cred = await navigator.credentials.create({publicKey})

        const name =
          window.prompt("Name this security key:", "Security key") || "Security key"

        const finish = await postJson(finishUrl, {
          id: cred.id,
          rawId: bufToB64u(cred.rawId),
          type: cred.type,
          attestationObject: bufToB64u(cred.response.attestationObject),
          clientDataJSON: bufToB64u(cred.response.clientDataJSON),
          name,
        })

        const sinkSel = this.el.dataset.recoveryTarget
        const sink = sinkSel && document.querySelector(sinkSel)

        if (finish.recoveryCodes && finish.recoveryCodes.length && sink) {
          sink.className = "alert alert-warning flex-col items-start gap-2"
          sink.innerHTML = `
            <p class="font-semibold text-sm">Save these recovery codes — shown once.</p>
            <pre class="text-xs font-mono grid grid-cols-2 gap-x-6 gap-y-1">${finish.recoveryCodes.join("\n")}</pre>
            <button type="button" class="btn btn-xs" data-ack>I've saved these — refresh</button>`
          sink.querySelector("[data-ack]").addEventListener("click", () => window.location.reload())
          setStatus(this.el, `Added '${finish.name}'. Save the recovery codes above.`, "success")
        } else {
          setStatus(this.el, `Security key '${finish.name}' added.`, "success")
          window.location.reload()
        }
      } catch (err) {
        setStatus(this.el, `Couldn't add key: ${err.message || err}`, "error")
      }
    })
  },
}

export const WebauthnAuthenticate = {
  mounted() {
    this.el.addEventListener("click", async ev => {
      ev.preventDefault()
      if (!window.PublicKeyCredential) {
        setStatus(this.el, "Your browser doesn't support security keys.", "error")
        return
      }

      try {
        setStatus(this.el, "Touch your security key…")

        const start = await postJson("/api/webauthn/auth/start", {})
        const publicKey = decodeRequestOptions(start.publicKey)
        const cred = await navigator.credentials.get({publicKey})

        const finish = await postJson("/api/webauthn/auth/finish", {
          id: bufToB64u(cred.rawId),
          rawId: bufToB64u(cred.rawId),
          type: cred.type,
          authenticatorData: bufToB64u(cred.response.authenticatorData),
          clientDataJSON: bufToB64u(cred.response.clientDataJSON),
          signature: bufToB64u(cred.response.signature),
          userHandle: cred.response.userHandle ? bufToB64u(cred.response.userHandle) : null,
        })

        const redirect = finish.redirect || this.el.dataset.completeUrl
        if (redirect) window.location.assign(redirect)
      } catch (err) {
        setStatus(this.el, `Verification failed: ${err.message || err}`, "error")
      }
    })
  },
}
