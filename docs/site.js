// Upgrades the Download button to the newest published release (pre-releases included) and keeps
// the clips quiet: paused offscreen, and not autoplaying when the system asks for reduced motion.
(function () {
  "use strict";

  var button = document.getElementById("download");
  var label = document.getElementById("download-label");
  var meta = document.getElementById("download-meta");
  var PREFIX = "https://github.com/elenaOnline/microfish/releases/download/";

  function setText(node, text) { if (node) { node.textContent = text; } }

  if (button && window.fetch) {
    fetch("https://api.github.com/repos/elenaOnline/microfish/releases?per_page=10", {
      headers: { Accept: "application/vnd.github+json" }
    })
      .then(function (r) { if (!r.ok) { throw new Error("status " + r.status); } return r.json(); })
      .then(function (releases) {
        var release = null, asset = null, i, j, a;
        for (i = 0; i < releases.length && !asset; i++) {
          if (releases[i].draft) { continue; }
          for (j = 0; j < (releases[i].assets || []).length; j++) {
            a = releases[i].assets[j];
            if (/\.zip$/.test(a.name) && String(a.browser_download_url).indexOf(PREFIX) === 0) {
              release = releases[i]; asset = a; break;
            }
          }
        }
        if (!asset) { return; }
        var version = String(release.tag_name).replace(/^v/, "");
        button.href = asset.browser_download_url;
        setText(label, "Download Microfish " + version);
        var parts = [];
        if (release.prerelease) { parts.push("beta"); }
        parts.push((asset.size / 1e6).toFixed(1) + " MB");
        parts.push("macOS 15 or later, Apple silicon");
        setText(meta, parts.join(" · "));
      })
      .catch(function () { /* keep the static link */ });
  }

  var videos = Array.prototype.slice.call(document.querySelectorAll("video"));
  var still = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  videos.forEach(function (v) {
    v.addEventListener("loadedmetadata", function () {
      if (v.videoWidth && v.videoHeight) { v.style.aspectRatio = v.videoWidth + " / " + v.videoHeight; }
    });
    if (still) {
      v.removeAttribute("autoplay");
      v.pause();
      v.controls = true;
    }
  });

  // A visible pause control for all clips (WCAG 2.2.2); clicking a clip also pauses or plays it.
  var paused = still;
  var pauseButton = document.getElementById("pause");
  function play(v) { var p = v.play(); if (p && p.catch) { p.catch(function () {}); } }
  function visible(v) { var r = v.getBoundingClientRect(); return r.bottom > 0 && r.top < window.innerHeight; }
  function setPaused(value) {
    paused = value;
    setText(pauseButton, paused ? "Play animations" : "Pause animations");
    videos.forEach(function (v) { if (paused) { v.pause(); } else if (visible(v)) { play(v); } });
  }
  if (pauseButton) {
    pauseButton.hidden = false;
    setText(pauseButton, paused ? "Play animations" : "Pause animations");
    pauseButton.addEventListener("click", function () { setPaused(!paused); });
  }
  videos.forEach(function (v) {
    v.addEventListener("click", function () { if (v.paused) { play(v); } else { v.pause(); } });
  });

  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { if (!paused) { play(e.target); } }
        else { e.target.pause(); }
      });
    }, { threshold: 0.25 });
    videos.forEach(function (v) { io.observe(v); });
  }
})();
