// phoenix_kit_publishing's browser bundle. Delivered into the host through
// `Publishing.js_sources/0` -> the `:phoenix_kit_js_sources` compiler ->
// `phoenix_kit_modules.js`, which the host's root layout loads on EVERY
// page.
//
// That last part matters more than it looks: public post pages are DEAD
// views — no LiveSocket, so a phx-hook here would never mount and an
// interactive block would render as inert controls. Everything in this
// bundle therefore boots two ways:
//
//   * dead pages — a DOMContentLoaded scan for `[data-pk-splat-gaussian]`
//   * live views — the same boot function exported as a hook, for the
//     editor preview or any future live context
//
// A `__pkBooted` marker keeps the two paths from double-booting one element.
window.PhoenixKitPublishingHooks = (function () {
  "use strict";

  // ── D2: one gaussian, with sliders ────────────────────────────────────
  //
  // The article's first interactive: a single 3D gaussian the reader can
  // stretch, spin and fade before any math appears. Dependency-free canvas
  // 2D. The 3D-ness is conveyed by a slow orbiting viewpoint — stopped by
  // prefers-reduced-motion, and permanently once the reader grabs the view
  // slider, because a scene that starts moving again while someone reads it
  // is worse than one that stays put.

  var TAU = Math.PI * 2;

  // 3x3 helpers, unrolled — per-frame code that needs nothing general.
  function rotY(a) {
    var c = Math.cos(a), s = Math.sin(a);
    return [c, 0, s, 0, 1, 0, -s, 0, c];
  }

  function rotX(a) {
    var c = Math.cos(a), s = Math.sin(a);
    return [1, 0, 0, 0, c, -s, 0, s, c];
  }

  function mul(a, b) {
    var r = new Array(9);
    for (var i = 0; i < 3; i++)
      for (var j = 0; j < 3; j++)
        r[i * 3 + j] =
          a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    return r;
  }

  function transpose(m) {
    return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
  }

  // Covariance of the gaussian in world space: C = R · S² · Rᵀ. The one
  // formula the article shows — this demo IS that formula.
  function covariance(sx, sy, sz, yaw, pitch) {
    var R = mul(rotY(yaw), rotX(pitch));
    var S2 = [sx * sx, 0, 0, 0, sy * sy, 0, 0, 0, sz * sz];
    return mul(mul(R, S2), transpose(R));
  }

  // Rotate into view space and drop z — the EWA insight: a 3D gaussian seen
  // by a camera is exactly a 2D gaussian, in closed form.
  function projectedEllipse(C, viewYaw, viewPitch) {
    var V = mul(rotX(viewPitch), rotY(viewYaw));
    var M = mul(mul(V, C), transpose(V));
    var a = M[0], b = M[1], d = M[4];
    var tr = a + d, det = a * d - b * b;
    var disc = Math.sqrt(Math.max(0, (tr * tr) / 4 - det));
    var l1 = tr / 2 + disc, l2 = tr / 2 - disc;
    var angle = Math.atan2(l1 - a, b || 1e-9);
    return {
      r1: Math.sqrt(Math.max(l1, 1e-6)),
      r2: Math.sqrt(Math.max(l2, 1e-6)),
      angle: angle
    };
  }

  function el(tag, cls, parent) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (parent) parent.appendChild(e);
    return e;
  }

  function slider(panel, label, min, max, step, value, oninput) {
    var row = el("label", "pk-splatg__row", panel);
    el("span", "pk-splatg__label", row).textContent = label;
    var input = el("input", "pk-splatg__slider", row);
    input.type = "range";
    input.min = min;
    input.max = max;
    input.step = step;
    input.value = value;
    var out = el("span", "pk-splatg__value", row);
    out.textContent = value;
    input.addEventListener("input", function () {
      out.textContent = input.value;
      oninput(parseFloat(input.value));
    });
    return input;
  }

  var STYLE_ID = "pk-splatg-style";

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent =
      ".pk-splatg{border:1px solid rgba(128,128,128,.25);border-radius:12px;overflow:hidden;margin:1.5rem 0}" +
      ".pk-splatg__canvas{display:block;width:100%;background:#0d0f14}" +
      ".pk-splatg__panel{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:.25rem .9rem;padding:.8rem 1rem;font-size:.85rem}" +
      ".pk-splatg__row{display:flex;align-items:center;gap:.5rem}" +
      ".pk-splatg__label{width:5.5em;opacity:.75}" +
      ".pk-splatg__slider{flex:1;accent-color:#e58f5a}" +
      ".pk-splatg__value{width:3em;text-align:right;font-variant-numeric:tabular-nums;opacity:.75}" +
      ".pk-splatg__caption{padding:0 1rem .8rem;font-size:.8rem;opacity:.6}";
    document.head.appendChild(style);
  }

  function bootSplatGaussian(root) {
    if (root.__pkBooted) return;
    root.__pkBooted = true;
    ensureStyle();

    // The no-JS fallback text is replaced wholesale by the real thing.
    root.textContent = "";

    var state = {
      sx: parseFloat(root.dataset.sx || "1"),
      sy: parseFloat(root.dataset.sy || "0.45"),
      sz: parseFloat(root.dataset.sz || "0.7"),
      yaw: 0.5,
      pitch: 0.35,
      opacity: 0.9,
      hue: parseFloat(root.dataset.hue || "24"),
      view: 0.6,
      orbiting: !window.matchMedia("(prefers-reduced-motion: reduce)").matches,
      raf: null
    };

    var canvas = el("canvas", "pk-splatg__canvas", root);
    var panel = el("div", "pk-splatg__panel", root);
    var caption = el("div", "pk-splatg__caption", root);
    caption.textContent =
      "One gaussian. Its screen shape is C = R S² Rᵀ projected to " +
      "2D — no mesh, no edges, just a recipe for a smear.";

    slider(panel, "scale x", 0.05, 2, 0.05, state.sx, function (v) { state.sx = v; draw(); });
    slider(panel, "scale y", 0.05, 2, 0.05, state.sy, function (v) { state.sy = v; draw(); });
    slider(panel, "scale z", 0.05, 2, 0.05, state.sz, function (v) { state.sz = v; draw(); });
    slider(panel, "rotate", 0, 360, 1, 29, function (v) { state.yaw = (v / 360) * TAU; draw(); });
    slider(panel, "opacity", 0.05, 1, 0.05, state.opacity, function (v) { state.opacity = v; draw(); });
    slider(panel, "colour", 0, 360, 1, state.hue, function (v) { state.hue = v; draw(); });
    slider(panel, "view", 0, 360, 1, Math.round((state.view / TAU) * 360), function (v) {
      state.orbiting = false;
      state.view = (v / 360) * TAU;
      draw();
    });

    function resize() {
      var width = root.clientWidth || 640;
      var height = Math.round(width * 0.52);
      // Backing store capped at DPR 2 — a gradient blob gains nothing at 3x,
      // and tiled mobile GPUs pay squarely for fill.
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      canvas.style.height = height + "px";
    }

    // A flat ring of reference lines under the blob, rotating with the view
    // — the cheapest possible "this is 3D" cue.
    function drawGround(ctx, cx, cy, unit) {
      ctx.save();
      ctx.translate(cx, cy + unit * 1.5);
      ctx.strokeStyle = "rgba(140,150,170,0.16)";
      ctx.lineWidth = 1;

      var spokes = 12;

      for (var i = 0; i < spokes; i++) {
        var a = state.view + (i / spokes) * TAU;
        ctx.beginPath();
        ctx.moveTo(0, 0);
        ctx.lineTo(Math.cos(a) * unit * 2.2, Math.sin(a) * unit * 0.55);
        ctx.stroke();
      }

      for (var ring = 1; ring <= 3; ring++) {
        ctx.beginPath();
        ctx.ellipse(0, 0, unit * 0.73 * ring, unit * 0.18 * ring, 0, 0, TAU);
        ctx.stroke();
      }

      ctx.restore();
    }

    function draw() {
      var ctx = canvas.getContext("2d");
      var w = canvas.width, h = canvas.height;
      ctx.clearRect(0, 0, w, h);

      var cx = w / 2, cy = h / 2.15;
      var unit = Math.min(w, h) / 4.6;

      drawGround(ctx, cx, cy, unit);

      var C = covariance(state.sx, state.sy, state.sz, state.yaw, state.pitch);
      var e = projectedEllipse(C, state.view, 0.3);

      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(e.angle);
      ctx.scale(e.r1 * unit, e.r2 * unit);
      var g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
      g.addColorStop(0, "hsla(" + state.hue + ",85%,62%," + state.opacity + ")");
      g.addColorStop(0.45, "hsla(" + state.hue + ",80%,55%," + state.opacity * 0.55 + ")");
      g.addColorStop(1, "hsla(" + state.hue + ",75%,50%,0)");
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(0, 0, 1, 0, TAU);
      ctx.fill();
      ctx.restore();
    }

    function tick() {
      if (!state.orbiting) return;
      state.view = (state.view + 0.004) % TAU;
      draw();
      state.raf = requestAnimationFrame(tick);
    }

    resize();
    draw();
    if (state.orbiting) state.raf = requestAnimationFrame(tick);

    if (typeof ResizeObserver !== "undefined") {
      var observer = new ResizeObserver(function () {
        resize();
        draw();
      });
      observer.observe(root);
      root.__pkObserver = observer;
    }

    // For the LV-hook path; a dead page tears down with the document.
    root.__pkTeardown = function () {
      if (state.raf) cancelAnimationFrame(state.raf);
      if (root.__pkObserver) root.__pkObserver.disconnect();
    };
  }

  function bootAll() {
    var nodes = document.querySelectorAll("[data-pk-splat-gaussian]");
    for (var i = 0; i < nodes.length; i++) bootSplatGaussian(nodes[i]);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bootAll);
  } else {
    bootAll();
  }

  return {
    // Same boot, as a hook, for live contexts (the editor preview). The
    // dead-page scan and this are idempotent together via __pkBooted.
    PubSplatGaussian: {
      mounted: function () {
        bootSplatGaussian(this.el);
      },
      destroyed: function () {
        if (this.el.__pkTeardown) this.el.__pkTeardown();
      }
    }
  };
})();
