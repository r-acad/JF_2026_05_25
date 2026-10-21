/* User-supplied postprocessing criteria. Never changes constitutive properties,
 * loads or solved fields. Strain is engineering strain in each ply's axes. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMaterialAllowables=api;})(globalThis,function(){
 'use strict';
 const KEY='materials.allowables',STRAINS=['strain_tension','strain_compression'],LEGACY_STRAINS=['e1_t','e1_c','e2_t','e2_c','g12'];
 const LABELS={stress:'Von Mises stress',strain_tension:'Tensile principal strain limit',strain_compression:'Compressive principal strain limit (positive magnitude)',e1_t:'Legacy longitudinal tensile limit',e1_c:'Legacy longitudinal compressive limit',e2_t:'Legacy transverse tensile limit',e2_c:'Legacy transverse compressive limit',g12:'Legacy engineering shear limit'};
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0;
 const format=n=>finite(n)?Number(n.toPrecision(5)).toString():'Unavailable';
 function validate(rows){
  if(!Array.isArray(rows))throw Error('Material allowables must be a table.');
  const ids=new Set();
  for(const row of rows){
   if(!Number.isInteger(row.material_id)||row.material_id<1||ids.has(row.material_id))throw Error('Material allowable IDs must be positive and unique.');
   ids.add(row.material_id);if(!['stress','strain'].includes(row.mode))throw Error('Choose stress or strain allowables.');
   for(const key of ['stress',...STRAINS,...LEGACY_STRAINS])if(row[key]!==undefined&&!positive(row[key]))throw Error('Material '+row.material_id+': '+LABELS[key]+' must be finite and positive.');
  }
  return rows;
 }
 function compatible(mat,row){return row?.mode==='stress'?mat?.type==='MAT1':row?.mode==='strain'?mat?.type==='MAT8':false;}
 function missing(row){return(row?.mode==='stress'?['stress']:STRAINS).filter(key=>!positive(row?.[key]));}
 function sample(demand,limit,details){const utilization=Math.abs(demand)/limit;return{...details,demand,allowable:limit,utilization,reserve_factor:utilization>0?1/utilization:null,margin:utilization>0?1/utilization-1:null};}
 function strainSample(face,row,details){
  if(!face||!['e1','e2','g12'].every(key=>finite(face[key])))return null;
  // The tensor off-diagonal is gamma12 / 2; principal strains are invariant
  // under a change of in-plane ply axes. A pure shear state has +/-gamma12/2.
  const mean=face.e1/2+face.e2/2,radius=Math.hypot(face.e1/2-face.e2/2,face.g12/2);
  const maximum=mean+radius,minimum=mean-radius;
  if(!finite(maximum)||!finite(minimum))return null;
  const common={...details,criterion:'Principal strain',unit:'strain',principal_maximum:maximum,principal_minimum:minimum};
  const tension=sample(Math.max(0,maximum),row.strain_tension,{...common,component:'Tensile principal strain'});
  const compression=sample(Math.min(0,minimum),row.strain_compression,{...common,component:'Compressive principal strain'});
  return tension.utilization>=compression.utilization?tension:compression;
 }
 function assessElement(property,record,rows){
  if(!property)return{reason:'Material definition unavailable.'};
  const limits=rows instanceof Map?rows:new Map(rows.map(row=>[row.material_id,row]));
  const plies=property.type==='PCOMP'?property.plies:null;
  const parts=plies?.length?plies.map((ply,i)=>({material:ply.material,mid:ply.material_id??ply.material?.id,ply:i+1})):[{material:property.material,mid:property.material_id??property.material?.id}];
  if(parts.some(part=>part.material?.type==='MAT8'&&limits.get(Number(part.mid))?.mode==='strain')){
   if(!plies?.length)return{reason:'Orthotropic principal-strain checks require a laminate property and recovered ply faces.'};
   const mid=Number(parts[0].mid);
   if(!parts.every(part=>part.material?.type==='MAT8'&&Number(part.mid)===mid))return{reason:'Principal-strain checks require every laminate ply to use the same orthotropic MAT8 material ID; heterogeneous laminates are unassessed.'};
  }
  let worst=null;
  for(const part of parts){
   const row=limits.get(Number(part.mid)),mat=part.material;
   if(!row)return{reason:'No allowable for material '+(part.mid??'unknown')+'.'};
   if(!compatible(mat,row))return{reason:'Material '+part.mid+': use von Mises stress for MAT1 or principal strain for MAT8.'};
   if(missing(row).length)return{reason:'Material '+part.mid+': incomplete '+row.mode+' limits.'+(row.mode==='strain'&&LEGACY_STRAINS.some(key=>row[key]!==undefined)?' Saved directional limits are not converted; enter both principal-strain limits.':'')};
   let candidates=[];
   if(plies){
    const recovery=record?.[row.mode==='strain'?'strain':'stress'];
    if(recovery?.ply_faces_complete!==true||recovery.ply_faces_coordinate_system!=='ply material 1/2 axes')return{reason:'Complete ply recovery in material axes is unavailable.'};
    const faces=recovery.ply_faces;
    const recovered=Array.isArray(faces)?faces.find(face=>Number(face.ply)===part.ply&&Number(face.material_id)===Number(part.mid)):null;
    if(!recovered)return{reason:'Ply-face '+row.mode+' recovery unavailable; rerun with '+(row.mode==='strain'?'STRAIN':'STRESS')+' output.'};
    for(const side of ['bottom','top']){
     const detail={material_id:part.mid,ply:part.ply,face:side};
     const value=row.mode==='strain'?strainSample(recovered[side],row,detail):finite(recovered[side]?.von_mises)&&recovered[side].von_mises>=0?sample(recovered[side].von_mises,row.stress,{...detail,criterion:'Von Mises stress',unit:'stress'}):null;
     if(!value)return{reason:'Incomplete ply-face '+row.mode+' recovery.'};candidates.push(value);
    }
   }else{
    // No axial-stress substitution for beam equivalent stress. Only consume
    // explicitly recovered von Mises values, including solid/shell samples.
    if(property.type==='PSHELL'&&!['z1','z2'].every(face=>finite(record?.stress?.[face]?.von_mises)&&record.stress[face].von_mises>=0))return{reason:'Both shell-face von Mises samples are required.'};
    let invalid=false;
    const visit=(value,path=[])=>{if(!value||typeof value!=='object')return;for(const[key,item]of Object.entries(value)){if(key==='von_mises'){if(!finite(item)||item<0){invalid=true;continue;}candidates.push(sample(item,row.stress,{material_id:part.mid,face:path.join(' / ')||'element',criterion:'Von Mises stress',unit:'stress'}));}else if(item&&typeof item==='object')visit(item,[...path,key]);}};
    visit(record?.stress);
    if(invalid)return{reason:'Invalid equivalent stress sample.'};
    if(!candidates.length)return{reason:'Equivalent von Mises stress was not recovered for this element.'};
   }
   for(const candidate of candidates){if(!finite(candidate.utilization))return{reason:'Demand / allowable ratio exceeds numeric range.'};if(!worst||candidate.utilization>worst.utilization)worst=candidate;}
  }
  return worst||{reason:'No structural material samples.'};
 }
 function build(elements,records,rows){
  validate(rows);const limits=new Map(rows.map(row=>[row.material_id,row])),details=new Map(),byId=new Map(),reasons=new Map();let total=0,worst=null;
  for(const[eid,element]of elements){
   const g=element.group;if(!['quad','tria','shell','solid','bar'].includes(g?.kind)||g.name==='aero')continue;
   total++;const value=assessElement(g.properties,records?.[String(eid)],limits);details.set(eid,value);
   if(value.reason){reasons.set(value.reason,(reasons.get(value.reason)||0)+1);continue;}
   byId.set(eid,value.utilization);if(!worst||value.utilization>worst.utilization)worst={eid,pid:g.pid,...value};
  }
  const values=[...byId.values()];let min=Infinity,max=-Infinity;for(const value of values){min=Math.min(min,value);max=Math.max(max,value);}
  const note=byId.size+' / '+total+' elements assessed at their recovered sample locations. Utilization = demand / allowable; > 1 exceeds the limit. Gray elements are unassessed. Principal-strain checks require all plies to use one MAT8 material, with both faces recovered. They do not include interlaminar stresses or extrapolated corner peaks. Zero demand has no finite reserve factor.';
  return{details,reasons,total,assessed:byId.size,worst,contour:{name:'Material allowable utilization',unit:'ratio',location:'element',domain:'all',byId,min:byId.size?min:0,max:byId.size?max:0,note}};
 }
 function materialsFromGroups(groups){const materials=new Map();for(const g of groups||[]){const p=g.properties;for(const mat of [p?.material,...(p?.plies||[]).map(ply=>ply.material)])if(Number.isInteger(mat?.id))materials.set(mat.id,mat);}return [...materials.values()].sort((a,b)=>a.id-b.id);}
 function editor({document:doc,host,readMaterials,readRows,onChange,sourceUnits=()=>false}){
  const el=(tag,text,cls)=>{const node=doc.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;};
  const title=el('h2','Material allowables'),note=el('p','Optional limits for the current material. These are saved with the Study and compared with physical static results. Changing a limit updates the comparison without rerunning the solver.','pick-note');
  const label=el('label','Material','display-control'),select=el('select');select.id='allowable-material';label.append(select);
  const modeLabel=el('label','Compare with','display-control'),mode=el('select');mode.id='allowable-mode';for(const[value,text]of[['none','Not assessed'],['stress','Stress · von Mises (isotropic)'],['strain','Strain · principal (orthotropic laminate)']]){const opt=el('option',text);opt.value=value;mode.append(opt);}modeLabel.append(mode);
  const fields=el('div',undefined,'allowable-fields'),info=el('p',undefined,'pick-note'),status=el('p',undefined,'material-error');status.setAttribute('role','status');
  const help=el('details',undefined,'ui-form-help');help.append(el('summary','How allowable comparisons work'),el('p','MAT1: compare the recovered von Mises stress with one positive stress limit. Principal-strain checks apply only to laminates whose every ply uses the same orthotropic MAT8 material ID; ply angles may differ. Enter two dimensionless limits: tension and a positive compression magnitude (0.005 means 0.5%). At both faces of every ply, εmax/min = (ε1 + ε2) / 2 ± sqrt(((ε1 − ε2) / 2)² + (γ12 / 2)²). γ12 is engineering shear strain, twice tensor shear. Compare positive εmax with the tensile limit and the magnitude of negative εmin with the compressive limit; the largest ratio governs. Heterogeneous laminates, missing limits or missing recovery remain unassessed. Saved directional limits are retained but never converted to principal-strain limits. These are pointwise elastic checks, not damage or progressive-failure models. Reserve factor = 1 / utilization and margin = reserve factor - 1. For nonlinear results these are demand ratios, not predicted load multipliers. Eigenmode amplitudes are arbitrary and cannot be checked. If an imported deck suppresses STRAIN output, select an explicit solution in Analysis of imported model and rerun; preserving the source analysis also preserves its output requests.'));
  const controls={};for(const key of ['stress',...STRAINS]){const row=el('label',LABELS[key],'material-field'),input=el('input');input.type='number';input.step='any';input.min='0';input.id='allowable-'+key;input.setAttribute('aria-label',LABELS[key]);row.append(input);fields.append(row);controls[key]={row,input};input.addEventListener('input',store);}
  host.replaceChildren(title,note,label,modeLabel,fields,info,status,help);let catalogue=[];
  const read=()=>JSON.parse(JSON.stringify(readRows()||[]));
  function store(){
   const previous=read().find(row=>row.material_id===Number(select.value));
   let rows=read().filter(row=>row.material_id!==Number(select.value));
   if(mode.value!=='none'){
    const row={material_id:Number(select.value),mode:mode.value};
    // Retain old Study data for reference, without inventing new limits.
    for(const key of LEGACY_STRAINS)if(previous?.[key]!==undefined)row[key]=previous[key];
    // Preserve the dormant basis values when toggling, without using them.
    for(const key of ['stress',...STRAINS]){const input=controls[key].input;if(input.value!==''||input.validity.badInput)row[key]=input.validity.badInput?{raw:'invalid number'}:Number(input.value)*(key==='stress'&&!sourceUnits()?1e9:1);}
    rows.push(row);
   }
   rows.sort((a,b)=>a.material_id-b.material_id);onChange(rows);describe();
  }
  function describe(){
   const row=read().find(row=>row.material_id===Number(select.value)),mat=catalogue.find(mat=>mat.id===Number(select.value));
   for(const[key,{row:field}]of Object.entries(controls))field.hidden=mode.value==='none'||(mode.value==='stress'?key!=='stress':key==='stress');
   controls.stress.row.firstChild.textContent='Von Mises stress limit ('+(sourceUnits()?'source stress units':'GPa')+')';
   info.textContent=mode.value==='strain'?'Enter both principal-strain limits. Strain 0.005 = 0.5%; compression is a positive magnitude. Applies only to laminates made entirely from this MAT8 material; ply angles may differ.':mode.value==='stress'?(sourceUnits()?'Use the same stress units as the imported deck; no unit conversion is inferred.':'Stress limits are displayed in GPa and stored in Pa.'):'No allowable comparison for this material.';
   try{validate(read());status.textContent=row&&!compatible(mat,row)?'This basis is incompatible with '+(mat?.type||'the unavailable material')+'.':row&&missing(row).length?'Incomplete limits: this material will remain unassessed.'+(row.mode==='strain'&&LEGACY_STRAINS.some(key=>row[key]!==undefined)?' Saved directional limits are not converted; enter both principal-strain limits.':''):'';}catch(error){status.textContent=error.message;}status.hidden=!status.textContent;
  }
  function show(){const row=read().find(row=>row.material_id===Number(select.value)),mat=catalogue.find(mat=>mat.id===Number(select.value));mode.value=row?.mode||'none';for(const opt of mode.options)opt.disabled=opt.value!=='none'&&!compatible(mat,{mode:opt.value});for(const[key,{input}]of Object.entries(controls))input.value=finite(row?.[key])?String(Number((row[key]*(key==='stress'&&!sourceUnits()?1e-9:1)).toPrecision(15))):'';describe();}
  function refresh(){
   const previous=select.value;catalogue=[...(readMaterials()||[])];for(const row of read())if(!catalogue.some(mat=>mat.id===row.material_id))catalogue.push({id:row.material_id,type:'Unavailable',name:'Saved material not in current model'});
   select.replaceChildren();for(const mat of catalogue){const opt=el('option',mat.id+' · '+(mat.name||mat.type||'Material')+' ('+(mat.type||'unknown')+')');opt.value=mat.id;select.append(opt);}if([...select.options].some(opt=>opt.value===previous))select.value=previous;select.disabled=!catalogue.length;mode.disabled=!catalogue.length;show();
  }
  select.addEventListener('change',show);mode.addEventListener('change',store);refresh();
  return{refresh,assertValid:()=>validate(read()),destroy:()=>host.replaceChildren()};
 }
 return{KEY,STRAINS,validate,missing,compatible,assessElement,build,materialsFromGroups,editor,format};
});
