/* Topla page logic. The page collects intent; Zig runs yt-dlp and reports back. */
(function () {
  "use strict";

  const api = window.myzig;
  const $ = (s) => document.querySelector(s);
  const el = {
    url: $("#urlInput"), analyse: $("#analyseBtn"), result: $("#resultCard"),
    thumb: $("#mediaThumb"), source: $("#sourceBadge"), title: $("#mediaTitle"),
    sub: $("#mediaSub"), formats: $("#formats"), download: $("#downloadBtn"),
    cancel: $("#cancelBtn"), progress: $("#progressCard"), fill: $("#progressFill"),
    pct: $("#progressPct"), progressLine: $("#progressLine"), outdir: $("#outdirInput"),
    pick: $("#pickBtn"), folder: $("#folderBtn"), theme: $("#themeBtn"),
    status: $("#toolStatus"), version: $("#toolVersion"), history: $("#history"),
    toasts: $("#toasts")
  };

  const FORMATS = [
    { id: "best", title: "En iyi", sub: "Video + ses", icon: "video" },
    { id: "hd1080", title: "1080p", sub: "Yüksek çözünürlük", icon: "video" },
    { id: "hd720", title: "720p", sub: "Dengeli", icon: "video" },
    { id: "audio", title: "Ses", sub: "MP3 olarak", icon: "music" },
    { id: "image", title: "Görsel", sub: "Kapak resmi", icon: "image" }
  ];

  const S = {
    settings: { theme: "dark", outdir: "", format: "best", history: [] },
    url: "", info: null, format: "best", busy: false, ready: false,
    status: null
  };

  const ico = (n) => `<svg class="ico"><use href="#i-${n}"/></svg>`;
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  function toast(msg, kind) {
    const node = document.createElement("div");
    node.className = "toast " + (kind || "");
    node.innerHTML = ico(kind === "err" ? "alert" : kind === "ok" ? "check" : "download") +
      "<span>" + esc(msg) + "</span>";
    el.toasts.appendChild(node);
    setTimeout(() => node.remove(), 3200);
  }

  function persist() {
    api.call("Settings.save", JSON.stringify(S.settings)).catch((e) =>
      console.warn("topla: settings not saved", e));
  }

  function applyTheme(theme) {
    S.settings.theme = theme === "light" ? "light" : "dark";
    document.documentElement.dataset.theme = S.settings.theme;
    el.theme.innerHTML = ico(S.settings.theme === "dark" ? "sun" : "moon");
  }

  function markReady() {
    if (S.ready) return;
    S.ready = true;
    try { api.emit("topla:ready"); } catch (e) { console.warn("topla: ready signal failed", e); }
  }

  function fmtDuration(seconds) {
    if (!seconds || seconds < 0) return "—";
    const s = Math.round(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const r = s % 60;
    return h ? `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
             : `${m}:${String(r).padStart(2, "0")}`;
  }

  function sourceOf(info) {
    const text = ((info.extractor_key || "") + " " + (info.webpage_url || "")).toLowerCase();
    if (text.includes("youtube")) return text.includes("music") ? "YouTube Music" : "YouTube";
    if (text.includes("instagram")) return "Instagram";
    if (text.includes("facebook")) return "Facebook";
    if (text.includes("tiktok")) return "TikTok";
    if (text.includes("twitter") || text.includes(" x.com")) return "X";
    return "Bağlantı";
  }

  function renderFormats() {
    el.formats.innerHTML = FORMATS.map((f) =>
      `<button class="format${f.id === S.format ? " selected" : ""}" data-format="${f.id}">` +
      ico(f.icon) + `<span class="f-title">${esc(f.title)}</span>` +
      `<span class="f-sub">${esc(f.sub)}</span></button>`).join("");
  }

  function renderHistory() {
    const items = S.settings.history || [];
    if (!items.length) {
      el.history.innerHTML = '<li class="empty">Henüz indirme yok</li>';
      return;
    }
    el.history.innerHTML = items.map((h) => {
      const cls = h.status === "Tamamlandı" ? " ok" : h.status === "Hata" || h.status === "İptal" ? " err" : "";
      return `<li>${ico("download")}<span class="h-text">` +
        `<span class="h-title">${esc(h.title)}</span>` +
        `<span class="h-meta">${esc(h.source || "")}</span></span>` +
        `<span class="h-state${cls}">${esc(h.status)}</span></li>`;
    }).join("");
  }

  function addHistory(title, status, source) {
    S.settings.history.unshift({ title: title || "İndirme", status, source: source || "", time: Date.now() });
    S.settings.history = S.settings.history.slice(0, 8);
    persist();
    renderHistory();
  }

  function setHistoryStatus(status) {
    const first = S.settings.history[0];
    if (!first) return;
    first.status = status;
    persist();
    renderHistory();
  }

  function setBusy(busy) {
    S.busy = busy;
    el.analyse.disabled = busy;
    el.download.disabled = busy;
    el.cancel.hidden = !busy;
    el.url.disabled = false;
  }

  function showResult(info) {
    el.source.textContent = sourceOf(info);
    el.title.textContent = info.title || "Bağlantı";
    const bits = [];
    if (info.uploader) bits.push(info.uploader);
    if (info.duration) bits.push(fmtDuration(info.duration));
    if (info.ext) bits.push(String(info.ext).toUpperCase());
    el.sub.textContent = bits.join(" · ") || "—";

    el.thumb.innerHTML = "";
    if (info.thumbnail) {
      const img = document.createElement("img");
      img.alt = "";
      img.onerror = () => { el.thumb.innerHTML = ico("image"); };
      img.src = info.thumbnail;
      el.thumb.appendChild(img);
    } else {
      el.thumb.innerHTML = ico("image");
    }
    el.result.hidden = false;
  }

  function resetProgress() {
    el.pct.textContent = "0%";
    el.fill.style.transform = "scaleX(0)";
    el.progressLine.textContent = "—";
    el.progress.hidden = false;
  }

  // ------------------------------------------------------------- operations
  async function analyse() {
    const url = el.url.value.trim();
    if (!url) { toast("Bağlantı gerekli", "err"); el.url.focus(); return; }
    if (S.busy) return;
    setBusy(true);
    el.result.hidden = true;
    S.info = null;
    S.url = url;
    try {
      await api.call("Media.analyse", url);
      toast("Bağlantı çözümleniyor");
    } catch (err) {
      setBusy(false);
      toast(err.message || "Çözümleme başlatılamadı", "err");
    }
  }

  async function download() {
    if (!S.url || S.busy) return;
    const outdir = el.outdir.value.trim();
    if (!outdir) { toast("Çıktı klasörü gerekli", "err"); return; }
    setBusy(true);
    resetProgress();
    addHistory(S.info ? S.info.title : S.url, "İndiriliyor", sourceOf(S.info || {}));
    try {
      await api.call("Download.start", S.url, S.format, outdir);
    } catch (err) {
      setBusy(false);
      setHistoryStatus("Hata");
      toast(err.message || "İndirme başlatılamadı", "err");
    }
  }

  async function cancel() {
    try { await api.call("Download.cancel"); }
    catch (err) { toast("İptal edilemedi", "err"); }
  }

  async function pickFolder() {
    try {
      const paths = await api.dialog.open({ title: "Çıktı klasörü", directory: true });
      if (Array.isArray(paths) && paths.length) {
        el.outdir.value = paths[0];
        S.settings.outdir = paths[0];
        persist();
      }
    } catch (err) { toast("Klasör seçilemedi", "err"); }
  }

  // ------------------------------------------------------------------ events
  if (!api) {
    el.status.textContent = "MyZig köprüsü yok";
    document.querySelector(".main").innerHTML =
      '<div class="card"><h1>MyZig köprüsü yok</h1><p>Bu sayfa yalnızca Topla içinde çalışır.</p></div>';
    return;
  }

  api.on("media:info", (raw) => {
    let info;
    try { info = typeof raw === "string" ? JSON.parse(raw) : raw; }
    catch (err) { setBusy(false); toast("Metadata okunamadı", "err"); return; }
    S.info = info;
    setBusy(false);
    showResult(info);
  });
  api.on("media:error", (msg) => {
    setBusy(false);
    toast("Çözümlenemedi: " + String(msg).slice(0, 120), "err");
  });
  api.on("download:progress", (raw) => {
    const clean = String(raw).replace(/\x1b\[[0-9;]*m/g, "");
    const m = clean.match(/(\d{1,3}(?:\.\d+)?)%/);
    if (m) {
      const p = Math.min(100, parseFloat(m[1]));
      el.fill.style.transform = "scaleX(" + (p / 100) + ")";
      el.pct.textContent = Math.round(p) + "%";
    }
    el.progressLine.textContent = clean.trim();
  });
  api.on("download:done", () => {
    setBusy(false);
    setHistoryStatus("Tamamlandı");
    el.pct.textContent = "100%";
    el.fill.style.transform = "scaleX(1)";
    toast("İndirme tamamlandı", "ok");
    setTimeout(() => { el.progress.hidden = true; }, 1200);
  });
  api.on("download:error", (msg) => {
    setBusy(false);
    setHistoryStatus("Hata");
    toast("İndirme hatası: " + String(msg).slice(0, 120), "err");
  });
  api.on("download:cancelled", () => {
    setBusy(false);
    setHistoryStatus("İptal");
    toast("İndirme iptal edildi");
    el.progress.hidden = true;
  });

  el.analyse.addEventListener("click", analyse);
  el.download.addEventListener("click", download);
  el.cancel.addEventListener("click", cancel);
  el.pick.addEventListener("click", pickFolder);
  el.folder.addEventListener("click", () => {
    api.openExternal(el.outdir.value.trim()).then((ok) => {
      if (!ok) toast("Klasör açılamadı", "err");
    }).catch(() => toast("Klasör açılamadı", "err"));
  });
  el.theme.addEventListener("click", () => {
    applyTheme(S.settings.theme === "dark" ? "light" : "dark");
    persist();
  });
  el.formats.addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-format]");
    if (!b) return;
    S.format = b.dataset.format;
    S.settings.format = S.format;
    persist();
    el.formats.querySelectorAll(".format").forEach((n) =>
      n.classList.toggle("selected", n.dataset.format === S.format));
  });
  el.url.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") { ev.preventDefault(); analyse(); }
  });
  el.outdir.addEventListener("change", () => {
    S.settings.outdir = el.outdir.value.trim();
    persist();
  });
  document.addEventListener("keydown", (ev) => {
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "Enter") {
      ev.preventDefault();
      if (S.info && !S.busy) download(); else analyse();
    }
  });

  // -------------------------------------------------------------------- boot
  async function boot() {
    applyTheme(S.settings.theme);
    try {
      const saved = await api.call("Settings.load");
      if (saved && typeof saved === "object") {
        S.settings = Object.assign(S.settings, saved);
        if (!Array.isArray(S.settings.history)) S.settings.history = [];
      }
    } catch (err) { console.warn("topla: settings not loaded", err); }
    applyTheme(S.settings.theme);
    S.format = FORMATS.some((f) => f.id === S.settings.format) ? S.settings.format : "best";
    renderFormats();
    renderHistory();

    try {
      S.status = await api.call("App.status");
      if (S.status) {
        if (!S.settings.outdir) S.settings.outdir = S.status.downloads || "";
        el.outdir.value = S.settings.outdir;
        el.version.textContent = S.status.version || "—";
        el.status.textContent = S.status.installed ? "yt-dlp hazır" : "yt-dlp bulunamadı";
        el.status.classList.toggle("ready", !!S.status.installed);
        if (!S.status.installed) toast("yt-dlp kurulu değil — README'ye bakın", "err");
      }
    } catch (err) {
      el.status.textContent = "Durum alınamadı";
      toast("Uygulama durumu okunamadı", "err");
    }
    setTimeout(markReady, 32);

    if (new URLSearchParams(location.search).get("selftest") === "1") {
      setTimeout(() => {
        console.log("TOPLA SELFTEST " + (S.status && S.status.installed ? "PASS" : "FAIL") +
          " version=" + (S.status ? S.status.version : "none"));
      }, 200);
    }
  }

  boot().catch((err) => { console.error("topla boot failed", err); markReady(); });
})();
