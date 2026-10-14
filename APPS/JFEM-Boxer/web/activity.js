/* Shared, bounded activity display. CSS animation remains composited during JIT/render work. */
(function (root) {
  "use strict";
  const jobs = new Map(); let next = 0, timer = null, notice = null, noticeTimer = null;
  const now = () => performance.now();
  const byId = id => document.getElementById(id);
  function elapsed(milliseconds) {
    const seconds = Math.max(0, Math.floor(milliseconds / 1000));
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
  }
  function draw() {
    const panel = byId("activity-status"); if (!panel) return;
    const job = Array.from(jobs.values()).at(-1) || notice;
    panel.hidden = !job;
    panel.setAttribute("aria-busy", String(!!jobs.size&&job?.state!=="error"));
    if (!job) return;
    byId("activity-label").textContent = job.label;
    byId("activity-detail").textContent = job.detail || "Working…";
    byId("activity-time").textContent = elapsed((job.finished ?? now()) - job.started);
    byId("activity-time").setAttribute("aria-label","Total task elapsed time, including preparation and any compilation: "+elapsed((job.finished ?? now()) - job.started));
    panel.dataset.category = ["numerical","loading"].includes(job.category) ? job.category : "preparation";
    panel.dataset.state = job.state || "running";
    panel.title = job.state==="completed"?"Completed.":job.state==="error"?"Operation failed; see Log for details.":job.category === "loading"?"Blue: loading the cached solver. This is startup work, not measured numerical execution.":job.category === "numerical" ? "Blue: numerical solver phase. Elapsed time can include Julia compilation; completed timings separate it." : "Orange: preparation, declared compilation, or input/output.";
    panel.classList.toggle("activity-blocking", !!job.blocking);
    let close=byId('activity-dismiss');
    if(!close){close=document.createElement('button');close.id='activity-dismiss';close.type='button';close.textContent='×';close.setAttribute('aria-label','Dismiss activity notice');close.title='Dismiss this completed or failed activity notice';close.onclick=dismiss;panel.append(close);}
    close.hidden=!!jobs.size||!notice||!['completed','error','failed','cancelled'].includes(notice.state);
  }
  function begin(label, options = {}) {
    if(noticeTimer){clearTimeout(noticeTimer);noticeTimer=null;}notice=null;
    const token = "activity-" + ++next;
    jobs.set(token, {label, detail:"", started:now(), ...options});
    if (!timer) timer = setInterval(draw, 250);
    draw(); return token;
  }
  function update(token, patch) { const job = jobs.get(token); if (job) { Object.assign(job, patch); draw(); } }
  function end(token, options = {}) {
    const job=jobs.get(token);if (!jobs.delete(token)) return;
    if (!jobs.size && timer) { clearInterval(timer); timer = null; }
    draw();
    if (options.error) {
      const status = byId("mesh-status");
      if (status) { status.textContent = options.message || "Operation failed — see Log"; status.dataset.state = "invalid"; }
    }
    if(options.outcome)announce(options.label||job.label,{...options,started:job.started,state:options.outcome,detail:options.message||options.detail||job.detail});
  }
  function announce(label,options={}){
    if(noticeTimer)clearTimeout(noticeTimer);noticeTimer=null;
    notice={label,detail:"",started:now(),finished:now(),state:"completed",...options};
    if(!options.persistent)noticeTimer=setTimeout(()=>{notice=null;noticeTimer=null;draw();},options.duration??4500);draw();
  }
  function dismiss(){
    if(!notice||!['completed','error','failed','cancelled'].includes(notice.state))return false;
    if(noticeTimer)clearTimeout(noticeTimer);noticeTimer=null;notice=null;draw();return true;
  }
  function phase(progress={},options={}){
    const stage=progress.stage||progress.phase||"startup",category=["compile","compilation","precompile","package_precompilation"].includes(stage)?"preparation":progress.stage_category||"preparation";
    const names={startup:"Starting Julia and loading the solver",bootstrap:"Loading sensitivity worker",native_package_load:"Loading cached JFEM solver",precompile:"Precompiling Julia packages",parse:"Reading model input",export:"Writing solver results",unknown:"Waiting for solver phase"};
    const label=progress.stage_message||names[stage]||progress.detail||progress.message||"Waiting for solver phase";
    const completed=progress.stage_state==="completed",mixed=!completed&&category==="numerical"&&progress.compilation_live!=="excluded";
    const measured=value=>Number.isFinite(value)?value.toFixed(3)+" s":"unavailable";
    const detail=[progress.solution?"SOL"+progress.solution:null,progress.case_label?"Case "+progress.case_id+": "+progress.case_label:null,
      Number.isFinite(progress.target_percent)?"Attempting "+progress.target_percent.toFixed(1)+"% load; accepted "+(progress.accepted_percent||0).toFixed(1)+"%":null,
      progress.detail&&progress.detail!==label?progress.detail:progress.message&&progress.message!==label?progress.message:null,
      completed?"Stage complete. Measured compilation "+measured(progress.stage_timing?.compilation_seconds)+"; execution excluding compilation "+measured(progress.stage_timing?.execution_seconds)+".":mixed?"Julia compilation may occur; it is measured separately after this stage.":category==="numerical"&&progress.compilation_live==="excluded"?"Numerical execution; compilation excluded by the reported phase.":null,
      Number.isFinite(progress.stage_seconds)?Math.floor(Math.max(0,progress.stage_seconds))+" s in this stage":null].filter(Boolean).join(" · ");
    return {label:(options.sensitivity?"Sensitivity":"JFEM")+" · "+label,detail:detail||"Waiting for the next reported phase.",
      category:progress.stage_state==="completed"?"preparation":stage==='native_package_load'?'loading':category,compilationLive:progress.compilation_live,
      state:progress.stage_state==="failed"?"error":"running"};
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
  root.WingActivity = {begin, update, end, announce, dismiss, phase, yieldFrame, run, elapsed,
    get count() { return jobs.size; }};
  root.WingActivity.startup = begin("Starting JFEM-Boxer", {detail:"Loading the 3D viewer and parameter definitions…"});
  root.addEventListener("error", event => {
    if (!root.WingActivity.startup) return;
    const resource = event.target?.getAttribute?.("src");
    if (resource || event.error) {
      const token=root.WingActivity.startup;root.WingActivity.startup=null;
      end(token,{outcome:"error",label:"Startup interrupted",persistent:true,
        detail:resource ? "Could not load " + resource + ". Refresh this page to retry." : "See Log or refresh this page to retry."});
    }
  }, true);
})(window);
