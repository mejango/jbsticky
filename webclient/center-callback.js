/* /center/callback: where Signa sends the sign-in back. Clears the code from the address bar first
 * (the original URL stays only in memory), then hands it to the Sticky page that framed or opened
 * this one, or finishes the sign-in here and returns to the saved route. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else api.start(root);
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const PATH = "/center/callback";
  const RETURN_KEY = "sticky:center:return:v1";
  const ROUTE = /^#\/[A-Za-z0-9/_@.:%-]{0,1000}$/;

  // The hash route the app saved before a full-page sign-in, read once.
  function returnRoute(storage) {
    let saved = "";
    try { saved = storage.getItem(RETURN_KEY) || ""; storage.removeItem(RETURN_KEY); } catch {}
    return ROUTE.test(saved) ? "/" + saved : "/";
  }

  // Null when the page that framed or opened this one takes the callback; otherwise the route to return to.
  async function complete({ url, win, config, load }) {
    const sdk = await load();
    if (new URL(url).search && await sdk.deliverCenterCallback(url, { window: win })) return null;
    if (!config) throw new Error("Signa sign-in is not configured for this site.");
    const wallet = sdk.createCenterWalletClient({ ...config, callbackUri: win.location.origin + PATH });
    await sdk.completeCenterCallback(wallet, url);
    return returnRoute(win.sessionStorage);
  }

  function start(win) {
    const doc = win.document;
    const url = win.location.href;
    try { win.history.replaceState(null, "", PATH); } catch {}
    const main = doc.getElementById("callback");
    const title = doc.getElementById("callback-title");
    const status = doc.getElementById("callback-status");
    const retry = doc.getElementById("callback-retry");
    const framed = win.parent !== win;
    main.classList.toggle("framed", framed);
    if (framed && typeof win.ResizeObserver === "function") {
      const report = () => win.parent.postMessage({ type: "juicebox-center:size",
        height: Math.ceil(main.getBoundingClientRect().height) }, win.location.origin);
      new win.ResizeObserver(report).observe(main);
    }
    let running = false;
    const run = () => {
      if (running) return;
      running = true;
      retry.classList.add("hide");
      status.classList.remove("err");
      status.textContent = "Restoring your wallet and original page...";
      if (!framed) main.classList.add("ready");
      complete({ url, win, config: win.STICKY_CONFIG?.centerWallet || null, load: () => import("/center-connect.js") })
        .then((route) => {
          if (route !== null) return win.location.replace(route);
          if (framed) { title.textContent = "All done."; status.textContent = ""; }
          else status.textContent = "Done. You can close this window.";
          main.classList.add("ready");
        }, (error) => {
          running = false;
          title.textContent = "Your Signa account";
          status.textContent = error?.message || "The sign-in could not be restored.";
          status.classList.add("err");
          retry.classList.remove("hide");
          main.classList.add("ready");
        });
    };
    retry.addEventListener("click", run);
    run();
  }

  return { PATH, RETURN_KEY, returnRoute, complete, start };
});
