(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingImportedAnalysis=api;})(globalThis,function(){
 'use strict';
 const DEFAULTS={solution:'source',follower:'source',modes:10,buckling_max_factor:100,load_steps:20,max_iterations:40,max_cutbacks:12,displacement_tolerance:1e-6,residual_tolerance:1e-5,buckling_output_override:false,buckling_deformation_energy:false,buckling_energy_density:false,buckling_compact:false};
 const OUTPUT_KEYS=['buckling_output_override','buckling_deformation_energy','buckling_energy_density','buckling_compact'];
 const outputOverride=value=>OUTPUT_KEYS.some(key=>value[key]);
 function options(raw){
  if(raw!=null&&(typeof raw!=='object'||Array.isArray(raw)))throw Error('Invalid imported analysis settings.');
  const value={...DEFAULTS,...raw};value.solution=String(value.solution);value.follower=String(value.follower);
  if(!['source','101','103','105','106'].includes(value.solution)||!['source','fixed','force'].includes(value.follower))throw Error('Unsupported imported analysis settings.');
  for(const key of Object.keys(DEFAULTS).filter(k=>typeof DEFAULTS[k]==='number'))if(!Number.isFinite(value[key])||value[key]<0)throw Error('Invalid '+key+' setting.');
  for(const key of OUTPUT_KEYS)if(typeof value[key]!=='boolean')throw Error('Invalid '+key+' setting.');
  value.buckling_deformation_energy=value.buckling_deformation_energy||value.buckling_energy_density;value.buckling_energy_density=false;
  if(outputOverride(value))value.buckling_output_override=true;
  return value.solution==='source'&&value.follower==='source'&&!outputOverride(value)?{...DEFAULTS}:Object.fromEntries(Object.keys(DEFAULTS).map(key=>[key,value[key]]));
 }
 function signature(deck){const value=options(deck?.source?.analysis);return value.solution==='source'&&value.follower==='source'&&!outputOverride(value)?deck.signature:deck.signature+'|'+JSON.stringify(value);}
 function solution(deck){const value=options(deck?.source?.analysis);return value.solution==='source'?String(deck.solution):value.solution;}
 function matches(raw,deck){return JSON.stringify(options(raw))===JSON.stringify(options(deck?.source?.analysis));}
 function cases(deck){return (deck.cases||[]).filter(row=>options(deck.source?.analysis).solution==='source'?row.result_required!==false:row.case_control?.STATSUB==null&&!String(row.analysis_role||'').startsWith('Buckling'));}
 function create({host,read,onChange}){
  host.innerHTML='<h2>Imported deck analysis</h2><label class="display-control">Solution <select data-key="solution"><option value="source">Original source solution</option><option value="101">SOL101 · linear static</option><option value="103">SOL103 · normal modes</option><option value="105">SOL105 · linear buckling</option><option value="106">SOL106 · nonlinear static</option></select></label><label class="display-control">Concentrated FORCE loads <select data-key="follower"><option value="source">Keep source follower settings</option><option value="fixed">Fixed directions</option><option value="force">Follower forces · FORCE ROT</option></select></label><p class="pick-note">Original geometry, properties, LOAD sets, SPCs and MPCs are preserved. The selected solution is written to a separate run deck. SOL105 creates a buckling companion for each original static case. Imported SOL106 runs that solution only. Save Study includes these settings; the original BDF text stays unchanged.</p><p class="pick-note">Follower mode rotates concentrated FORCE directions with nodal rotations: SOL101 uses the first-order load tangent; SOL106 updates directions during each iteration. MOMENT, pressure and body loads stay fixed. Follower forces are unavailable for SOL103/SOL105. Analysis → Sensitivity has its own SOL101, SOL103, SOL105 or SOL106 selector. SOL106 sensitivities currently support final-load displacement with fixed-direction loads and supported shell/CBAR formulations.</p><div data-eigen></div><div data-nonlinear></div><p data-note role="status"></p>';
  const abaqusInfo=document.createElement('div');abaqusInfo.dataset.abaqusInfo='';abaqusInfo.hidden=true;abaqusInfo.className='pick-note';host.querySelector('h2').after(abaqusInfo);
  const originalNotes=[...host.querySelectorAll(':scope > p.pick-note')];
  const eigenNote=document.createElement('div');eigenNote.dataset.eigenNote='';eigenNote.className='pick-note';host.querySelector('[data-eigen]').after(eigenNote);
  const outputs=document.createElement('div');outputs.dataset.bucklingOutputs='';eigenNote.after(outputs);
  for(const [key,label]of [['buckling_output_override','Override source SOL105 output settings'],['buckling_deformation_energy','Export element strain energy and density (ESE)'],['buckling_compact','Only eigenvalues and peak-node properties']]){
   const line=document.createElement('label');line.className='display-control';const input=document.createElement('input');input.type='checkbox';input.dataset.key=key;line.append(input,document.createTextNode(' '+label));outputs.append(line);
   if(key==='buckling_compact')line.title='PARAM,JFBKCOMP,1 is a JFEM-specific request for compact buckling output. It reduces exported data without changing the solve or eigenvalues. Eigenvectors are still computed internally to find peak GRID/property IDs. Leave it off, omit the PARAM or use 0 to keep the normal mode shapes, preload fields and contours. Enable the source override to change a compact request already present in an imported deck.';
   if(key==='buckling_deformation_energy')line.title='Writes ESE(PLOT) = ALL in Case Control, requesting both quantities. With the override enabled and this checkbox off, ESE = NONE suppresses energy output. Leave the override off to preserve source ESE requests and element SET selections.';
  }
  const outputNote=document.createElement('p');outputNote.className='pick-note';outputNote.textContent='Leave the override off to retain source output settings. Energy exports contain true ½uᵀKₑu and energy per physical element volume, separately for the static preload and each normalized buckling mode. Units follow the source deck: force × length and force / length² (J and J/m³ only for N-m inputs). Modal values depend on arbitrary eigenvector amplitude and are not physical postbuckling energy. Compact output retains eigenvalues and maximum-translation GRID IDs with directly incident property IDs; it intentionally omits mode vectors, preload fields and energy data. Unsupported energy/volume definitions are identified, never replaced with stress proxies.';outputs.append(outputNote);
  function numeric(parent,key,label,step){const line=document.createElement('label');line.className='display-control';line.textContent=label+' ';const input=document.createElement('input');input.type='number';input.dataset.key=key;input.step=String(step);input.min=key==='max_cutbacks'?'0':'0.00000000000001';line.append(input);parent.append(line);}
  for(const [key,label,step]of [['modes','Requested modes',1],['buckling_max_factor','Maximum buckling factor',1]])numeric(host.querySelector('[data-eigen]'),key,label,step);
  for(const [key,label,step]of [['load_steps','Initial load steps',1],['max_iterations','Iterations per step',1],['max_cutbacks','Maximum cutbacks',1],['displacement_tolerance','Displacement tolerance','any'],['residual_tolerance','Residual tolerance','any']])numeric(host.querySelector('[data-nonlinear]'),key,label,step);
  host.addEventListener('change',event=>{if(!event.target.dataset.key)return;try{const values=Object.fromEntries([...host.querySelectorAll('[data-key]')].map(el=>[el.dataset.key,el.type==='checkbox'?el.checked:el.type==='number'?Number(el.value):el.value]));if(event.target.dataset.key==='buckling_output_override'&&!event.target.checked)for(const key of OUTPUT_KEYS)values[key]=false;onChange(options(values));refresh();}catch(error){host.querySelector('[data-note]').textContent=error.message;}});
  function refresh(disabled=false){
   const deck=read();host.hidden=!deck;if(!deck)return;
   const value=options(deck.source?.analysis),sol=solution(deck),isAbaqus=deck.source_format==='abaqus'||deck.source?.format==='abaqus';
   abaqusInfo.hidden=!isAbaqus;
   if(isAbaqus){
    abaqusInfo.replaceChildren();const note=document.createElement('p');note.textContent=deck.analysis_ready===false?'This Abaqus file is a mesh-only or incomplete model. Inspect its named sets below. To solve a solid mesh, read it again and enable the explicit material, constraint and static/modal setup. No missing material or loading is invented.':'Abaqus analysis uses the authored input steps or the explicit setup saved with this Study. The original source and completion settings are retained. Reference-only solution/follower overlays are unavailable.';abaqusInfo.append(note);
    const meta=deck.abaqus||{};for(const [key,label]of [['nsets','Node sets'],['elsets','Element sets'],['surfaces','Surfaces']]){
     const entries=Object.entries(meta[key]||{});if(!entries.length)continue;const details=document.createElement('details'),summary=document.createElement('summary');summary.textContent=label+' ? '+entries.length;details.append(summary);
     for(const [name,items]of entries){const row=document.createElement('div');row.textContent=name+' ? '+(Array.isArray(items)?items.length:(items.entries||[]).length)+' '+(key==='nsets'?'nodes':key==='elsets'?'elements':'entries');row.title=Array.isArray(items)?items.slice(0,100).join(', ')+(items.length>100?', ...':''):JSON.stringify(items);details.append(row);}abaqusInfo.append(details);
    }
    const diagnostics=(meta.diagnostics||[]).filter(row=>row.message);if(diagnostics.length){const list=document.createElement('ul');for(const row of diagnostics){const item=document.createElement('li');item.textContent=(row.code?row.code+': ':'')+row.message;list.append(item);}abaqusInfo.append(list);}
   }
   for(const note of originalNotes)note.hidden=isAbaqus;
   for(const input of host.querySelectorAll('[data-key]')){if(input.type==='checkbox')input.checked=value[input.dataset.key];else input.value=value[input.dataset.key];input.disabled=disabled||isAbaqus||(OUTPUT_KEYS.slice(1).includes(input.dataset.key)&&!value.buckling_output_override)||(value.buckling_compact&&['buckling_deformation_energy','buckling_energy_density'].includes(input.dataset.key));}
   outputs.hidden=isAbaqus||sol!=='105';
   host.querySelector('[data-key="follower"]').closest('label').hidden=isAbaqus;
   host.querySelector('[data-eigen]').hidden=isAbaqus||!['103','105'].includes(value.solution);
   host.querySelector('[data-key="buckling_max_factor"]').closest('label').hidden=value.solution!=='105';
   host.querySelector('[data-nonlinear]').hidden=isAbaqus||value.solution!=='106';
   eigenNote.hidden=isAbaqus||!['103','105'].includes(sol);
   eigenNote.replaceChildren();
   if(!eigenNote.hidden){
    const explanation=document.createElement('p');
    if(value.solution==='source'){
     explanation.textContent='Original source solution retains its METHOD and EIGRL/EIGR cards, including their source limits and root counts. The source card values are shown in Deck. Selecting SOL103 or SOL105 here exposes the override settings and writes a new extraction request to the separate run deck; the original BDF text stays unchanged.';
     eigenNote.append(explanation);
    }else{
     const fields=document.createElement('p'),code=document.createElement('code');
     code.textContent='EIGRL | SID=new METHOD ID | V1='+(sol==='105'?'1e-6':'blank')+' | V2='+(sol==='105'?value.buckling_max_factor:'blank')+' | ND='+value.modes+' | NORM=MASS';fields.append(code);
     explanation.textContent='SID identifies the new METHOD request; ND is the requested root count. '+(sol==='105'?'V1 and V2 are positive dimensionless buckling load factors multiplying each source static preload, not frequencies in Hz. Fewer than ND roots may lie in the interval.':'SOL103 leaves both frequency bounds blank and requests mass-normalized normal modes.');
     eigenNote.append(fields,explanation);
    }
   }
   host.querySelector('[data-note]').textContent=isAbaqus?(deck.analysis_ready===false?'Analysis unavailable until the missing data are explicitly defined.':'Run '+(deck.solution_label||'SOL'+sol)+' on '+deck.name+'; original input steps are preserved.'):value.follower==='force'&&!['101','106'].includes(sol)?'Select fixed forces for SOL103/SOL105 before running.':'Run SOL'+sol+' on '+deck.name+'; no lifting surface geometry will be generated.';
  }
  return {refresh};
 }
 return {options,signature,solution,matches,cases,create};
});
