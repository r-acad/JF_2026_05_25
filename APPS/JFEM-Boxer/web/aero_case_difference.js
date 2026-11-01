/* Differences between corresponding panels of two conditions in one VLM sweep. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAeroCaseDifference=api;})(globalThis,function(){
 'use strict';
 const vector=v=>Array.isArray(v)&&v.length===3&&v.every(Number.isFinite);
 const positive=n=>Number.isFinite(n)&&n>0;
 const near=(a,b)=>Number.isFinite(a)&&Number.isFinite(b)&&Math.abs(a-b)<=1e-8*Math.max(1,Math.abs(a),Math.abs(b));
 const clone=value=>JSON.parse(JSON.stringify(value));
 const SCALARS=['delta_cp','delta_pressure_Pa','circulation_m2_s','speed_ratio'];
 const label=c=>c?.name||c?.label||'Case '+String(c?.id??'?');
 const key=p=>JSON.stringify([p.side,p.region,p.patch,p.strip,p.chord]);
 function index(c){
  if(!Array.isArray(c?.panels)||!c.panels.length)throw Error('Both cases need a computed panel mesh.');
  if(c.panel_count!==undefined&&c.panel_count!==c.panels.length)throw Error('The recorded panel count does not match the mesh.');
  const entries=new Map();
  for(const p of c.panels){
   if(!p||!['patch','strip','chord'].every(k=>Number.isInteger(p[k])&&p[k]>0)||!['left','right'].includes(p.side)||typeof p.region!=='string')throw Error('Panel surface and grid identifiers are unavailable. Recompute this sweep before comparing cases.');
   if(!Number.isFinite(p.eta)||!Number.isFinite(p.chord_fraction))throw Error('Panel span/chord coordinates are unavailable. Recompute this sweep before comparing cases.');
   if(!positive(p.area_m2)||!vector(p.position)||!Array.isArray(p.corners)||p.corners.length!==4||!p.corners.every(vector))throw Error('A panel has invalid geometry or area.');
   if(!vector(p.force_N))throw Error('Both cases must have computed panel forces; mesh previews cannot be subtracted.');
   const id=key(p);if(entries.has(id))throw Error('The panel mesh has duplicate surface/grid identifiers.');entries.set(id,p);
  }
  return entries;
 }
 function matching(a,b){
  const first=index(a),second=index(b);
  if(first.size!==second.size)throw Error('The cases have different panel counts. Use cases with matching VLM grids.');
  for(const k of ['span_m','area_m2','mac_m'])if(a[k]!==undefined&&b[k]!==undefined&&!near(a[k],b[k]))throw Error('The cases use different reference geometry. Compare conditions from the same sweep.');
  if(a.vector_frame&&b.vector_frame&&a.vector_frame!==b.vector_frame)throw Error('The cases use different dimensional vector frames.');
  let geometryChanged=false;
  const pairs=[];
  for(const [id,p] of first){
   const q=second.get(id);
   if(!q||String(p.control||'')!==String(q.control||''))throw Error('The cases have different VLM surface or control topology.');
   if(!near(p.eta,q.eta)||!near(p.chord_fraction,q.chord_fraction))throw Error('The cases have different span/chord panel spacing. Recompute with matching grids before subtracting.');
   geometryChanged ||= p.corners.some((corner,i)=>corner.some((x,k)=>!near(x,q.corners[i][k])));
   pairs.push([p,q]);
  }
  return{pairs,geometryChanged};
 }
 /** Check material-panel correspondence, independent of array order or global IDs.
  * Control motion is allowed when surface/grid IDs and normalized panel stations
  * still match. Adaptive remeshing is rejected; no nearest-neighbour interpolation
  * is performed. Render the difference on the minuend's geometry.
  */
 function compare(a,b){
  try{const match=matching(a,b);return{compatible:true,reason:'',panelCount:match.pairs.length,geometryChanged:match.geometryChanged};}
  catch(error){return{compatible:false,reason:error.message};}
 }
 function subtractVector(a,b){const difference=a.map((v,i)=>v-b[i]);if(!vector(difference))throw Error('The case difference exceeds the numeric display range.');return difference;}
 /** Subtract dimensional vectors in construction C. Pressure arrows use the
  * difference of each force/area, not (force difference)/(minuend area). Scalar
  * pressure and Cp differences retain each case's own normal and normalization.
  * This is a display result, not another aerodynamic solution or wake solution.
  */
 function subtract(a,b){
  const {pairs,geometryChanged}=matching(a,b),out=clone(a);
  out.id=String(a.id??'?')+' - '+String(b.id??'?');
  out.difference={minuend:a.id??null,subtrahend:b.id??null,label:label(a)+' - '+label(b),geometry:'minuend',geometryChanged,
   vector_frame:'construction C',pressure_vector_definition:'F_A / area_A - F_B / area_B',
   description:'Corresponding panel differences on '+label(a)+' geometry. Force vectors are A - B in construction C; pressure vectors are F_A/area_A - F_B/area_B. Cp and scalar pressure use each solved case\'s own normalization and panel normal.'};
  out.panels=pairs.map(([p,q])=>{
   const record=clone(p);
   record.force_N=subtractVector(p.force_N,q.force_N);
   record.pressure_vector_Pa=subtractVector(p.force_N.map(x=>x/p.area_m2),q.force_N.map(x=>x/q.area_m2));
   for(const k of SCALARS){const n=Number.isFinite(p[k])&&Number.isFinite(q[k])?p[k]-q[k]:null;record[k]=Number.isFinite(n)?n:null;}
   // These quantities rotate with flight condition or depend on the reference;
   // retaining the minuend's values here would mislabel them as differences.
   for(const k of ['force_wind_N','wind_loads_N','moment_Nm','velocity_m_s'])delete record[k];
   return record;
  });
  out.panel_count=out.panels.length;
  out.force_N=out.panels.reduce((sum,p)=>sum.map((v,i)=>v+p.force_N[i]),[0,0,0]);
  for(const k of ['coefficients','derivatives','strips','moment_Nm','CDi_trefftz','span_efficiency','trefftz','residual_over_V','wake','wake_origins','wake_direction','wake_model'])delete out[k];
  out.warnings=[out.difference.description];
  return out;
 }
 return{compare,subtract};
});
