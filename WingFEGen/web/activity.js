/* Shared, bounded activity display. CSS animation remains composited during JIT/render work. */
(function (root) {
  "use strict";
  const jobs = new Map(); let next = 0, timer = null;
  const now = () => performance.now();
  const byId = id => document.getElementById(id);
  function elapsed(milliseconds) {
    const seconds = Math.max(0, Math.floor(milliseconds / 1000));
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
  }
  function draw() {
    const panel = byId("activity-status"); if (!panel) return;
    const job = Array.from(jobs.values()).at(-1);
    panel.hidden = !job;
    panel.setAttribute("aria-busy", String(!!job));
    if (!job) return;
    byId("activity-label").textContent = job.label;
    byId("activity-detail").textContent = job.detail || "Working…";
    byId("activity-time").textContent = elapsed(now() - job.started);
    panel.classList.toggle("activity-blocking", !!job.blocking);
  }
  function begin(label, options = {}) {
    const token = "activity-" + ++next;
    jobs.set(token, {label, detail:"", started:now(), ...options});
    if (!timer) timer = setInterval(draw, 250);
    draw(); return token;
  }
  function update(token, patch) { const job = jobs.get(token); if (job) { Object.assign(job, patch); draw(); } }
  function end(token, options = {}) {
    if (!jobs.delete(token)) return;
    if (!jobs.size && timer) { clearInterval(timer); timer = null; }
    draw();
    if (options.error) {
      const status = byId("mesh-status");
      if (status) { status.textContent = options.message || "Operation failed — see Log"; status.dataset.state = "invalid"; }
    }
  }
  // A macrotask after rAF lets the browser paint the stage label before CPU work.
  const yieldFrame = () => new Promise(resolve => {
    let frame;
    // Background tabs can suspend rAF; a timer keeps downloads/builds progressing.
    const timer = setTimeout(() => { cancelAnimationFrame(frame); resolve(); }, 60);
    frame = requestAnimationFrame(() => { clearTimeout(timer); setTimeout(resolve, 0); });
  });
  async function run(label, action, options = {}) {
    const token = begin(label, options);
    try { await yieldFrame(); return await action(token); }
    finally { end(token); }
  }
  root.WingActivity = {begin, update, end, yieldFrame, run, elapsed,
    get count() { return jobs.size; }};
  root.WingActivity.startup = begin("Starting WingFEGen", {detail:"Loading the 3D viewer and parameter definitions…"});
  root.addEventListener("error", event => {
    if (!root.WingActivity.startup) return;
    const resource = event.target?.getAttribute?.("src");
    if (resource || event.error) {
      update(root.WingActivity.startup, {label:"Startup interrupted", detail:resource ? "Could not load " + resource + ". Refresh this page to retry." : "See Log or refresh this page to retry."});
    }
  }, true);
})(window);
