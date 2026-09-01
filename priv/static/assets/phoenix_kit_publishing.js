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
//     and `[data-pk-splat-trainer]`
//   * live views — the same boot functions exported as hooks, for the
//     editor preview or any future live context
//
// A `__pkBooted` marker keeps the two paths from double-booting one element.
window.PhoenixKitPublishingHooks = (function () {
  "use strict";

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

  // Eigen-decomposition of a symmetric 2x2 — the screen ellipse of a
  // projected gaussian. Shared by both demos.
  function eig2(a, b, d) {
    var tr = a + d, det = a * d - b * b;
    var disc = Math.sqrt(Math.max(0, (tr * tr) / 4 - det));
    var l1 = tr / 2 + disc, l2 = tr / 2 - disc;
    return {
      r1: Math.sqrt(Math.max(l1, 1e-6)),
      r2: Math.sqrt(Math.max(l2, 1e-6)),
      angle: Math.atan2(l1 - a, b || 1e-9)
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
      ".pk-splatg__caption{padding:0 1rem .8rem;font-size:.8rem;opacity:.6}" +
      // ── trainer ──
      ".pk-splatt{border:1px solid rgba(128,128,128,.25);border-radius:12px;overflow:hidden;margin:1.5rem 0}" +
      ".pk-splatt__stage{display:grid;grid-template-columns:3fr 2fr;background:#0d0f14}" +
      "@media(max-width:640px){.pk-splatt__stage{grid-template-columns:1fr}}" +
      ".pk-splatt__truth{display:block;width:100%;touch-action:none;cursor:grab}" +
      ".pk-splatt__side{background:#12151c;color:#cfd6e4;padding:.7rem;display:flex;flex-direction:column;gap:.55rem;min-width:0}" +
      ".pk-splatt__shots{display:flex;gap:.6rem;flex-wrap:wrap}" +
      ".pk-splatt__shot{font-size:.62rem;opacity:.92;text-align:center}" +
      ".pk-splatt__pair{display:flex;gap:4px}" +
      ".pk-splatt__mini{width:64px;height:64px;image-rendering:pixelated;background:#000;border-radius:4px;display:block}" +
      ".pk-splatt__loss{width:100%;height:52px;background:#0d0f14;border-radius:4px}" +
      ".pk-splatt__bars{display:flex;flex-direction:column;gap:3px;font-size:.68rem}" +
      ".pk-splatt__barrow{display:flex;align-items:center;gap:.4rem}" +
      ".pk-splatt__barlabel{width:7em;opacity:.75}" +
      ".pk-splatt__bartrack{flex:1;height:8px;background:rgba(128,140,160,.18);border-radius:4px;overflow:hidden}" +
      ".pk-splatt__bar{height:100%;background:#e58f5a;border-radius:4px;width:0}" +
      ".pk-splatt__controls{display:flex;flex-wrap:wrap;gap:.5rem .7rem;padding:.7rem 1rem;align-items:center;font-size:.85rem}" +
      ".pk-splatt__btn{padding:.3rem .75rem;border:1px solid rgba(128,128,128,.45);border-radius:8px;background:transparent;color:inherit;cursor:pointer;font:inherit;font-size:.82rem}" +
      ".pk-splatt__btn--on{background:#e58f5a;border-color:#e58f5a;color:#14161c}" +
      ".pk-splatt__caption{padding:0 1rem .8rem;font-size:.8rem;opacity:.6}";
    document.head.appendChild(style);
  }

  // ── D2: one gaussian, with sliders ────────────────────────────────────
  //
  // The article's first interactive: a single 3D gaussian the reader can
  // stretch, spin and fade before any math appears. Dependency-free canvas
  // 2D. The 3D-ness is conveyed by a slow orbiting viewpoint — stopped by
  // prefers-reduced-motion, and permanently once the reader grabs the view
  // slider, because a scene that starts moving again while someone reads it
  // is worse than one that stays put.

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
    return eig2(M[0], M[1], M[4]);
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

  // ── D3: the red-dot trainer ───────────────────────────────────────────
  //
  // The article's core demo: gradient descent fitting one gaussian to a
  // red dot, with the reader choosing how many cameras get to disagree.
  // Honest by construction — this is a real optimizer (central-difference
  // gradients + Adam over 9 parameters: 3 position + a 6-parameter
  // Cholesky factor of the covariance), not an animation of one. The
  // 1-camera cigar, the 2-camera snap and the rig comparison are whatever
  // the loss surface actually does.
  //
  // Projection is orthographic (the same EWA drop-z as D2). That choice IS
  // the pedagogy: under orthographic projection one viewpoint contains
  // exactly zero depth information, so the demo's central claim is true by
  // geometry, not by tuning.

  var trainerMath = (function () {
    var IMG = 40;        // each "photo" is 40x40 — genuinely what the loss sees
    var SPAN = 3.4;      // world units across a photo
    var DOT_R = 0.09;    // the truth dot, as a tight isotropic gaussian
    var PIX_FLOOR = 0.35; // px² footprint floor; keeps a collapsed axis visible
                          // to the loss, so its gradient never flatlines

    function norm3(v) {
      var n = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) || 1;
      return [v[0] / n, v[1] / n, v[2] / n];
    }

    function cross(a, b) {
      return [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0]
      ];
    }

    function dot3(a, b) {
      return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    }

    // A camera on the sphere around the room's center, looking inward.
    // az 0 = +z, el 0 = horizontal, el > 0 = above the room looking down.
    function cameraBasis(az, el) {
      var pos = [
        Math.sin(az) * Math.cos(el) * 2.1,
        Math.sin(el) * 2.1,
        Math.cos(az) * Math.cos(el) * 2.1
      ];
      var fwd = norm3([-pos[0], -pos[1], -pos[2]]);
      var right = norm3(cross(fwd, [0, 1, 0]));
      var up = cross(right, fwd);
      return { pos: pos, fwd: fwd, right: right, up: up, az: az, el: el };
    }

    // Render one gaussian into img (Float64Array IMG*IMG), additive.
    // Orthographic: pixel u tracks `right`, pixel v tracks -`up`.
    function renderInto(img, cam, mean, C, amp) {
      var k = IMG / SPAN;
      var mu = IMG / 2 + dot3(cam.right, mean) * k;
      var mv = IMG / 2 - dot3(cam.up, mean) * k;

      // 2D covariance in pixel space: rows of the projection are k·right
      // and -k·up, so Σ = J C Jᵀ with those two rows.
      var Cr = [
        C[0] * cam.right[0] + C[1] * cam.right[1] + C[2] * cam.right[2],
        C[3] * cam.right[0] + C[4] * cam.right[1] + C[5] * cam.right[2],
        C[6] * cam.right[0] + C[7] * cam.right[1] + C[8] * cam.right[2]
      ];
      var Cu = [
        C[0] * cam.up[0] + C[1] * cam.up[1] + C[2] * cam.up[2],
        C[3] * cam.up[0] + C[4] * cam.up[1] + C[5] * cam.up[2],
        C[6] * cam.up[0] + C[7] * cam.up[1] + C[8] * cam.up[2]
      ];
      var sa = dot3(cam.right, Cr) * k * k + PIX_FLOOR;
      var sb = -dot3(cam.right, Cu) * k * k;
      var sd = dot3(cam.up, Cu) * k * k + PIX_FLOOR;

      var det = sa * sd - sb * sb;
      if (det < 1e-12) det = 1e-12;
      var ia = sd / det, ib = -sb / det, id = sa / det;

      var ru = 3.5 * Math.sqrt(sa), rv = 3.5 * Math.sqrt(sd);
      var x0 = Math.max(0, Math.floor(mu - ru));
      var x1 = Math.min(IMG - 1, Math.ceil(mu + ru));
      var y0 = Math.max(0, Math.floor(mv - rv));
      var y1 = Math.min(IMG - 1, Math.ceil(mv + rv));

      for (var y = y0; y <= y1; y++) {
        var dy = y + 0.5 - mv;
        for (var x = x0; x <= x1; x++) {
          var dx = x + 0.5 - mu;
          var q = ia * dx * dx + 2 * ib * dx * dy + id * dy * dy;
          if (q < 24) img[y * IMG + x] += amp * Math.exp(-0.5 * q);
        }
      }
    }

    function renderTruth(cam, dotPos) {
      var img = new Float64Array(IMG * IMG);
      var C = [
        DOT_R * DOT_R, 0, 0,
        0, DOT_R * DOT_R, 0,
        0, 0, DOT_R * DOT_R
      ];
      renderInto(img, cam, dotPos, C, 1);
      return img;
    }

    function mse(a, b) {
      var s = 0;
      for (var i = 0; i < a.length; i++) {
        var d = a[i] - b[i];
        s += d * d;
      }
      return s / a.length;
    }

    // params: [x, y, z, log l00, l10, log l11, l20, l21, log l22]
    // C = L·Lᵀ with L lower-triangular, log-diagonal — always a valid
    // covariance, and a cigar can point ANY direction without a separate
    // rotation parameterization.
    function paramsToC(p) {
      var a = Math.exp(p[3]), b = p[4], c = Math.exp(p[5]);
      var d = p[6], e = p[7], f = Math.exp(p[8]);
      return [
        a * a, a * b, a * d,
        a * b, b * b + c * c, b * d + c * e,
        a * d, b * d + c * e, d * d + e * e + f * f
      ];
    }

    function initParams() {
      // The article's "fog": a vague isotropic blob, off-center.
      var s = Math.log(0.45);
      return new Float64Array([0.25, 0.8, -0.3, s, 0, s, 0, 0, s]);
    }

    // Camera rigs.
    //
    // count mode — the narrative's three: one nearly head-on; a second at
    // the same height ~50° around (position snaps, shape stays loose along
    // the shared depth-ish direction); a third from clearly above.
    var COUNT_CAMS = [
      cameraBasis(0.17, 0.1),
      cameraBasis(1.05, 0.1),
      cameraBasis(-0.8, 0.9)
    ];

    // rig mode — a one-sided capture, the honest miniature of a real shoot:
    // three cameras in a narrow ~5° arc, the "standing in the doorway"
    // shoot. "flat" holds one height — the three view rays are then nearly
    // parallel, so together they constrain little more than one camera
    // does. "spread" fans the same arc across three heights, which rotates
    // the unconstrained depth directions apart and triangulates via height
    // parallax instead. The arc is deliberately this narrow: measured
    // headless, even a 28° flat arc already triangulates depth well
    // (sin 25° ≈ 0.42 of full lateral sensitivity), and at 8° the flat
    // cigar still dissolved before the demo's 6000-step budget ran out.
    var RIGS = {
      flat: [cameraBasis(-0.04, 0.12), cameraBasis(0, 0.12), cameraBasis(0.04, 0.12)],
      spread: [cameraBasis(-0.04, 0.06), cameraBasis(0, 0.5), cameraBasis(0.04, 0.95)]
    };

    function makeTrainer(cams, dotPos) {
      var p = initParams();
      var m = new Float64Array(9);
      var v = new Float64Array(9);
      var t = 0;
      var LR = 0.045, B1 = 0.9, B2 = 0.999, EPS = 1e-8;
      var FD = 1e-3;
      var cameras = cams.slice();
      var dot = dotPos.slice();
      var targets = cameras.map(function (c) { return renderTruth(c, dot); });
      var scratch = new Float64Array(IMG * IMG);

      // Coarse-to-fine, the same move real pipelines make. Pixel-wise MSE
      // has no long-range position gradient: a small render that does not
      // overlap its target cannot feel which way to move — measured
      // headless, the 2nd-camera "snap" simply never happened; the blob
      // shrank on its plateau instead. So the LOSS compares blurred copies
      // of both sides — free in covariance space, since a blurred gaussian
      // is a gaussian — and the blur anneals away over ~600 steps. It
      // resets whenever the exam changes (cameras or dot), so the basin
      // re-widens exactly when the optimizer is farthest from the answer.
      var annealT = 0;
      var blurTargets = null;
      var blurB2 = 0;

      function blurVar() {
        var sigma = Math.max(0.02, 0.5 * Math.pow(0.994, annealT));
        return sigma * sigma;
      }

      function refreshBlur() {
        blurB2 = blurVar();
        if (!blurTargets || blurTargets.length !== cameras.length) {
          blurTargets = cameras.map(function () {
            return new Float64Array(IMG * IMG);
          });
        }
        var r2 = DOT_R * DOT_R + blurB2;
        var Ct = [r2, 0, 0, 0, r2, 0, 0, 0, r2];
        for (var i = 0; i < cameras.length; i++) {
          blurTargets[i].fill(0);
          renderInto(blurTargets[i], cameras[i], dot, Ct, 1);
        }
      }

      function lossAt(params) {
        if (!blurTargets) refreshBlur();
        var total = 0;
        var C = paramsToC(params);
        C[0] += blurB2;
        C[4] += blurB2;
        C[8] += blurB2;
        var mean = [params[0], params[1], params[2]];
        for (var i = 0; i < cameras.length; i++) {
          scratch.fill(0);
          renderInto(scratch, cameras[i], mean, C, 1);
          total += mse(scratch, blurTargets[i]);
        }
        return total / cameras.length;
      }

      function clamp(x, lo, hi) {
        return x < lo ? lo : x > hi ? hi : x;
      }

      // The search is confined to the room. Without this, Adam's
      // per-coordinate normalization drifts the blob at full learning-rate
      // speed along an unconstrained view ray — measured headless: 62
      // world units in 1500 steps, loss still ~0 (a perfect floater, but
      // one that leaves the demo). Worse, a blob outside every photo's
      // frame produces zero gradient, so adding cameras can never pull it
      // back. Clamped, the 1-camera cigar slides to the room's edge and
      // sits there — visibly at the wrong depth, still matching its photo.
      function confine() {
        p[0] = clamp(p[0], -1.3, 1.3);
        p[1] = clamp(p[1], 0.02, 1.6);
        p[2] = clamp(p[2], -1.3, 1.3);
        var lo = Math.log(0.02), hi = Math.log(1.1);
        p[3] = clamp(p[3], lo, hi);
        p[5] = clamp(p[5], lo, hi);
        p[8] = clamp(p[8], lo, hi);
        p[4] = clamp(p[4], -1.1, 1.1);
        p[6] = clamp(p[6], -1.1, 1.1);
        p[7] = clamp(p[7], -1.1, 1.1);
      }

      function step() {
        t++;
        annealT++;
        refreshBlur();
        for (var k = 0; k < 9; k++) {
          var keep = p[k];
          p[k] = keep + FD;
          var up = lossAt(p);
          p[k] = keep - FD;
          var dn = lossAt(p);
          p[k] = keep;
          var g = (up - dn) / (2 * FD);
          m[k] = B1 * m[k] + (1 - B1) * g;
          v[k] = B2 * v[k] + (1 - B2) * g * g;
          var mh = m[k] / (1 - Math.pow(B1, t));
          var vh = v[k] / (1 - Math.pow(B2, t));
          p[k] -= (LR * mh) / (Math.sqrt(vh) + EPS);
        }
        confine();
        return lossAt(p);
      }

      return {
        step: step,
        loss: function () { return lossAt(p); },
        steps: function () { return t; },
        params: function () { return p; },
        mean: function () { return [p[0], p[1], p[2]]; },
        cov: function () { return paramsToC(p); },
        dot: function () { return dot.slice(); },
        cameras: function () { return cameras; },
        // Changing the camera set keeps the learned parameters — watching
        // the wrong answer get corrected IS the demo.
        setCameras: function (next) {
          cameras = next.slice();
          targets = cameras.map(function (c) { return renderTruth(c, dot); });
          annealT = 0;
          blurTargets = null;
        },
        setDot: function (next) {
          dot = next.slice();
          targets = cameras.map(function (c) { return renderTruth(c, dot); });
          annealT = 0;
          blurTargets = null;
        },
        renderCurrent: function (i, out) {
          out.fill(0);
          renderInto(out, cameras[i], [p[0], p[1], p[2]], paramsToC(p), 1);
        },
        target: function (i) { return targets[i]; },
        reset: function () {
          p = initParams();
          m = new Float64Array(9);
          v = new Float64Array(9);
          t = 0;
          annealT = 0;
          blurTargets = null;
        }
      };
    }

    // Error split along a reference frame: the first camera's view ray,
    // the horizontal axis across it, and world-vertical. Position error and
    // extent error are combined per axis — a blob in the right place but
    // smeared along the ray scores as "along the ray" error, same as one
    // sitting at the wrong depth.
    function axisErrors(trainer, refCam) {
      var pm = trainer.mean();
      var dt = trainer.dot();
      var dp = [pm[0] - dt[0], pm[1] - dt[1], pm[2] - dt[2]];
      var C = trainer.cov();
      var axes = {
        along: refCam.fwd,
        across: norm3(cross(refCam.fwd, [0, 1, 0])),
        vertical: [0, 1, 0]
      };
      var out = {};
      for (var name in axes) {
        var a = axes[name];
        var Ca = [
          C[0] * a[0] + C[1] * a[1] + C[2] * a[2],
          C[3] * a[0] + C[4] * a[1] + C[5] * a[2],
          C[6] * a[0] + C[7] * a[1] + C[8] * a[2]
        ];
        var extent = Math.sqrt(Math.max(dot3(a, Ca), 0));
        out[name] = Math.abs(dot3(a, dp)) + Math.abs(extent - DOT_R);
      }
      return out;
    }

    return {
      IMG: IMG,
      SPAN: SPAN,
      DOT_R: DOT_R,
      cameraBasis: cameraBasis,
      renderInto: renderInto,
      renderTruth: renderTruth,
      mse: mse,
      paramsToC: paramsToC,
      initParams: initParams,
      makeTrainer: makeTrainer,
      axisErrors: axisErrors,
      COUNT_CAMS: COUNT_CAMS,
      RIGS: RIGS,
      norm3: norm3,
      cross: cross,
      dot3: dot3
    };
  })();

  function bootSplatTrainer(root) {
    if (root.__pkBooted) return;
    root.__pkBooted = true;
    ensureStyle();
    root.textContent = "";

    var M = trainerMath;
    var mode = root.dataset.mode === "rig" ? "rig" : "count";
    var camCount = { "1": 1, "2": 2, "3": 3 }[root.dataset.cameras] || 1;
    var rig = "flat";
    var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    var state = {
      dot: [0.35, 0.55, 0.2],
      view: 0.55,
      viewEl: 0.38,
      orbiting: !reducedMotion,
      training: false,
      raf: null,
      losses: [],
      stepsPerFrame: 3
    };

    function activeCams() {
      if (mode === "rig") return M.RIGS[rig];
      return M.COUNT_CAMS.slice(0, camCount);
    }

    var trainer = M.makeTrainer(activeCams(), state.dot);

    // ── DOM ──
    var stage = el("div", "pk-splatt__stage", root);
    var truth = el("canvas", "pk-splatt__truth", stage);
    var side = el("div", "pk-splatt__side", stage);
    var shots = el("div", "pk-splatt__shots", side);
    var lossCanvas = el("canvas", "pk-splatt__loss", side);
    var bars = el("div", "pk-splatt__bars", side);
    var controls = el("div", "pk-splatt__controls", root);
    var caption = el("div", "pk-splatt__caption", root);
    caption.textContent =
      mode === "rig"
        ? "Same optimizer, same one-sided shoot — the only change is " +
          "whether the three cameras share a height. Watch the error bars."
        : "Left: the room, the red dot, and the blob being fitted. Right: " +
          "what the optimizer actually sees — its renders vs. the photos, " +
          "and the loss. Drag the dot; drag empty space to orbit.";

    var barEls = {};
    [["along", "along the ray"], ["across", "across the ray"], ["vertical", "vertical"]]
      .forEach(function (pair) {
        var row = el("div", "pk-splatt__barrow", bars);
        el("span", "pk-splatt__barlabel", row).textContent = pair[1];
        var track = el("div", "pk-splatt__bartrack", row);
        barEls[pair[0]] = el("div", "pk-splatt__bar", track);
      });

    var shotBlocks = [];

    function rebuildShots() {
      shots.textContent = "";
      shotBlocks = [];
      var cams = trainer.cameras();
      for (var i = 0; i < cams.length; i++) {
        var block = el("div", "pk-splatt__shot", shots);
        var pairEl = el("div", "pk-splatt__pair", block);
        var tgt = el("canvas", "pk-splatt__mini", pairEl);
        var cur = el("canvas", "pk-splatt__mini", pairEl);
        tgt.width = M.IMG; tgt.height = M.IMG;
        cur.width = M.IMG; cur.height = M.IMG;
        el("div", null, block).textContent = "photo " + (i + 1) + " · render";
        shotBlocks.push({ tgt: tgt, cur: cur });
      }
    }

    // Grayscale float image -> tinted pixels. The photos are red (they are
    // photos of the red dot); the optimizer's renders are blue, so a
    // mismatch is legible at a glance.
    function paintMini(canvas, img, r, g, b) {
      var ctx = canvas.getContext("2d");
      var data = ctx.createImageData(M.IMG, M.IMG);
      for (var i = 0; i < img.length; i++) {
        var a = Math.max(0, Math.min(1, img[i]));
        data.data[i * 4] = r * a + 13 * (1 - a);
        data.data[i * 4 + 1] = g * a + 15 * (1 - a);
        data.data[i * 4 + 2] = b * a + 20 * (1 - a);
        data.data[i * 4 + 3] = 255;
      }
      ctx.putImageData(data, 0, 0);
    }

    var scratch = new Float64Array(M.IMG * M.IMG);

    function paintShots() {
      var cams = trainer.cameras();
      for (var i = 0; i < cams.length; i++) {
        paintMini(shotBlocks[i].tgt, trainer.target(i), 255, 75, 75);
        trainer.renderCurrent(i, scratch);
        paintMini(shotBlocks[i].cur, scratch, 96, 165, 250);
      }
    }

    function paintLoss() {
      var ctx = lossCanvas.getContext("2d");
      var w = lossCanvas.width, h = lossCanvas.height;
      ctx.fillStyle = "#0d0f14";
      ctx.fillRect(0, 0, w, h);
      var n = state.losses.length;
      if (n < 2) return;
      ctx.strokeStyle = "#e58f5a";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      for (var i = 0; i < n; i++) {
        // log scale: losses span orders of magnitude or the curve is a wall
        var y = Math.log10(Math.max(state.losses[i], 1e-9));
        var py = ((y + 9) / 9) * h;
        var px = (i / (n - 1)) * w;
        if (i === 0) ctx.moveTo(px, h - py);
        else ctx.lineTo(px, h - py);
      }
      ctx.stroke();
    }

    function paintBars() {
      var errs = M.axisErrors(trainer, trainer.cameras()[0]);
      for (var name in barEls) {
        // Log scale, 1e-3..~1.5 -> 0..100%. The interesting differences
        // span orders of magnitude (the 3rd camera improves the along-ray
        // fit ~300x); on a linear bar they would all read as "small".
        var lg = Math.log10(Math.max(errs[name], 1e-3));
        var pct = Math.max(0, Math.min(100, ((lg + 3) / 3.2) * 100));
        barEls[name].style.width = pct + "%";
      }
    }

    // ── truth panel ──
    function viewBasis() {
      var cy = Math.cos(state.view), sy = Math.sin(state.view);
      var ce = Math.cos(state.viewEl), se = Math.sin(state.viewEl);
      var fwd = [-sy * ce, -se, -cy * ce];
      var right = M.norm3(M.cross(fwd, [0, 1, 0]));
      var up = M.cross(right, fwd);
      return { fwd: fwd, right: right, up: up };
    }

    function project(basis, p, cx, cy, u) {
      return [
        cx + M.dot3(basis.right, p) * u,
        cy - M.dot3(basis.up, p) * u
      ];
    }

    function drawTruth() {
      var ctx = truth.getContext("2d");
      var w = truth.width, h = truth.height;
      ctx.clearRect(0, 0, w, h);
      var cx = w / 2, cy = h / 2 + h * 0.06;
      var u = Math.min(w, h) / 3.4;
      var B = viewBasis();

      // floor grid at y=0
      ctx.strokeStyle = "rgba(140,150,170,0.18)";
      ctx.lineWidth = 1;
      for (var g = -2; g <= 2; g++) {
        var a = project(B, [g * 0.6, 0, -1.2], cx, cy, u);
        var b = project(B, [g * 0.6, 0, 1.2], cx, cy, u);
        ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
        a = project(B, [-1.2, 0, g * 0.6], cx, cy, u);
        b = project(B, [1.2, 0, g * 0.6], cx, cy, u);
        ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
      }

      var cams = trainer.cameras();
      var dotP = trainer.dot();

      // view rays through the dot, drawn past it — "the answer is
      // somewhere along this line" is the 1-camera lesson made visible
      ctx.strokeStyle = "rgba(255,105,97,0.28)";
      for (var i = 0; i < cams.length; i++) {
        var cp = cams[i].pos;
        var dir = M.norm3([dotP[0] - cp[0], dotP[1] - cp[1], dotP[2] - cp[2]]);
        var far = [cp[0] + dir[0] * 5.2, cp[1] + dir[1] * 5.2, cp[2] + dir[2] * 5.2];
        var a2 = project(B, cp, cx, cy, u);
        var b2 = project(B, far, cx, cy, u);
        ctx.beginPath(); ctx.moveTo(a2[0], a2[1]); ctx.lineTo(b2[0], b2[1]); ctx.stroke();
      }

      // cameras
      ctx.fillStyle = "#9fb0cf";
      for (i = 0; i < cams.length; i++) {
        var sp = project(B, cams[i].pos, cx, cy, u);
        ctx.beginPath();
        ctx.arc(sp[0], sp[1], 4.5, 0, TAU);
        ctx.fill();
        ctx.font = "10px system-ui, sans-serif";
        ctx.fillText(String(i + 1), sp[0] + 7, sp[1] + 3);
      }

      // fitted blob: project world covariance through the orbit view
      var C = trainer.cov();
      var mean = trainer.mean();
      var Cr = [
        C[0] * B.right[0] + C[1] * B.right[1] + C[2] * B.right[2],
        C[3] * B.right[0] + C[4] * B.right[1] + C[5] * B.right[2],
        C[6] * B.right[0] + C[7] * B.right[1] + C[8] * B.right[2]
      ];
      var Cu = [
        C[0] * B.up[0] + C[1] * B.up[1] + C[2] * B.up[2],
        C[3] * B.up[0] + C[4] * B.up[1] + C[5] * B.up[2],
        C[6] * B.up[0] + C[7] * B.up[1] + C[8] * B.up[2]
      ];
      var e = eig2(
        M.dot3(B.right, Cr) * u * u,
        -M.dot3(B.right, Cu) * u * u,
        M.dot3(B.up, Cu) * u * u
      );
      var mp = project(B, mean, cx, cy, u);
      ctx.save();
      ctx.translate(mp[0], mp[1]);
      ctx.rotate(e.angle);
      ctx.scale(Math.max(e.r1, 2), Math.max(e.r2, 2));
      var grad = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
      grad.addColorStop(0, "rgba(96,165,250,0.85)");
      grad.addColorStop(0.5, "rgba(96,165,250,0.4)");
      grad.addColorStop(1, "rgba(96,165,250,0)");
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.arc(0, 0, 1, 0, TAU);
      ctx.fill();
      ctx.restore();

      // truth dot, on top
      var dp = project(B, dotP, cx, cy, u);
      ctx.fillStyle = "#ff4b4b";
      ctx.beginPath();
      ctx.arc(dp[0], dp[1], 5, 0, TAU);
      ctx.fill();
    }

    // ── controls ──
    function button(label, on) {
      var b = el("button", "pk-splatt__btn", controls);
      b.type = "button";
      b.textContent = label;
      b.addEventListener("click", on);
      return b;
    }

    var trainBtn;

    function setTraining(next) {
      state.training = next;
      trainBtn.textContent = next ? "pause" : "train";
      trainBtn.classList.toggle("pk-splatt__btn--on", next);
    }

    var groupBtns = [];

    function refreshGroup() {
      groupBtns.forEach(function (entry) {
        entry.btn.classList.toggle("pk-splatt__btn--on", entry.test());
      });
    }

    if (mode === "count") {
      [1, 2, 3].forEach(function (n) {
        var b = button(n + (n === 1 ? " camera" : " cameras"), function () {
          camCount = n;
          trainer.setCameras(activeCams());
          rebuildShots();
          refreshGroup();
        });
        groupBtns.push({ btn: b, test: function () { return camCount === n; } });
      });
    } else {
      camCount = 3;
      [["flat", "one height"], ["spread", "three heights"]].forEach(function (pair) {
        var b = button(pair[1], function () {
          rig = pair[0];
          trainer.setCameras(activeCams());
          rebuildShots();
          refreshGroup();
        });
        groupBtns.push({ btn: b, test: function () { return rig === pair[0]; } });
      });
    }

    trainBtn = button("train", function () {
      setTraining(!state.training);
    });

    button("reset", function () {
      trainer.reset();
      state.losses = [];
      drawAll();
    });

    slider(controls, "dot height", 0.15, 1.5, 0.05, state.dot[1], function (v) {
      state.dot[1] = v;
      trainer.setDot(state.dot);
    });

    refreshGroup();

    // ── interaction: drag the dot, or drag space to orbit ──
    var drag = null;

    truth.addEventListener("pointerdown", function (ev) {
      var rect = truth.getBoundingClientRect();
      var scale = truth.width / rect.width;
      var mx = (ev.clientX - rect.left) * scale;
      var my = (ev.clientY - rect.top) * scale;
      var cx = truth.width / 2, cy = truth.height / 2 + truth.height * 0.06;
      var u = Math.min(truth.width, truth.height) / 3.4;
      var B = viewBasis();
      var dp = project(B, trainer.dot(), cx, cy, u);
      var grabbing = Math.hypot(mx - dp[0], my - dp[1]) < 20 * scale;
      drag = grabbing
        ? { kind: "dot" }
        : { kind: "orbit", x: ev.clientX, view: state.view };
      if (grabbing) moveDot(ev);
      state.orbiting = false;
      truth.setPointerCapture(ev.pointerId);
    });

    function moveDot(ev) {
      var rect = truth.getBoundingClientRect();
      var scale = truth.width / rect.width;
      var mx = (ev.clientX - rect.left) * scale;
      var my = (ev.clientY - rect.top) * scale;
      var cx = truth.width / 2, cy = truth.height / 2 + truth.height * 0.06;
      var u = Math.min(truth.width, truth.height) / 3.4;
      var B = viewBasis();
      // Orthographic un-project: the screen point is a line along fwd;
      // intersect it with the horizontal plane at the dot's height.
      var a = (mx - cx) / u;
      var b = -(my - cy) / u;
      var q = [
        a * B.right[0] + b * B.up[0],
        a * B.right[1] + b * B.up[1],
        a * B.right[2] + b * B.up[2]
      ];
      var y0 = state.dot[1];
      if (Math.abs(B.fwd[1]) < 0.05) return;
      var t = (y0 - q[1]) / B.fwd[1];
      var px = Math.max(-1.05, Math.min(1.05, q[0] + t * B.fwd[0]));
      var pz = Math.max(-1.05, Math.min(1.05, q[2] + t * B.fwd[2]));
      state.dot[0] = px;
      state.dot[2] = pz;
      trainer.setDot(state.dot);
    }

    truth.addEventListener("pointermove", function (ev) {
      if (!drag) return;
      if (drag.kind === "dot") {
        moveDot(ev);
      } else {
        state.view = drag.view - (ev.clientX - drag.x) * 0.008;
      }
      if (!state.raf) drawAll();
    });

    truth.addEventListener("pointerup", function () { drag = null; });
    truth.addEventListener("pointercancel", function () { drag = null; });

    // ── sizing / loop ──
    function resize() {
      var width = stage.clientWidth || 640;
      var truthWidth = truth.clientWidth || Math.round(width * 0.6);
      var height = Math.round(Math.max(truthWidth * 0.72, 230));
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      truth.width = Math.round(truthWidth * dpr);
      truth.height = Math.round(height * dpr);
      truth.style.height = height + "px";
      var lw = lossCanvas.clientWidth || 200;
      lossCanvas.width = Math.round(lw * dpr);
      lossCanvas.height = Math.round(52 * dpr);
    }

    function drawAll() {
      drawTruth();
      paintShots();
      paintLoss();
      paintBars();
    }

    function frame() {
      state.raf = null;
      var busy = false;

      if (state.training) {
        var loss = 0;
        for (var s = 0; s < state.stepsPerFrame; s++) loss = trainer.step();
        state.losses.push(loss);
        if (state.losses.length > 260) state.losses.shift();
        busy = true;
        // A converged fit burning battery forever helps nobody.
        if (trainer.steps() > 6000) setTraining(false);
      }

      if (state.orbiting) {
        state.view = (state.view + 0.003) % TAU;
        busy = true;
      }

      drawAll();
      if (busy) state.raf = requestAnimationFrame(frame);
    }

    function wake() {
      if (!state.raf && (state.training || state.orbiting)) {
        state.raf = requestAnimationFrame(frame);
      }
    }

    // Watching the fit happen is the content, so training starts itself
    // when the demo scrolls into view — except under reduced motion, where
    // nothing moves until asked.
    if (typeof IntersectionObserver !== "undefined" && !reducedMotion) {
      var io = new IntersectionObserver(function (entries) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].isIntersecting && trainer.steps() === 0 && !state.training) {
            setTraining(true);
            wake();
          }
        }
      }, { threshold: 0.35 });
      io.observe(root);
      root.__pkIntersection = io;
    }

    // Train/pause clicks need to restart the loop when it idled out.
    trainBtn.addEventListener("click", wake);

    rebuildShots();
    resize();
    drawAll();
    wake();

    if (typeof ResizeObserver !== "undefined") {
      var ro = new ResizeObserver(function () {
        resize();
        drawAll();
      });
      ro.observe(root);
      root.__pkObserver = ro;
    }

    root.__pkTeardown = function () {
      if (state.raf) cancelAnimationFrame(state.raf);
      state.training = false;
      state.orbiting = false;
      if (root.__pkObserver) root.__pkObserver.disconnect();
      if (root.__pkIntersection) root.__pkIntersection.disconnect();
    };
  }

  function bootAll() {
    var nodes = document.querySelectorAll("[data-pk-splat-gaussian]");
    for (var i = 0; i < nodes.length; i++) bootSplatGaussian(nodes[i]);
    nodes = document.querySelectorAll("[data-pk-splat-trainer]");
    for (i = 0; i < nodes.length; i++) bootSplatTrainer(nodes[i]);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bootAll);
  } else {
    bootAll();
  }

  return {
    // Same boots, as hooks, for live contexts (the editor preview). The
    // dead-page scan and these are idempotent together via __pkBooted.
    PubSplatGaussian: {
      mounted: function () {
        bootSplatGaussian(this.el);
      },
      destroyed: function () {
        if (this.el.__pkTeardown) this.el.__pkTeardown();
      }
    },
    PubSplatTrainer: {
      mounted: function () {
        bootSplatTrainer(this.el);
      },
      destroyed: function () {
        if (this.el.__pkTeardown) this.el.__pkTeardown();
      }
    },
    // Not a public API. The trainer's pure math, exposed so the claims the
    // article makes about it ("one camera fits the photo perfectly and the
    // 3D is wrong", "the second camera snaps position into place") can be
    // re-verified headless against the SHIPPED optimizer, not a
    // re-implementation of it.
    __splatTrainerMath: trainerMath
  };
})();
