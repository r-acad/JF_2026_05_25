(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingStringerLayout=api;})(globalThis,function(){
 'use strict';
 function segments(points){
  const ordered=points.map((p,index)=>({...p,index})).sort((a,b)=>a.eta-b.eta),rows=[];
  ordered.forEach((p,i)=>rows.push({index:p.index,start:i?ordered[i-1].eta:0,end:p.eta===0&&ordered.length===1?1:p.eta,angle:p.stringer_angle??0,unused:p.eta===0&&ordered.length>1}));
  if(ordered.length&&ordered.at(-1).eta>0&&ordered.at(-1).eta<1)rows.push({index:ordered.at(-1).index,start:ordered.at(-1).eta,end:1,angle:ordered.at(-1).stringer_angle??0,inherited:true});
  return rows;
 }
 function install(host,{read,onEdit,isLocked=()=>false}){
  const doc=host.ownerDocument,section=doc.createElement('section');section.className='stringer-segment-angles';section.innerHTML='<h3>Stringer angles along the rear spar</h3><p class="pick-note">Angles are relative to the rear-spar segment from the preceding point (or root). The last angle continues to the tip. Define the segment positions in Structure → Spars.</p><div data-angles></div><p data-angle-error role="alert" hidden></p>';host.append(section);
  const output=section.querySelector('[data-angles]'),error=section.querySelector('[data-angle-error]');
  function refresh(){
   const points=read()||[],legacy=doc.getElementById('row-box.stringer_angle');if(legacy)legacy.hidden=points.length>0;
   // Retain the focused draft while other inputs and previews update.
   if(section.contains(doc.activeElement))return;
   output.replaceChildren();error.hidden=true;
   if(!points.length){const p=doc.createElement('p');p.className='pick-note';p.textContent='No rear-spar perturbation points: the default angle above applies along the full span.';output.append(p);return;}
   const table=doc.createElement('table');table.className='stringer-angle-table';table.innerHTML='<thead><tr><th>Span η</th><th>Angle (deg)</th></tr></thead><tbody></tbody>';
   for(const row of segments(points)){
    const tr=doc.createElement('tr'),label=doc.createElement('th'),value=doc.createElement('td');label.scope='row';label.textContent=row.unused?'Root point (unused)':String(row.start)+' → '+String(row.end);tr.append(label,value);
    if(row.inherited){value.dataset.inheritedPoint=String(row.index);value.textContent=String(row.angle)+' · same as previous';}
    else{const input=doc.createElement('input');input.type='number';input.step='any';input.value=Number.isFinite(row.angle)?String(row.angle):'';input.dataset.pointIndex=String(row.index);input.setAttribute('aria-label','Stringer angle for rear point '+(row.index+1));input.disabled=isLocked()||row.unused;
     input.addEventListener('change',()=>{if(isLocked())return;const angle=Number(input.value);if(!input.value.trim()||!Number.isFinite(angle)){error.textContent='Enter a finite stringer angle in degrees.';error.hidden=false;return;}const next=(read()||[]).map(p=>({...p}));if(!next[row.index])return;next[row.index].stringer_angle=angle;error.hidden=true;onEdit(next);for(const inherited of output.querySelectorAll('[data-inherited-point]'))if(Number(inherited.dataset.inheritedPoint)===row.index)inherited.textContent=String(angle)+' · same as previous';});value.append(input);}
    table.tBodies[0].append(tr);
   }output.append(table);
  }
  host.addEventListener('parameterlockchange',()=>{for(const input of section.querySelectorAll('input'))input.disabled=isLocked()||segments(read()||[]).find(r=>r.index===Number(input.dataset.pointIndex)&&!r.inherited)?.unused;});
  refresh();return{refresh,section};
 }
 return{segments,install};
});
