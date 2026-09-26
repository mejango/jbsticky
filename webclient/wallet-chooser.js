/* The sign-in chooser: Signa (a passkey account, framed in this dialog) first, then browser wallets.
 * It renders a connect controller from center-connect.js (createConnectController); it never signs. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StickyWalletChooser = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const PASSKEY_ID = "juicebox-center";
  const SIZE = "juicebox-center:size";
  const THEME = "juicebox-center:theme";
  const PAGE = "juicebox-center:page";

  // Homerun's button copy: the device's own passkey name.
  function deviceLabel(userAgent) {
    const agent = String(userAgent || "");
    if (/iPhone/.test(agent)) return "Face ID";
    if (/Macintosh|iPad/.test(agent)) return "Touch ID";
    if (/Windows/.test(agent)) return "Windows Hello";
    return "Device";
  }

  // The frame has no src (Signa's launch form posts into it by name), so passkeys must be
  // delegated to Signa's origin by name; a bare feature list delegates nothing.
  function frameAllow(origin) {
    return `publickey-credentials-get ${origin}; publickey-credentials-create ${origin}`;
  }

  // Design tokens only. Signa applies hex colours, a font list and a radius from its framer.
  function themeOf(style, headingStyle) {
    const theme = {};
    for (const [key, name] of [["background", "--jb-connect-bg"], ["foreground", "--jb-connect-fg"],
      ["muted", "--jb-connect-muted"], ["line", "--jb-connect-line"], ["accent", "--jb-connect-accent"],
      ["accentForeground", "--jb-connect-accent-fg"], ["radius", "--jb-connect-radius"], ["inset", "--jb-connect-pad"]]) {
      const value = String(style.getPropertyValue(name) || "").trim();
      if (value) theme[key] = value;
    }
    if (style.fontFamily) theme.font = style.fontFamily;
    if (headingStyle?.fontFamily) theme.headingFont = headingStyle.fontFamily;
    return theme;
  }

  function safeIcon(icon) {
    return typeof icon === "string" && /^data:image\/(?:png|svg\+xml|webp|jpeg|gif);/i.test(icon) ? icon : "";
  }

  /**
   * dialog: a native <dialog> holding an <h2> and an element for the body.
   * controller: { options, getState, subscribe, choose, cancel }.
   * issuer: Signa's origin; theme replies go only there.
   */
  function createChooser({ dialog, heading, body, controller, issuer, label, win, extra, onClose }) {
    const doc = dialog.ownerDocument;
    let frame = null;
    let unsubscribe = null;
    let closed = false;

    const element = (tag, props = {}, children = []) => {
      const node = doc.createElement(tag);
      for (const [key, value] of Object.entries(props)) {
        if (key === "text") node.textContent = value;
        else if (key === "onClick") node.addEventListener("click", value);
        else node.setAttribute(key, value);
      }
      for (const child of children) if (child) node.appendChild(child);
      return node;
    };

    function render() {
      const state = controller.getState();
      const passkey = controller.options.find((option) => option.id === PASSKEY_ID);
      const wallets = controller.options.filter((option) => option.id !== PASSKEY_ID);
      const pending = state.pending ? controller.options.find((option) => option.id === state.pending) : null;
      // Keep a live frame across renders: rebuilding it would drop the sign-in inside.
      if (frame && (!pending || state.frameName !== frame.getAttribute("name"))) frame = null;
      const nodes = [];
      if (pending) {
        if (state.frameName) {
          frame ||= element("iframe", {
            name: state.frameName, class: "wallet-frame", title: "Signa",
            allow: frameAllow(state.frameOrigin), referrerpolicy: "no-referrer",
          });
          nodes.push(element("div", { role: "status", "aria-label": "Connection" }, [frame]));
        } else {
          nodes.push(element("p", { class: "wallet-status", role: "status",
            text: pending === passkey ? "Connecting, just a sec..." : `Opening ${pending.name}...` }));
        }
      } else {
        if (heading.textContent !== "Sign in") heading.textContent = "Sign in";
        if (passkey) {
          nodes.push(element("button", { type: "button", class: "wallet-primary", text: label,
            onClick: () => void controller.choose(passkey.id) }));
        }
        nodes.push(element("p", { class: "wallet-divider", text: passkey ? "or connect a wallet" : "Connect a wallet" }));
        if (wallets.length) {
          nodes.push(element("div", { class: "wallet-tiles" }, wallets.map((option) => {
            const icon = safeIcon(option.icon);
            // Icon-only tiles, as in Homerun: the name is the accessible name and the tooltip; the mark is decorative.
            return element("button", {
              type: "button", class: "wallet-tile", "aria-label": option.name, title: option.name,
              onClick: () => void controller.choose(option.id),
            }, [
              icon ? element("img", { class: "wallet-mark", src: icon, alt: "" })
                : element("span", { class: "wallet-mark", "aria-hidden": "true", text: option.name.slice(0, 1).toUpperCase() }),
            ]);
          })));
        } else {
          nodes.push(element("p", { class: "wallet-note", text: "No wallet detected in this browser. Install a browser wallet." }));
        }
        if (extra) nodes.push(extra);
      }
      if (state.error) nodes.push(element("p", { class: "wallet-error", role: "alert", text: state.error }));
      body.replaceChildren(...nodes);
    }

    function onMessage(event) {
      const data = event.data;
      if (!frame?.contentWindow || event.source !== frame.contentWindow || !data || typeof data !== "object") return;
      if (event.origin === issuer && data.type === PAGE && (data.page === "signup" || data.page === "signin")) {
        heading.textContent = data.page === "signup" ? "Sign up" : "Sign in";
        return;
      }
      if (data.type !== SIZE || typeof data.height !== "number" || !Number.isFinite(data.height)) return;
      frame.style.height = `${Math.min(1200, Math.max(160, Math.ceil(data.height))) + 2}px`;
      if (event.origin === issuer) {
        const style = win.getComputedStyle(dialog);
        frame.contentWindow.postMessage({ type: THEME, theme: themeOf(style, win.getComputedStyle(heading)) }, issuer);
      }
    }

    function close() {
      if (closed) return;
      closed = true;
      unsubscribe?.();
      win.removeEventListener("message", onMessage);
      controller.cancel();
      frame = null;
      if (dialog.open) dialog.close();
      onClose?.();
    }

    function open() {
      heading.textContent = "Sign in";
      unsubscribe = controller.subscribe(render);
      win.addEventListener("message", onMessage);
      dialog.onclose = close;
      render();
      if (!dialog.open) dialog.showModal();
      heading.focus?.();
    }

    return { open, close, render };
  }

  return { PASSKEY_ID, deviceLabel, frameAllow, themeOf, createChooser };
});
