/* ==========================================================================
   Netmeter — speed test engine
   Drives the gauge, the live readout, the throughput chart and the results.
   Self-initialises against [data-speedtest]; does nothing if absent.
   ========================================================================== */

(function () {
  "use strict";

  var root = document.querySelector("[data-speedtest]");
  if (!root) return;

  var $ = function (sel) { return root.querySelector(sel); };
  var $$ = function (sel) { return Array.prototype.slice.call(root.querySelectorAll(sel)); };

  var COLOR = { download: "#00d4aa", upload: "#f0a13c", ping: "#d6d6d6", idle: "#00d4aa" };
  var PHASE_TEXT = {
    idle: "Ready",
    ping: "Measuring latency",
    download: "Testing download",
    upload: "Testing upload",
    done: "Test complete",
    stopped: "Stopped"
  };

  var SAMPLE_CAP = 120;
  var PING_SAMPLES = 8;
  var HISTORY_KEY = "nm.recent";
  var HISTORY_MAX = 6;
  var UPLOAD_CEILING = 100;
  var SAMPLE_INTERVAL = 0.22;

  /* down = advertised node capacity in Mbps; upload is always capped by UPLOAD_CEILING. */
  var SERVERS = [
    { id: "hkg", city: "Hong Kong", site: "HKIX", sponsor: "Netmeter APAC", down: 940, ping: 11, spread: 1.2 },
    { id: "sin", city: "Singapore", site: "SGIX", sponsor: "Netmeter APAC", down: 880, ping: 34, spread: 2.4 },
    { id: "nrt", city: "Tokyo", site: "JPIX", sponsor: "Netmeter Japan", down: 790, ping: 47, spread: 3.1 },
    { id: "lax", city: "Los Angeles", site: "Any2 West", sponsor: "Netmeter US", down: 640, ping: 148, spread: 6.8 },
    { id: "fra", city: "Frankfurt", site: "DE-CIX", sponsor: "Netmeter EU", down: 560, ping: 196, spread: 9.4 },
    { id: "syd", city: "Sydney", site: "Equinix SY1", sponsor: "Netmeter Oceania", down: 480, ping: 172, spread: 8.2 }
  ];

  var ISP_POOL = [
    { isp: "City Telecom", asn: "AS64500" },
    { isp: "Harbour Broadband", asn: "AS64501" },
    { isp: "Meridian Networks", asn: "AS64510" },
    { isp: "Northline Cable", asn: "AS64522" }
  ];

  var state = {
    server: SERVERS[0],
    isp: ISP_POOL[0],
    running: false,
    cancelled: false,
    phase: "idle",
    result: { down: null, up: null, ping: null, jitter: null },
    history: []
  };

  var el = {
    value: $("#value"),
    unit: $("#unit"),
    phase: $("#phase"),
    live: $("#gaugeLive"),
    prog: $("#prog"),
    glow: $("#progGlow"),
    ticks: $("#ticks"),
    goBtn: $("#goBtn"),
    serverName: $("#serverName"),
    serverPick: $("#serverPick"),
    srvList: $("#srvList"),
    rPing: $("#rPing"),
    rJitter: $("#rJitter"),
    rDown: $("#rDown"),
    rUp: $("#rUp"),
    historyBody: $("#historyBody"),
    chartLabel: $("#chartLabel"),
    chartLegend: $("#chartLegend"),
    canvas: $("#wave"),
    clientIsp: $("#clientIsp"),
    clientAsn: $("#clientAsn"),
    clientIp: $("#clientIp"),
    copyBtn: $("#copyBtn"),
    copyNote: $("#copyNote")
  };

  if (!el.canvas) return;
  var ctx = el.canvas.getContext("2d");

  var samples = [];
  var chart = { w: 0, h: 0 };
  var liveText = "";
  var lastFrame = 0;
  var sampleClock = 0;
  var drift = { value: 0, target: 0, timer: 0 };

  var gauge = {
    value: 0,
    target: 0,
    progress: 0,
    progressTarget: 0,
    color: COLOR.idle
  };

  /* ---------- helpers ---------- */

  function rand(min, max) { return min + Math.random() * (max - min); }
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function fixed(n, d) { return n.toFixed(d); }

  function hexToRgba(hex, alpha) {
    var v = parseInt(hex.slice(1), 16);
    return "rgba(" + ((v >> 16) & 255) + "," + ((v >> 8) & 255) + "," + (v & 255) + "," + alpha + ")";
  }

  function niceMax(v) {
    if (v <= 10) return 10;
    var step = Math.pow(10, Math.floor(Math.log10(v)));
    return Math.ceil(v / step) * step;
  }

  function fmtAxis(v) {
    if (v >= 1000) return (v / 1000).toFixed(1).replace(/\.0$/, "") + "G";
    return String(Math.round(v));
  }

  function sleep(ms) {
    return new Promise(function (resolve) { window.setTimeout(resolve, ms); });
  }

  /* ---------- gauge ---------- */

  function buildTicks() {
    if (!el.ticks) return;
    var svgNs = "http://www.w3.org/2000/svg";
    var frag = document.createDocumentFragment();
    for (var i = 0; i <= 44; i++) {
      var major = i % 5 === 0;
      var angle = (135 + (270 * i) / 44) * Math.PI / 180;
      var r1 = major ? 133 : 136;
      var r2 = 141;
      var line = document.createElementNS(svgNs, "line");
      line.setAttribute("x1", (150 + r1 * Math.cos(angle)).toFixed(2));
      line.setAttribute("y1", (150 + r1 * Math.sin(angle)).toFixed(2));
      line.setAttribute("x2", (150 + r2 * Math.cos(angle)).toFixed(2));
      line.setAttribute("y2", (150 + r2 * Math.sin(angle)).toFixed(2));
      line.setAttribute("stroke", major ? "rgba(255,255,255,0.28)" : "rgba(255,255,255,0.12)");
      line.setAttribute("stroke-width", "1");
      frag.appendChild(line);
    }
    el.ticks.appendChild(frag);
  }

  /* Compresses a linear rate onto the arc: 1000 Mbps fills the dial. */
  function rateToArc(v) {
    if (v <= 0) return 0;
    return Math.min(1, Math.log10(1 + v) / Math.log10(1 + 1000));
  }

  /* Latency uses only the first fifth of the arc, so a slow node stays readable. */
  function latencyToArc(v) {
    if (v <= 0) return 0;
    return 0.03 + Math.min(0.22, Math.log10(1 + v) / Math.log10(1 + 500) * 0.22);
  }

  function setArc(p, color) {
    if (color && color !== gauge.color) {
      gauge.color = color;
      el.prog.style.stroke = color;
      if (el.glow) el.glow.style.stroke = color;
      root.setAttribute("data-phase-color", color === COLOR.upload ? "upload" : "download");
    }
    var dash = (p * 100).toFixed(2) + " 100";
    el.prog.setAttribute("stroke-dasharray", dash);
    if (el.glow) el.glow.setAttribute("stroke-dasharray", dash);
  }

  function announce(text) {
    if (text === liveText) return;
    liveText = text;
    if (el.live) el.live.textContent = text;
  }

  function setPhase(name) {
    state.phase = name;
    if (el.phase) el.phase.textContent = PHASE_TEXT[name] || "Ready";
    root.setAttribute("data-phase", name);
    announce(PHASE_TEXT[name] || "Ready");
  }

  function setButton(mode) {
    el.goBtn.dataset.mode = mode;
    el.goBtn.textContent = mode === "running" ? "Stop test" : mode === "again" ? "Test again" : "Start test";
  }

  /* Result cells animate on change so a new figure lands instead of snapping. */
  function setResultCell(key, value, digits) {
    var target = { ping: el.rPing, jitter: el.rJitter, down: el.rDown, up: el.rUp }[key];
    if (!target) return;

    var next = value == null ? "—" : fixed(value, digits);
    if (target.textContent === next) return;
    target.textContent = next;

    if (value == null) return;
    var cell = target.closest(".result");
    if (!cell) return;

    cell.classList.remove("is-set");
    // Force a reflow so the animation can restart on repeated updates.
    void cell.offsetWidth;
    cell.classList.add("is-set");
  }

  /* ---------- chart ---------- */

  function sizeCanvas() {
    var rect = el.canvas.getBoundingClientRect();
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    chart.w = Math.max(1, rect.width);
    chart.h = Math.max(1, rect.height);
    el.canvas.width = Math.round(chart.w * dpr);
    el.canvas.height = Math.round(chart.h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function strokeCurve(pts) {
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    if (pts.length === 2) {
      ctx.lineTo(pts[1].x, pts[1].y);
      return;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      var xc = (pts[i].x + pts[i + 1].x) / 2;
      var yc = (pts[i].y + pts[i + 1].y) / 2;
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, xc, yc);
    }
    var last = pts[pts.length - 1];
    ctx.lineTo(last.x, last.y);
  }

  function drawChart() {
    var w = chart.w;
    var h = chart.h;
    if (!w || !h) return;
    ctx.clearRect(0, 0, w, h);

    var padTop = 10;
    var padBottom = 10;
    var padRight = 38;
    var plotH = h - padTop - padBottom;
    var plotW = Math.max(10, w - padRight);

    var peak = 0;
    for (var i = 0; i < samples.length; i++) if (samples[i] > peak) peak = samples[i];
    var vmax = niceMax(Math.max(peak * 1.16, 8));

    var mono = 'ui-monospace, "SF Mono", "Cascadia Mono", "DejaVu Sans Mono", monospace';
    ctx.font = "11px " + mono;
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";

    for (var g = 0; g <= 3; g++) {
      var y = padTop + (plotH * g) / 3;
      ctx.beginPath();
      ctx.moveTo(0, Math.round(y) + 0.5);
      ctx.lineTo(plotW, Math.round(y) + 0.5);
      ctx.strokeStyle = g === 0 ? "rgba(255,255,255,0.1)" : "rgba(255,255,255,0.055)";
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = "rgba(255,255,255,0.46)";
      ctx.fillText(fmtAxis(vmax * (1 - g / 3)), plotW + 8, y);
    }

    if (samples.length < 2) return;

    var offset = SAMPLE_CAP - samples.length;
    var pts = [];
    for (var s = 0; s < samples.length; s++) {
      var ratio = Math.min(1, samples[s] / vmax);
      var px = (plotW * (offset + s)) / (SAMPLE_CAP - 1);
      pts.push({
        x: Math.min(plotW, Math.max(0, px)),
        y: padTop + plotH - ratio * plotH
      });
    }

    var color = COLOR[state.phase === "upload" ? "upload" : "download"];

    var grad = ctx.createLinearGradient(0, padTop, 0, padTop + plotH);
    grad.addColorStop(0, hexToRgba(color, 0.2));
    grad.addColorStop(1, hexToRgba(color, 0));

    strokeCurve(pts);
    ctx.lineTo(pts[pts.length - 1].x, padTop + plotH);
    ctx.lineTo(pts[0].x, padTop + plotH);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    strokeCurve(pts);
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.8;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.stroke();

    var head = pts[pts.length - 1];
    ctx.beginPath();
    ctx.arc(head.x, head.y, 4.6, 0, Math.PI * 2);
    ctx.fillStyle = hexToRgba(color, 0.16);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(head.x, head.y, 2.4, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
  }

  /* Replaces the newest sample so the head dot moves every frame. */
  function pushSample(v, thin) {
    if (thin && samples.length) {
      samples[samples.length - 1] = v;
      return;
    }
    samples.push(v);
    if (samples.length > SAMPLE_CAP) samples.shift();
  }

  /* ---------- frame loop ---------- */

  function frame(now) {
    var dt = lastFrame ? Math.min(0.1, (now - lastFrame) / 1000) : 0.016;
    lastFrame = now;

    // Slow drift: a new normalised offset every 260-560 ms, eased between them,
    // so the readout keeps moving during the steady part of a transfer.
    if (state.running && state.phase !== "ping") {
      drift.timer -= dt;
      if (drift.timer <= 0) {
        drift.timer = 0.26 + Math.random() * 0.3;
        drift.target = (Math.random() - 0.5) * 2;
      }
    } else {
      drift.target = 0;
    }
    drift.value += (drift.target - drift.value) * (1 - Math.pow(0.02, dt));

    var driftAmp = state.phase === "upload" ? 0.035 : 0.014;
    var aim = gauge.target * (1 + drift.value * driftAmp);
    var gap = aim - gauge.value;
    if (Math.abs(gap) > 0.001) {
      gauge.value += gap * (1 - Math.pow(0.0035, dt));
    } else {
      gauge.value = aim;
    }
    gauge.progress += (gauge.progressTarget - gauge.progress) * (1 - Math.pow(0.0016, dt));

    if (state.phase === "ping") {
      el.value.textContent = fixed(gauge.value, 1);
      el.unit.textContent = "ms";
    } else if (gauge.value >= 1000) {
      el.value.textContent = fixed(gauge.value / 1000, 2);
      el.unit.textContent = "Gbps";
    } else {
      el.value.textContent = fixed(gauge.value, 2);
      el.unit.textContent = "Mbps";
    }
    setArc(Math.max(0, Math.min(1, gauge.progress)));

    if (state.running && state.phase !== "ping") {
      sampleClock += dt;
      if (sampleClock >= SAMPLE_INTERVAL) {
        sampleClock = 0;
        pushSample(gauge.target);
      } else {
        pushSample(gauge.target, true);
      }
    }

    drawChart();
    window.requestAnimationFrame(frame);
  }

  /* ---------- servers ---------- */

  function serverLabel(s) { return s.city + " — " + s.site; }

  function renderServerList() {
    if (!el.srvList) return;
    el.srvList.innerHTML = "";
    SERVERS.forEach(function (s) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "srv";
      btn.disabled = state.running;
      btn.setAttribute("role", "option");
      btn.setAttribute("aria-current", String(s.id === state.server.id));
      btn.innerHTML =
        '<span><span class="srv-name">' + s.city + "</span>" +
        '<span class="srv-sub">' + s.sponsor + " · " + s.down + " Mbps down</span></span>" +
        '<span class="srv-rtt">' + s.ping + " ms</span>";
      btn.addEventListener("click", function () {
        if (state.running) return;
        state.server = s;
        el.serverName.textContent = serverLabel(s);
        renderServerList();
        var dlg = document.getElementById("dlg-servers");
        if (dlg && dlg.open) dlg.close();
      });
      el.srvList.appendChild(btn);
    });
  }

  /* ---------- client info ---------- */

  /* Reserve-range address with a random last octet; a frozen address looks staged. */
  function fakeClientIp() {
    var prefixes = ["203.0.113.", "198.51.100.", "192.0.2."];
    return prefixes[Math.floor(Math.random() * prefixes.length)] + (10 + Math.floor(Math.random() * 230));
  }

  function renderClient() {
    if (el.clientIsp) el.clientIsp.textContent = state.isp.isp;
    if (el.clientAsn) el.clientAsn.textContent = state.isp.asn;
    if (el.clientIp) el.clientIp.textContent = fakeClientIp();
  }

  /* ---------- history ---------- */

  function loadHistory() {
    try {
      var raw = window.localStorage.getItem(HISTORY_KEY);
      var parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed.slice(0, HISTORY_MAX) : [];
    } catch (err) {
      return [];
    }
  }

  function saveHistory() {
    try {
      window.localStorage.setItem(HISTORY_KEY, JSON.stringify(state.history));
    } catch (err) { /* storage unavailable */ }
  }

  function fmtTime(ts) {
    var d = new Date(ts);
    var now = new Date();
    var sameDay = d.toDateString() === now.toDateString();
    var opts = sameDay
      ? { hour: "2-digit", minute: "2-digit", hour12: false }
      : { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false };
    return d.toLocaleString("en-GB", opts);
  }

  function renderHistory() {
    if (!el.historyBody) return;
    if (!state.history.length) {
      el.historyBody.innerHTML = '<tr class="empty"><td colspan="5">No tests yet.</td></tr>';
      return;
    }
    el.historyBody.innerHTML = state.history.map(function (row, index) {
      return '<tr style="--i:' + index + '">' +
        "<td>" + fmtTime(row.t) + "</td>" +
        "<td>" + row.server + "</td>" +
        '<td class="num">' + fixed(row.ping, 1) + "</td>" +
        '<td class="num">' + fixed(row.down, 2) + "</td>" +
        '<td class="num">' + fixed(row.up, 2) + "</td>" +
        "</tr>";
    }).join("");
  }

  /* ---------- test phases ---------- */

  /*
   * Latency: eight probes spaced 110-150 ms apart. Each drifts around the node
   * baseline so jitter is derived from actual variance rather than invented.
   */
  function pingPhase() {
    return new Promise(function (resolve) {
      var server = state.server;
      var vals = [];
      var index = 0;

      setPhase("ping");
      gauge.color = COLOR.ping;
      el.prog.style.stroke = COLOR.ping;
      if (el.glow) el.glow.style.stroke = COLOR.ping;
      gauge.value = 0;
      gauge.target = 0;
      gauge.progress = 0;
      gauge.progressTarget = 0;

      function probe() {
        if (state.cancelled) { resolve(null); return; }
        var v = Math.max(0.8, server.ping + (Math.random() - 0.5) * server.spread * 2.2);
        vals.push(v);
        index++;
        gauge.value = v;
        gauge.target = v;
        gauge.progress = latencyToArc(v);
        gauge.progressTarget = gauge.progress;
        setResultCell("ping", v, 1);
        announce("Probe " + index + " of " + PING_SAMPLES);

        if (index >= PING_SAMPLES) {
          var sum = 0;
          for (var i = 0; i < vals.length; i++) sum += vals[i];
          var avg = sum / vals.length;
          var acc = 0;
          for (var j = 0; j < vals.length; j++) acc += Math.pow(vals[j] - avg, 2);
          var jitter = Math.sqrt(acc / vals.length);

          state.result.ping = avg;
          state.result.jitter = jitter;
          setResultCell("ping", avg, 1);
          setResultCell("jitter", jitter, 1);
          gauge.value = avg;
          gauge.target = avg;
          gauge.progress = latencyToArc(avg);
          gauge.progressTarget = gauge.progress;
          window.setTimeout(function () { resolve(avg); }, 240);
          return;
        }
        window.setTimeout(probe, 110 + Math.random() * 40);
      }

      window.setTimeout(probe, 140);
    });
  }

  /*
   * Throughput: slow-start ramp plus per-frame noise, so the number never sits
   * still. Upload is hard-capped by UPLOAD_CEILING.
   */
  function transferPhase(kind) {
    return new Promise(function (resolve) {
      var server = state.server;
      var ceiling = kind === "upload" ? UPLOAD_CEILING : server.down;
      var target = ceiling * rand(0.72, 0.94);
      var noiseAmp = ceiling * (kind === "upload" ? 0.024 : 0.016);
      var settleAmp = ceiling * (kind === "upload" ? 0.014 : 0.009);
      var duration = kind === "upload" ? 9000 : 12000;
      var start = 0;
      var elapsed = 0;
      var tail = [];
      var tailFrom = duration * 0.55;
      var lastAnnounce = 0;
      var seed = Math.random() * 100;

      setPhase(kind);
      el.chartLabel.textContent = kind === "download" ? "Download" : "Upload";
      el.chartLegend.textContent = kind === "download" ? "Download" : "Upload";
      gauge.color = COLOR[kind];
      el.prog.style.stroke = COLOR[kind];
      if (el.glow) el.glow.style.stroke = COLOR[kind];

      // A real tester drops to zero between phases and ramps up again, so the
      // upload reading can never inherit the download peak.
      gauge.value = 0;
      gauge.target = 0;
      gauge.progress = 0;
      gauge.progressTarget = 0;

      // Paint the zero immediately: the frame loop may be throttled, and stale
      // DOM text would otherwise show the previous phase's peak.
      el.value.textContent = "0.00";
      el.unit.textContent = "Mbps";
      setArc(0);

      samples = [];
      sampleClock = 0;

      function tick(now) {
        if (state.cancelled) { resolve(null); return; }
        if (!start) start = now;
        elapsed = now - start;
        var t = Math.min(1, elapsed / duration);

        var ramp = easeOutCubic(Math.min(1, t / 0.3));
        var breath = Math.sin(t * Math.PI * 2.1 + seed) * 0.008;
        var wobble =
          Math.sin(elapsed / 137 + seed) * 0.55 +
          Math.sin(elapsed / 61 + seed * 1.7) * 0.3 +
          (Math.random() - 0.5) * 0.9;
        // Noise amplitude follows the ramp so the first moments stay clean.
        var amp = (t < 0.75 ? noiseAmp : settleAmp) * Math.min(1, ramp * 1.4);
        var value = target * ramp * (1 + breath) + wobble * amp;

        // Pull the value back toward the ramp instead of hard-clamping it: a
        // hard floor would freeze the readout during slow start.
        var expected = target * ramp;
        var lowBound = expected * 0.74;
        var highBound = ceiling * 0.985;
        value = Math.max(lowBound, Math.min(highBound, value));

        gauge.target = value;
        gauge.progressTarget = rateToArc(value);
        if (elapsed >= tailFrom) tail.push(value);

        if (elapsed - lastAnnounce >= 1500) {
          lastAnnounce = elapsed;
          announce((kind === "upload" ? "Upload" : "Download") + " " + Math.round(t * 100) + "%");
        }

        if (elapsed >= duration) {
          var sum = 0;
          for (var i = 0; i < tail.length; i++) sum += tail[i];
          var result = tail.length ? sum / tail.length : gauge.target;
          var cap = kind === "upload" ? UPLOAD_CEILING * 0.98 : ceiling * 0.985;
          resolve(Math.min(cap, result));
          return;
        }
        window.requestAnimationFrame(tick);
      }

      window.requestAnimationFrame(tick);
    });
  }

  function finishTest() {
    state.running = false;
    setButton("again");
    setPhase("done");
    gauge.target = state.result.down;
    gauge.progressTarget = rateToArc(state.result.down);
    setResultCell("down", state.result.down, 2);
    setResultCell("up", state.result.up, 2);
    el.chartLabel.textContent = "Throughput";
    el.chartLegend.textContent = "Last run";
    renderServerList();
    announce("Test complete");
    root.setAttribute("data-complete", "true");

    state.history.unshift({
      t: Date.now(),
      server: state.server.city,
      ping: state.result.ping,
      down: state.result.down,
      up: state.result.up
    });
    state.history = state.history.slice(0, HISTORY_MAX);
    saveHistory();
    renderHistory();
  }

  function abortTest() {
    state.running = false;
    setButton(state.result.down == null ? "idle" : "again");
    setPhase("stopped");
    el.chartLabel.textContent = "Throughput";
    el.chartLegend.textContent = "Last run";
    renderServerList();
  }

  function runTest() {
    state.running = true;
    state.cancelled = false;
    root.removeAttribute("data-complete");
    samples = [];
    sampleClock = 0;
    state.result = { down: null, up: null, ping: null, jitter: null };
    setButton("running");
    renderServerList();

    pingPhase().then(function (ping) {
      if (state.cancelled || ping == null) return null;
      return sleep(420).then(function () {
        if (state.cancelled) return null;
        return transferPhase("download");
      });
    }).then(function (down) {
      if (state.cancelled || down == null) return null;
      state.result.down = down;
      setResultCell("down", down, 2);
      return sleep(700).then(function () {
        if (state.cancelled) return null;
        return transferPhase("upload");
      });
    }).then(function (up) {
      if (state.cancelled || up == null) return null;
      state.result.up = Math.min(UPLOAD_CEILING, up);
      setResultCell("up", state.result.up, 2);
      finishTest();
    }).catch(function () {
      abortTest();
    });
  }

  /* ---------- wiring ---------- */

  el.goBtn.addEventListener("click", function () {
    if (state.running) {
      state.cancelled = true;
      abortTest();
      return;
    }
    runTest();
  });

  if (el.serverPick) {
    el.serverPick.addEventListener("click", function () {
      if (state.running) return;
      var dlg = document.getElementById("dlg-servers");
      if (dlg && typeof dlg.showModal === "function") dlg.showModal();
    });
  }

  if (el.copyBtn) {
    el.copyBtn.addEventListener("click", function () {
      if (state.result.down == null) {
        el.copyNote.textContent = "Run a test first";
        window.setTimeout(function () { el.copyNote.textContent = ""; }, 1800);
        return;
      }
      var text = [
        "Netmeter result",
        "Server: " + serverLabel(state.server),
        "Ping: " + fixed(state.result.ping, 1) + " ms (jitter " + fixed(state.result.jitter, 1) + " ms)",
        "Download: " + fixed(state.result.down, 2) + " Mbps",
        "Upload: " + fixed(state.result.up, 2) + " Mbps"
      ].join("\n");
      var done = function () {
        el.copyNote.textContent = "Copied";
        window.setTimeout(function () { el.copyNote.textContent = ""; }, 1800);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { el.copyNote.textContent = "Copy failed"; });
      } else {
        el.copyNote.textContent = "Copy unavailable";
      }
    });
  }

  var resizeTimer = 0;
  window.addEventListener("resize", function () {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(sizeCanvas, 120);
  });

  document.addEventListener("visibilitychange", function () {
    lastFrame = 0;
  });

  /* ---------- boot ---------- */

  buildTicks();
  el.serverName.textContent = serverLabel(state.server);
  state.isp = ISP_POOL[Math.floor(Math.random() * ISP_POOL.length)];
  renderClient();
  renderServerList();
  state.history = loadHistory();
  renderHistory();
  setPhase("idle");
  setButton("idle");
  sizeCanvas();
  window.requestAnimationFrame(frame);
})();
