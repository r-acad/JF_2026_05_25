/* Physical RF display/inspection domains. FE recovery and solver topology stay
 * unchanged; fractional skin polygons are display-only parts of their EIDs. */
(function(root,factory){const common=typeof module==='object'&&module.exports;
 const api=factory(common?require('./stress_report_data.js'):root.WingStressReportData,common?require('./minimum_rf_data.js'):root.WingMinimumRFData);
 if(common)module.exports=api;else root.WingRFPanelScope=api;
})(globalThis,function(stress,minimum){
 'use strict';
 const finite=Number.isFinite,ids=values=>[...new Set((values||[]).map(Number).filter(v=>Number.isSafeInteger(v)&&v>0))],
  entries=value=>value instanceof Map?[...value]:Array.isArray(value)?value.map((v,i)=>[v.id??i+1,v]):Object.entries(value||{}),
  dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),sub=(a,b)=>a.map((v,i)=>v-b[i]),mid=(a,b)=>a.map((v,i)=>(v+b[i])/2),
  cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],norm=a=>Math.hypot(...a),EMPTY=Object.freeze([]),
  center=points=>points[0].map((_,i)=>points.reduce((s,p)=>s+p[i],0)/points.length),cache=new WeakMap();
 const componentModes={spar_web:'spar_web_buckling',rib_web:'rib_web_buckling',spar_cap:'spar_cap_buckling',rib_stiffener:'rib_stiffener_buckling',rib_stiffener_blade:'rib_stiffener_blade'};
 function typed(value,type){
  if(value instanceof Uint8Array){const n=value.byteLength/4,view=new DataView(value.buffer,value.byteOffset,value.byteLength);return Array.from({length:n},(_,i)=>type==='float'?view.getFloat32(4*i,true):view.getInt32(4*i,true));}
  return Array.from(value||[]);
 }
 function geometry(input){
  const data=input.data||{},result=new Map(),nodes=typed(data.nodes?.xyz,'float');
  for(const group of data.groups||[]){const eids=typed(group.eids),conn=typed(group.conn),stride=group.n_per_elem||(group.kind==='quad'?4:group.kind==='tria'?3:2);
   for(let e=0;e<eids.length;e++){const indices=conn.slice(stride*e,stride*(e+1));result.set(Number(eids[e]),{group,nodes:indices,points:indices.map(i=>nodes.slice(3*i,3*i+3))});}}
  // RF recovery frames are BASIC XYZ. The viewport's nodePositions may be
  // permuted YZX; the application supplies this explicit raw-coordinate view.
  const positions=input.scopeNodePositions||(input.nodeCoordinateFrame==='BASIC'?(input.nodePositions||input.positions):null);
  for(const[id,element]of entries(input.elements)){
   const previous=result.get(Number(id)),points=element.points||previous?.points||(positions&&element.nodes?Array.from(element.nodes,i=>Array.from(positions.slice(3*i,3*i+3))):undefined);
   result.set(Number(id),{...previous,...element,group:element.group||previous?.group,points});
  }
  // Section-only editor contexts carry refreshed properties without geometry.
  const properties=new Map((input.groups||[]).map(group=>[Number(group.pid),group.properties]));
  for(const element of result.values())if(properties.has(Number(element.group?.pid)))element.group={...element.group,properties:properties.get(Number(element.group.pid))||element.group.properties};
  return result;
 }
 function area(poly){let result=0;for(let i=1;i+1<poly.length;i++)result+=norm(cross(sub(poly[i].point,poly[0].point),sub(poly[i+1].point,poly[0].point)))/2;return result;}
 function clip(poly,plane){
  const output=[],distance=p=>dot(plane.normal,p.point)-plane.offset;
  for(let i=0;i<poly.length;i++){const a=poly[i],b=poly[(i+1)%poly.length],da=distance(a),db=distance(b),ina=da>=-1e-11,inb=db>=-1e-11;
   if(ina)output.push(a);if(ina!==inb){const t=da/(da-db);output.push({point:a.point.map((v,k)=>v+t*(b.point[k]-v)),weights:a.weights.map((v,k)=>v+t*(b.weights[k]-v))});}}
  return output;
 }
 function pieces(element,planes){
  const points=element?.points;if(!points||points.length<3||points.some(p=>p.length!==3||!p.every(finite)))return[];
  const vertices=points.map((point,i)=>({point:Array.from(point),weights:points.map((_,k)=>k===i?1:0)})),triangles=points.length===4?[[0,1,2],[0,2,3]]:[[0,1,2]],total=triangles.reduce((s,t)=>s+area(t.map(i=>vertices[i])),0),output=[];
  if(!(total>0))return output;
  for(const triangle of triangles){let poly=triangle.map(i=>vertices[i]);for(const plane of planes)poly=clip(poly,plane);const a=area(poly);if(poly.length>=3&&a>total*1e-10)output.push({vertices:poly,areaFraction:a/total,clipPlanes:planes});}
  return output;
 }
 function index(input={}){
  const data=input.data||input,panels=input.panels||data.stiffened_panels?.panels||EMPTY,columns=input.eulerColumns||data.stiffened_panels?.euler_columns||EMPTY,plates=input.skinBucklingPanels||data.stiffened_panels?.skin_buckling_panels||EMPTY,components=input.componentBuckling||data.component_buckling||{};
  const prior=cache.get(input);if(prior&&prior.panels===panels&&prior.columns===columns&&prior.plates===plates&&prior.elementsSource===input.elements&&prior.groupsSource===input.groups&&prior.materialRegions===input.materialRegions&&prior.data===data)return prior.value;
  const elements=geometry(input);
  const parts=[],byKey=new Map(),byElement=new Map(),assigned=new Set(),issues=[];
  const ownEids=panel=>ids([...(panel.stringer_eids||[]),...(panel.stringer_web_eids||[]),...(panel.stringer_flange_eids||[])]),
   columnByKey=new Map(columns.map(c=>[c.key,c])),panelByKey=new Map(panels.map(p=>[p.key,p]));
  function make(key,kind,label,extra={}){if(byKey.has(key))return byKey.get(key);const part={key,kind,label,elementIds:[],skinElementIds:[],stringerElementIds:[],capElementIds:[],editablePropertyIds:[],skinPlateKeys:[],fragments:[],skinFractions:{},componentChecks:[],...extra};parts.push(part);byKey.set(key,part);return part;}
  for(const panel of panels){const column=columnByKey.get(panel.key),bars=ownEids(panel);if(!bars.length&&!column)continue;
   make(panel.key,'compression_panel',panel.label||panel.key,{panelKey:panel.key,panelId:panel.id,stringer:panel.stringer,skin:panel.skin,ribBay:panel.rib_bay,stringerElementIds:bars,sourcePanel:panel,sourceColumn:column});}
  const coordinateKey=raw=>[raw.skin,raw.rib_bay,raw.segment??1,raw.stringer].join('|'),columnsAt=new Map(columns.map(c=>[coordinateKey(c),c]));
  function plateColumn(plate,stringer){return columnsAt.get([plate.skin,plate.rib_bay,plate.segment??1,stringer].join('|'))||columns.find(c=>c.skin===plate.skin&&Number(c.rib_bay)===Number(plate.rib_bay)&&Number(c.stringer)===stringer);}
  function station(column,eid,element){
   const rows=column?.stations||[],exact=rows.find(row=>(row.force_terms||[]).some(term=>Number(term.eid)===eid));if(exact)return exact;
   if(!element?.points?.length)return rows[0];const point=center(element.points);
   return rows.reduce((best,row)=>!best||Math.abs(dot(sub(point,row.origin_m),row.axis))<Math.abs(dot(sub(point,best.origin_m),best.axis))?row:best,null);
  }
  const nodeIds=input.nodeIds?Array.from(input.nodeIds):typed(data.nodes?.ids),rawPositions=input.scopeNodePositions||typed(data.nodes?.xyz,'float'),nodePoints=new Map(nodeIds.map((id,i)=>[Number(id),Array.from(rawPositions.slice(3*i,3*i+3))]));
  function pathEnds(column,row){
   const beam=(row?.force_terms||[]).map(term=>elements.get(Number(term.eid))).find(e=>e?.group?.kind==='bar'&&e.points?.length===2);
   if(beam)return beam.points.slice().sort((a,b)=>dot(sub(a,b),row.axis));
   const path=(panelByKey.get(column?.key)?.stringer_grid_ids||[]).map(id=>nodePoints.get(Number(id))).filter(p=>p?.length===3),segments=[];
   for(let i=0;i+1<path.length;i++)segments.push([path[i],path[i+1]]);
   return segments.reduce((best,pair)=>!best||Math.abs(dot(sub(center(pair),row.origin_m),row.axis))<Math.abs(dot(sub(center(best),row.origin_m),row.axis))?pair:best,null);
  }
  function midpointPlane(a,ar,b,br,plate){
   const ap=pathEnds(a,ar),bp=pathEnds(b,br);if(!ap||!bp)return null;
   const first=mid(ap[0],bp[0]),last=mid(ap[1],bp[1]),normal=cross(sub(last,first),plate.frame?.normal||ar.section_z||[0,0,1]);
   if(norm(normal)<1e-14)return null;
   if(dot(normal,sub(br.origin_m,ar.origin_m))<0)for(let i=0;i<3;i++)normal[i]*=-1;
   return{normal,offset:dot(normal,first)};
  }
  function addFragments(part,eid,planes,plateKey){
   const element=elements.get(eid),fragments=pieces(element,planes);
   if(!fragments.length)return;
   for(const fragment of fragments)part.fragments.push({...fragment,eid,partKey:part.key});
   part.skinFractions[eid]=(part.skinFractions[eid]||0)+fragments.reduce((s,f)=>s+f.areaFraction,0);part.skinElementIds.push(eid);part.skinPlateKeys.push(plateKey);assigned.add(eid);
  }
  for(const plate of plates){
   if(plate.applicable===false||plate.status==='not_applicable')continue;
   const labels=Array.isArray(plate.boundary_labels)?plate.boundary_labels:[],stringers=labels.map(label=>/^S(\d+)$/.exec(label)).filter(Boolean).map(m=>Number(m[1])),owners=stringers.map(n=>plateColumn(plate,n)).filter(Boolean),spar=labels.find(label=>['Front spar','Rear spar'].includes(label));
   const plain=spar||!owners.length?make('plain:'+plate.key,'plain_skin',(plate.skin==='upper'?'Upper':'Lower')+' · R'+plate.rib_bay+'–R'+(Number(plate.rib_bay)+1)+' · '+(plate.label||plate.key),{plateKey:plate.key,skin:plate.skin,ribBay:plate.rib_bay,sparSide:spar==='Front spar'?'front':spar==='Rear spar'?'rear':null}):null;
   for(const eid of ids(plate.member_element_ids)){
    const element=elements.get(eid);
    if(owners.length===2){
     const a=station(owners[0],eid,element),b=station(owners[1],eid,element),delta=a&&b&&sub(b.origin_m,a.origin_m);
     if(delta&&norm(delta)>1e-12){const plane=midpointPlane(owners[0],a,owners[1],b,plate)||{normal:delta,offset:dot(delta,mid(a.origin_m,b.origin_m))},normal=plane.normal,offset=plane.offset;
      const first=byKey.get(owners[0].key),second=byKey.get(owners[1].key);
      if(first)addFragments(first,eid,[{normal:normal.map(v=>-v),offset:-offset}],plate.key);
      if(second)addFragments(second,eid,[{normal,offset}],plate.key);continue;}
    }else if(owners.length===1&&spar){
     const row=station(owners[0],eid,element),part=byKey.get(owners[0].key);
     if(row?.section_y&&row.origin_m&&part){
      const capName=(spar==='Front spar'?'front':'rear')+'_'+plate.skin+'_cap',cap=(components.columns||[]).find(c=>c.kind==='spar_cap'&&c.part===capName&&Number(c.rib_bay)===Number(plate.rib_bay)),capStation=cap&&station(cap,eid,element),plane=capStation&&midpointPlane(owners[0],row,cap,capStation,plate);
      if(plane){addFragments(part,eid,[{normal:plane.normal.map(v=>-v),offset:-plane.offset}],plate.key);addFragments(plain,eid,[plane],plate.key);continue;}
      // Native section_y can point fore or aft on either cover. The spar
      // label alone therefore cannot select its signed transverse half-width.
      const plateCenter=plate.frame?.origin_m||element?.points?.length&&center(element.points),direction=plateCenter&&dot(sub(plateCenter,row.origin_m),row.section_y),side=finite(direction)&&Math.abs(direction)>1e-12?Math.sign(direction):spar==='Front spar'?-1:1,
       width=Number(side<0?row.left_width_m:row.right_width_m),normal=row.section_y.map(v=>side*v),offset=dot(normal,row.origin_m)+width;
      if(finite(width)&&width>=0){addFragments(part,eid,[{normal:normal.map(v=>-v),offset:-offset}],plate.key);addFragments(plain,eid,[{normal,offset}],plate.key);continue;}}
    }
    if(plain)addFragments(plain,eid,[],plate.key);
    else if(owners.length===1&&byKey.has(owners[0].key))addFragments(byKey.get(owners[0].key),eid,[],plate.key);
    else issues.push({eid,plateKey:plate.key,reason:'The physical skin partition lacks its stringer section stations.'});
   }
  }
  // The residual half strip at a spar can include its own cap, never a second
  // stringer. The original cap criterion remains an isolated-member check.
  for(const part of parts)if(part.kind==='plain_skin'&&part.sparSide){const name=part.sparSide+'_'+part.skin+'_cap';for(const raw of components.columns||[])if(raw.kind==='spar_cap'&&raw.part===name&&Number(raw.rib_bay)===Number(part.ribBay)){
   part.capElementIds.push(...ids(raw.member_element_ids));part.componentChecks.push({mode:'spar_cap_buckling',key:raw.key});}}
  // Non-cover components retain their own elementary physical regions.
  for(const[collection,rows]of Object.entries(components))for(const raw of rows||[]){const mode=componentModes[raw.kind];if(!mode||raw.applicable===false)continue;
   const eids=ids(raw.member_element_ids);if(!eids.length||parts.some(p=>p.capElementIds.some(eid=>eids.includes(eid))))continue;
   let part=parts.find(p=>p.kind==='property'&&p.elementIds.length===eids.length&&p.elementIds.every(eid=>eids.includes(eid)));
   if(!part)part=make('component:'+raw.kind+':'+raw.key,'property',raw.label||raw.key,{elementIds:eids});
   part.componentChecks.push({mode,key:raw.key});for(const eid of eids)assigned.add(eid);
  }
  for(const part of parts){part.skinElementIds=ids(part.skinElementIds);part.skinPlateKeys=[...new Set(part.skinPlateKeys)];part.elementIds=ids([...part.elementIds,...part.skinElementIds,...part.stringerElementIds,...part.capElementIds]);for(const eid of part.elementIds)assigned.add(eid);}
  const leftover=new Map();for(const[eid,element]of elements)if(!assigned.has(eid)&&Number.isSafeInteger(Number(element.group?.pid))){const pid=Number(element.group.pid);if(!leftover.has(pid))leftover.set(pid,[]);leftover.get(pid).push(eid);}
  for(const[pid,eids]of leftover){
   const runouts=eids.filter(eid=>elements.get(eid)?.group?.name==='STRINGER_RUNOUTS');
   for(const eid of runouts)make('runout:'+eid,'property','Stringer run-out · E'+eid,{elementIds:[eid]});
   const other=eids.filter(eid=>!runouts.includes(eid));if(other.length)make('property:'+pid,'property','Property P'+pid,{elementIds:other});
  }
  const materialRegions=[];
  for(const part of parts){
   part.editablePropertyIds=ids(part.elementIds.map(eid=>elements.get(eid)?.group?.pid));
   const byPid=new Map();for(const eid of part.elementIds){const pid=Number(elements.get(eid)?.group?.pid);if(!Number.isSafeInteger(pid))continue;if(!byPid.has(pid))byPid.set(pid,[]);byPid.get(pid).push(eid);if(!byElement.has(eid))byElement.set(eid,[]);byElement.get(eid).push(part);}
   part.materialRegions=[...byPid].map(([pid,member_element_ids])=>({key:part.key,pid,member_element_ids,label:part.label,member_kind:member_element_ids.some(eid=>part.stringerElementIds.includes(eid))?'stringer':member_element_ids.some(eid=>part.capElementIds.includes(eid))?'spar_cap':member_element_ids.some(eid=>part.skinElementIds.includes(eid))?'skin':'component'}));materialRegions.push(...part.materialRegions);
  }
  const value={parts:parts.filter(p=>p.elementIds.length),byKey,byElement,materialRegions,elements,issues,modelIndex:minimum.modelIndex({elements}),physical:parts.some(p=>p.fragments.length>0)||!!input.materialRegions?.length};
  cache.set(input,{panels,columns,plates,elementsSource:input.elements,groupsSource:input.groups,materialRegions:input.materialRegions,data,value});return value;
 }
 function resolve(input={},focus={}){
  const layout=index(input),key=focus.scopeKey||focus.partKey||focus.panelKey||focus.plateKey;
  if(key&&(layout.byKey.has(key)||layout.byKey.has('plain:'+key)))return layout.byKey.get(key)||layout.byKey.get('plain:'+key);
  const eid=Number(focus.eid),candidates=layout.byElement.get(eid)||[];
  if(candidates.length===1)return candidates[0];
  const element=layout.elements.get(eid),point=focus.point||element?.points?.length&&center(element.points);
  if(point){const matches=candidates.filter(part=>part.fragments.some(f=>f.eid===eid&&f.clipPlanes.every(p=>dot(p.normal,point)-p.offset>=-1e-10)));if(matches.length)return matches.find(p=>p.kind==='plain_skin')||matches[0];}
  if(candidates.length)return candidates.find(p=>p.stringerElementIds.includes(eid)||p.capElementIds.includes(eid))||candidates[0];
  const pid=Number(focus.pid),matches=layout.parts.filter(part=>part.editablePropertyIds.includes(pid));return matches.length===1?matches[0]:matches.find(part=>part.kind==='compression_panel')||matches[0]||null;
 }
 function summary(input={},report,scope){
  if(!scope)return{available:false,value:null,checks:[],failures:[],incomplete:['No physical panel is identified.'],reason:'No physical panel is identified.'};
  const layout=index(input),criteria=stress.criteria?.(report)||{},selectedMode=report?.failureMode||'minimum_rf',checks=[];
  const include=mode=>selectedMode==='minimum_rf'||selectedMode===mode;
  function add(row,mode,identity,label,memberKind){
   if(!include(mode))return;
   const complete=row?.complete===true,raw=row?.reserveFactor,noDemand=row?.noDemand===true||row?.euler?.noCompression===true||row?.blade?.noCompression===true||row?.skinBuckling?.noDestabilizingLoad===true;
   const value=complete?(noDemand?99:finite(raw)&&raw>0?raw:null):null;
   checks.push({modeKey:mode,failureMode:mode,mode:label||minimum.MODES[mode]||mode,modeLabel:label||minimum.MODES[mode]||mode,value,reserveFactor:value,complete:complete&&value!==null,noDemand,scope:row?.label||scope.label,scopeKey:identity,sourceRowKey:row?.rowKey||identity,caseLabel:row?.envelopeCaseLabel||'',caseKey:row?.envelopeCaseKey||'',caseResults:row?.caseResults||[],memberKind,propertyIds:row?.propertyIds||[row?.pid].filter(v=>v!=null),reason:row?.reserveFactorReason||row?.reason||(!row?'No current assessment was returned for this physical region.':''),approximate:!!(row?.approximation||row?.governingApproximation)});
  }
  function physical(mode,key,raws,memberKind,required=false){
   if(!include(mode))return;const raw=raws.find(r=>r.key===key);if(raw?.applicable===false||raw?.status==='not_applicable')return;
   if(!raw&&!required)return;const source=criteria[mode]||(report?.failureMode===mode?report:null),row=source?.rows?.find(r=>r.panelKey===key);
   add(row,mode,key,mode==='euler_column'?'Stringer + associated skin · Euler column buckling':undefined,memberKind);
  }
  const data=input.data||{};
  if(scope.kind==='compression_panel'){
   physical('euler_column',scope.panelKey,input.eulerColumns||data.stiffened_panels?.euler_columns||[],'stringer_skin',true);
   physical('stringer_blade',scope.panelKey,input.stringerBlades||data.stiffened_panels?.blade_columns||[],'stringer');
  }
  for(const key of scope.skinPlateKeys)physical('skin_buckling',key,input.skinBucklingPanels||data.stiffened_panels?.skin_buckling_panels||[],'skin');
  for(const item of scope.componentChecks){const c=input.componentBuckling||data.component_buckling||{},raws=Object.values(c).flat().filter(raw=>componentModes[raw.kind]===item.mode);physical(item.mode,item.key,raws,'component');}
  const materialRows=report?.materialRegions||criteria.material_regions?.rows||[];
  for(const region of scope.materialRegions){
   const properties=region.member_element_ids.map(eid=>layout.elements.get(eid)?.group?.properties).filter(Boolean),mode=properties.some(p=>p.type==='PCOMP')?'principal_strain':'von_mises';
   if(!include(mode))continue;const matches=materialRows.filter(r=>r.materialRegionKey===scope.key&&Number(r.pid)===region.pid&&(!r.failureMode||r.failureMode===mode));let row=matches.length===1?matches[0]:null;
   if(row?.memberElementIds){const actual=ids(row.memberElementIds).sort((a,b)=>a-b),expected=ids(region.member_element_ids).sort((a,b)=>a-b);if(actual.length!==expected.length||actual.some((id,i)=>id!==expected[i]))row={...row,complete:false,reserveFactorReason:'The local material response belongs to different physical element membership.'};}
   add(row,mode,'material_region:'+scope.key+':P'+region.pid,(region.member_kind==='stringer'?'Stringer':region.member_kind==='skin'?'Skin':region.member_kind==='spar_cap'?'Spar cap':'Component')+' strength · '+(mode==='principal_strain'?'Principal strain':'Von Mises stress'),region.member_kind);
  }
  const unique=new Map();for(const check of checks){const key=check.modeKey+'|'+check.scopeKey;if(!unique.has(key))unique.set(key,check);}
  const all=[...unique.values()],missing=all.filter(c=>!c.complete),computed=all.filter(c=>c.complete&&!c.noDemand),governing=computed.reduce((best,c)=>!best||c.value<best.value?c:best,null),complete=all.length>0&&!missing.length,noDemand=complete&&all.every(c=>c.noDemand),value=complete?(noDemand?99:governing?.value??null):null;
  const failures=all.flatMap(c=>{const rows=c.caseResults.filter(r=>finite(r.reserveFactor)&&r.reserveFactor<1&&!r.noDemand);return(rows.length?rows:[c]).filter(r=>finite(r.reserveFactor??r.value)&&(r.reserveFactor??r.value)<1&&!r.noDemand).map(r=>({value:r.reserveFactor??r.value,mode:c.mode,scope:c.scope,caseLabel:r.label||r.caseLabel||c.caseLabel}));}).sort((a,b)=>a.value-b.value);
  const reason=missing.map(c=>c.mode+': '+c.reason).join(' ');
  return{available:complete&&value!==null,value,reserveFactor:value,mode:governing?.mode||(noDemand?'No demand in applicable checks':''),modeKey:governing?.modeKey||'',caseLabel:governing?.caseLabel||'',caseKey:governing?.caseKey||'',scope:scope.label,scopeKey:scope.key,rowKey:'physical:'+scope.key,propertyIds:scope.editablePropertyIds,memberElementIds:scope.elementIds,checks:all,assessments:all,failures,incomplete:missing.map(c=>c.mode+': '+c.reason),reason,noDemand,knownMinimum:governing?.value??null,estimated:!!report?.estimated,stale:!!report?.stale,approximate:all.some(c=>c.approximate),minimumGauge:minimum.gaugeFor(scope.editablePropertyIds,layout.modelIndex),physicalScope:scope};
 }
 return{index,resolve,summary};
});
