/* Physical component checks. Reuse the tested plate bending/eigen kernels,
 * Euler sections and T-blade law; preserve spatial web membrane recovery. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./skin_buckling_data.js'):root.WingSkinBucklingData,typeof module==='object'&&module.exports?require('./euler_column_data.js'):root.WingEulerColumnData,typeof module==='object'&&module.exports?require('./stringer_blade_data.js'):root.WingStringerBladeData);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingComponentBucklingData=api;})(globalThis,function(plate,euler,blade){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0,flatten=M=>Array.isArray(M)&&Array.isArray(M[0])?M.flat():Array.from(M||[]),failure=reason=>({reason,converged:false});
 const MODES={spar_web_buckling:{kind:'spar_web',type:'plate',label:'Spar-web buckling',collection:'web_panels'},rib_web_buckling:{kind:'rib_web',type:'plate',label:'Rib-web buckling',collection:'web_panels'},spar_cap_buckling:{kind:'spar_cap',type:'column',label:'Spar-cap column buckling',collection:'columns'},rib_stiffener_buckling:{kind:'rib_stiffener',type:'column',label:'Rib-stiffener column buckling',collection:'columns'},rib_stiffener_blade:{kind:'rib_stiffener_blade',type:'blade',label:'Rib-stiffener blade instability',collection:'blades'}};
 const MAX_DIMENSION=256,MAX_MATRIX_BYTES=24*1024*1024,RESULT_LIMIT=1024,TOLERANCE=.005;
 const factors=new Map(),results=new Map();let factorBytes=0;
 const getCached=(map,key)=>{const value=map.get(key);if(value){map.delete(key);map.set(key,value);}return value;};
 function clearCaches(){factors.clear();results.clear();factorBytes=0;}
 function cacheInfo(){return{factorEntries:factors.size,factorBytes,factorByteLimit:MAX_MATRIX_BYTES,resultEntries:results.size,resultLimit:RESULT_LIMIT};}
 function rowsFor(input,mode){const descriptor=MODES[mode],rows=input.componentBuckling?.[descriptor?.collection];return Array.isArray(rows)?rows.filter(r=>r.kind===descriptor.kind):[];}
 function normalizedBounds(vertices){
  if(!Array.isArray(vertices)||vertices.length!==4||vertices.some(p=>!Array.isArray(p)||p.length!==2||!p.every(finite)))return failure('Each web face requires four finite normalized rectangle vertices.');
  const tolerance=1e-10,us=vertices.map(p=>p[0]),vs=vertices.map(p=>p[1]),u0=Math.min(...us),u1=Math.max(...us),v0=Math.min(...vs),v1=Math.max(...vs);
  if(u0< -tolerance||v0< -tolerance||u1>1+tolerance||v1>1+tolerance||u1-u0<=tolerance||v1-v0<=tolerance)return failure('A normalized web face lies outside its plate or has zero mapped area.');
  const corners=new Set();for(const [u,v]of vertices){const a=Math.abs(u-u0)<=tolerance?0:Math.abs(u-u1)<=tolerance?1:-1,b=Math.abs(v-v0)<=tolerance?0:Math.abs(v-v1)<=tolerance?1:-1;if(a<0||b<0)return failure('The web face does not form a supported rectangle in the equivalent-plate map.');corners.add(a+':'+b);}
  if(corners.size!==4)return failure('A normalized web face has repeated or missing corners.');
  return{bounds:[Math.max(0,u0),Math.min(1,u1),Math.max(0,v0),Math.min(1,v1)]};
 }
 function validateTiling(cells){
  if(!Array.isArray(cells)||!cells.length)return 'A complete spatial web membrane field is required.';
  const tol=1e-9;for(const c of cells){const b=c?.bounds;if(!Array.isArray(b)||b.length!==4||!b.every(finite)||b[0]<0||b[1]>1||b[2]<0||b[3]>1||b[1]<=b[0]||b[3]<=b[2])return 'A spatial web cell has invalid normalized bounds.';if(!Array.isArray(c.N)||c.N.length!==3||!c.N.every(finite))return 'Every spatial web cell requires three finite signed membrane resultants.';}
  const xs=[...new Set(cells.flatMap(c=>c.bounds.slice(0,2)))].sort((a,b)=>a-b);if(Math.abs(xs[0])>tol||Math.abs(xs.at(-1)-1)>tol)return 'Spatial web cells do not cover the full plate length.';
  for(let i=0;i<xs.length-1;i++){if(xs[i+1]-xs[i]<=tol)continue;const x=(xs[i]+xs[i+1])/2,ys=cells.filter(c=>c.bounds[0]<x&&c.bounds[1]>x).map(c=>c.bounds.slice(2)).sort((a,b)=>a[0]-b[0]);let end=0;for(const [lo,hi]of ys){if(Math.abs(lo-end)>tol)return lo<end?'Spatial web cells overlap; no buckling factor is assigned.':'Spatial web cells leave a hole; no buckling factor is assigned.';end=hi;}if(Math.abs(end-1)>tol)return 'Spatial web cells do not cover the full plate height.';}
  return '';
 }
 const integralCos=(k,lo,hi)=>k===0?hi-lo:(Math.sin(k*Math.PI*hi)-Math.sin(k*Math.PI*lo))/(k*Math.PI);
 const integralSin=(k,lo,hi)=>k===0?0:(Math.cos(k*Math.PI*lo)-Math.cos(k*Math.PI*hi))/(k*Math.PI);
 function integrals(count,lo,hi){
  const cc=new Float64Array(count*count),ss=new Float64Array(count*count),cs=new Float64Array(count*count),sc=new Float64Array(count*count);
  for(let i=1;i<=count;i++)for(let j=1;j<=count;j++){const k=(i-1)*count+j-1,a=integralCos(i-j,lo,hi),b=integralCos(i+j,lo,hi);cc[k]=(a+b)/2;ss[k]=(a-b)/2;cs[k]=(integralSin(j+i,lo,hi)+integralSin(j-i,lo,hi))/2;sc[k]=(integralSin(i+j,lo,hi)+integralSin(i-j,lo,hi))/2;}
  return{cc,ss,cs,sc};
 }
 function spatialMatrices(length,width,D,cells,mMax,nMax){
  const why=plate.validateGeometry(length,width,D)||validateTiling(cells);if(why)return failure(why);
  if(!Number.isSafeInteger(mMax)||!Number.isSafeInteger(nMax)||mMax<1||nMax<1||mMax*nMax>MAX_DIMENSION)return failure('The requested spatial plate basis exceeds the assessment size limit.');
  const matrices=plate.buildMatrices(length,width,D,mMax,nMax),G=new Float64Array(matrices.n*matrices.n),xCache=new Map(),yCache=new Map();
  for(const cell of cells){const [u0,u1,v0,v1]=cell.bounds,kx=u0+'|'+u1,ky=v0+'|'+v1;if(!xCache.has(kx))xCache.set(kx,integrals(mMax,u0,u1));if(!yCache.has(ky))yCache.set(ky,integrals(nMax,v0,v1));const x=xCache.get(kx),y=yCache.get(ky),[Nx,Ny,Nxy]=cell.N;
   for(let i=0;i<matrices.n;i++){const a=matrices.modes[i];for(let j=0;j<=i;j++){const b=matrices.modes[j],ix=(a.m-1)*mMax+b.m-1,iy=(a.n-1)*nMax+b.n-1;
    G[i*matrices.n+j]+=4*(Nx*a.alpha*b.alpha*x.cc[ix]*y.ss[iy]+Ny*a.beta*b.beta*x.ss[ix]*y.cc[iy]+Nxy*(a.alpha*b.beta*x.cs[ix]*y.sc[iy]+a.beta*b.alpha*x.sc[ix]*y.cs[iy]));
   }}
  }
  for(let i=0;i<matrices.n;i++)for(let j=0;j<i;j++)G[j*matrices.n+i]=G[i*matrices.n+j];
  return{bending:matrices.bending,geometric:G,modes:matrices.modes,n:matrices.n};
 }
 function criticalForSpatialBasis(length,width,D,cells,m,n){
  const matrices=spatialMatrices(length,width,D,cells,m,n);if(matrices.reason)return matrices;
  const key=[length,width,...flatten(D),m,n].join('|');let L=getCached(factors,key);
  if(!L){L=plate.cholesky(matrices.bending,matrices.n);if(!L)return failure('The spatial plate bending matrix is numerically indefinite.');factors.set(key,L);factorBytes+=L.byteLength;while(factors.size>128||factorBytes>MAX_MATRIX_BYTES){const first=factors.keys().next().value;factorBytes-=factors.get(first).byteLength;factors.delete(first);}}
  const normalized=plate.transformGeometric(L,matrices.geometric,matrices.n),mu=plate.largestEigenvalue(normalized,matrices.n);
  if(!finite(mu))return failure('The spatial plate eigenvalue could not be resolved.');
  return{reserveFactor:mu>0?1/mu:null,largestEigenvalue:mu,basisM:m,basisN:n,basisSize:matrices.n};
 }
 function nonDestabilizing(N){const scale=Math.max(...N.map(Math.abs));if(scale===0)return true;const [x,y,s]=N.map(v=>v/scale);return x<=0&&y<=0&&x*y-s*s>=0;}
 // For every admissible simply-supported displacement, integral |curvature|^2
 // >= integral (Laplacian w)^2 >= pi^2(1/L^2+1/W^2) integral |grad w|^2.
 // A positive Gershgorin bound for D and the greatest local principal load
 // therefore give a lower bound for *every* positive buckling eigenvalue.
 // This certifies only a non-governing case; it is never a case eigenvalue.
 function spatialLowerBound(length,width,D,cells,fixity=1){
  fixity??=1;
  const why=plate.validateGeometry(length,width,D)||validateTiling(cells);if(why||!positive(fixity))return null;
  const d=flatten(D),scale=Math.max(...d.map(Math.abs)),rounding=64*Number.EPSILON;
  const lower=Math.min(...[0,1,2].map(i=>d[3*i+i]/scale-[0,1,2].filter(j=>j!==i).reduce((sum,j)=>sum+Math.abs(d[3*i+j]/scale),0)))-rounding;
  if(!(lower>0))return null;
  let upper=0;for(const {N}of cells){const s=Math.max(...N.map(Math.abs));if(!s)continue;const [x,y,t]=N.map(v=>v/s);upper=Math.max(upper,Math.max(0,(x+y)/2+Math.hypot((x-y)/2,t)+rounding)*s);}
  if(!positive(upper))return null;
  const bound=fixity*(lower*scale/upper)*Math.PI**2*(1/length**2+1/width**2)*(1-128*Number.EPSILON);
  return positive(bound)?bound:null;
 }
 function solveSpatialPlate(length,width,D,cells,options={}){
  const why=plate.validateGeometry(length,width,D)||validateTiling(cells);if(why)return failure(why);
  const magnitude=cells.reduce((max,c)=>Math.max(max,...c.N.map(Math.abs)),0),d=flatten(D);
  if(magnitude===0||cells.every(c=>nonDestabilizing(c.N)))return{reserveFactor:99,noDestabilizingLoad:true,converged:true,convergenceError:0,basisOrder:0,basisSize:0,method:'No destabilizing membrane state in any recovered web cell'};
  const normalized=cells.map(c=>({bounds:c.bounds,N:c.N.map(x=>x/magnitude)})),first=normalized[0].N,uniform=normalized.every(c=>c.N.every((v,i)=>Math.abs(v-first[i])<=64*Number.EPSILON));
  if(uniform)return plate.solvePlate(length,width,D,cells[0].N,options);
  const tolerance=options.tolerance??TOLERANCE,maxDimension=options.maxDimension??MAX_DIMENSION,key=JSON.stringify([length,width,d,normalized,tolerance,maxDimension]),cached=getCached(results,key);
  if(cached)return{...cached,reserveFactor:cached.reserveFactor===null?null:cached.reserveFactor/magnitude};
  const aspect=length/width*(d[4]/d[0])**.25,history=[];let answer=null,previous=null,stable=0;
  for(const q of [3,5,7,9,11,13,15,17,19]){
   const m=Math.max(q,Math.ceil(aspect)+q-1),n=Math.max(q,Math.ceil(1/aspect)+q-1);if(m*n>maxDimension)break;
   const trial=criticalForSpatialBasis(length,width,d,normalized,m,n);if(trial.reason){answer=trial;break;}
   if(!positive(trial.reserveFactor)){previous=null;stable=0;continue;}
   const error=previous===null?null:Math.abs(previous-trial.reserveFactor)/trial.reserveFactor;history.push({order:q,m,n,reserveFactor:trial.reserveFactor,relativeChange:error});stable=error!==null&&error<=tolerance?stable+1:0;previous=trial.reserveFactor;
   answer={...trial,converged:stable>=2,basisOrder:q,convergenceError:error,method:'Spatial membrane-field double-sine Ritz plate',history};if(stable>=2)break;
  }
  if(!answer?.converged)answer={...answer,reserveFactor:null,converged:false,reason:answer?.reason||'The spatial web plate basis has not converged within the interactive mode limit; no reserve factor is assigned.'};
  results.set(key,answer);while(results.size>RESULT_LIMIT)results.delete(results.keys().next().value);
  return{...answer,reserveFactor:answer.reserveFactor===null?null:answer.reserveFactor/magnitude};
 }
 function prepareWeb(raw){
  if(raw.membership_complete===false)return failure('The full physical web-panel membership is unresolved.');const prepared=plate.preparePanel(raw);if(prepared.reason)return prepared;const bounds=[];
  for(const e of prepared.elements){const item=normalizedBounds(e.normalized_vertices_uv);if(item.reason)return item;bounds.push(item.bounds);}
  const why=validateTiling(bounds.map(b=>({bounds:b,N:[0,0,0]})));return why?failure(why):{...prepared,bounds};
 }
 const recordsOf=r=>r?.elementResults??r?.element_results,recordAt=(records,eid)=>records instanceof Map?records.get(eid)??records.get(String(eid)):records?.[String(eid)];
 function spatialDemand(prepared,records){
  const mean=plate.panelDemand(prepared,records);if(!mean.complete)return mean;
  const cells=prepared.elements.map((e,index)=>{const f=recordAt(records,e.eid).forces,N=[f.fx,f.fy,f.fxy],T=flatten(e.stress_transform);return{bounds:prepared.bounds[index],N:[0,1,2].map(i=>-N.reduce((sum,v,j)=>sum+T[3*i+j]*v,0))};});
  return{...mean,cells};
 }
 function assessWeb(raw,cases,input,mode){
  const prepared=prepareWeb(raw),c=input.componentFixities?.[mode]??raw.fixity_coefficient??1,baseReason=prepared.reason||(!positive(c)?'The component web fixity coefficient must be finite and positive.':''),caseResults=[],reasons=[];
  let governing=null,recovered=0,allNonDestabilizing=true;
  for(const item of cases.included){
   const demand=baseReason?{recovered:0,total:Math.max(1,raw.elements?.length||0),complete:false,reasons:[{reason:baseReason,count:1}]}:spatialDemand(prepared,recordsOf(item.result));recovered+=demand.recovered;for(const r of demand.reasons)reasons.push({...r,caseLabel:item.label});
   const assessment=demand.complete?solveSpatialPlate(prepared.length,prepared.width,prepared.D,demand.cells):failure('Incomplete spatial web membrane recovery.');if(demand.complete&&assessment.reason)reasons.push({reason:assessment.reason,count:1,caseLabel:item.label});
   const rf=assessment.converged?(assessment.noDestabilizingLoad?99:assessment.reserveFactor*c):null,valid=assessment.converged&&positive(rf);
   const row={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total:demand.total,recovered:demand.recovered,averageStressX:demand.complete?demand.stress[0]:null,averageStressY:demand.complete?demand.stress[1]:null,averageShear:demand.complete?demand.stress[2]:null,membraneResultants:demand.complete?demand.membrane:null,reserveFactor:valid?rf:null,noDestabilizingLoad:assessment.noDestabilizingLoad===true,converged:valid,basisOrder:assessment.basisOrder??null,basisM:assessment.basisM??null,basisN:assessment.basisN??null,basisSize:assessment.basisSize??null,convergenceError:assessment.convergenceError??null,method:assessment.method||'',reason:assessment.reason||'',lowerBound:!valid&&demand.complete?spatialLowerBound(prepared.length,prepared.width,prepared.D,demand.cells,c):null,certifiedNonGoverning:false,boundReason:''};caseResults.push(row);
   if(valid&&!row.noDestabilizingLoad){allNonDestabilizing=false;if(!governing||rf<governing.reserveFactor)governing=row;}
  }
  if(governing)for(const row of caseResults)if(!row.converged&&row.recovered===row.total&&positive(row.lowerBound)&&row.lowerBound>governing.reserveFactor*(1+1e-8)){
   row.certifiedNonGoverning=true;row.boundReason='Every positive eigenvalue is at least '+row.lowerBound.toPrecision(5)+' by a conservative bending/load bound, above the converged governing RF '+governing.reserveFactor.toPrecision(5)+'. The case eigenvalue remains unresolved.';
   for(const item of reasons)if(item.caseLabel===row.label&&item.reason===row.reason){item.reason=row.boundReason;item.certifiedNonGoverning=true;}
  }
  if(baseReason&&!reasons.length)reasons.push({reason:baseReason,count:1,caseLabel:''});
  const complete=!baseReason&&cases.complete&&caseResults.length>0&&caseResults.every(r=>r.recovered===r.total&&(r.converged||r.certifiedNonGoverning)),noDestabilizingLoad=complete&&allNonDestabilizing,reserveFactor=complete?(noDestabilizingLoad?99:governing?.reserveFactor??null):null,selected=governing||caseResults.find(r=>r.converged)||caseResults.find(r=>[r.averageStressX,r.averageStressY,r.averageShear].every(finite)),propertyIds=[...new Set(raw.property_ids||raw.elements?.map(e=>e.pid)||[])],materialIds=[...new Set((raw.elements||[]).flatMap(e=>e.material_ids||[]))];
  return{rowKey:mode+':'+raw.key,panelKey:raw.key,pid:propertyIds[0],propertyIds,label:raw.label||raw.key,names:[MODES[mode].label],propertyType:'Physical web plate',materialIds,locations:raw.locations||[],elementCount:raw.member_element_ids?.length||raw.elements?.length||0,maxStress:null,envelopeStress:null,allowableStress:null,envelopeCaseLabel:governing?.label||'',envelopeCaseKey:governing?.caseKey||'',reserveFactor,reserveFactorReason:baseReason||(!complete?'Incomplete case/spatial membrane recovery or unconverged web basis; reserve factor is not assessed.':''),complete,status:complete?'complete':recovered?'partial':'unavailable',coverage:{recovered,total:Math.max(1,raw.elements?.length||0)*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length)},caseResults,reasons,
   skinBuckling:{averageStressX:selected?.averageStressX??null,averageStressY:selected?.averageStressY??null,averageShear:selected?.averageShear??null,membraneResultants:selected?.membraneResultants??null,criticalFactor:noDestabilizingLoad?null:reserveFactor,length:raw.length_m,width:raw.width_m,fixityCoefficient:c,sourceCount:raw.elements?.length||0,noDestabilizingLoad,governingCase:governing?.label||'',basisOrder:selected?.basisOrder??null,basisM:selected?.basisM??null,basisN:selected?.basisN??null,basisSize:selected?.basisSize??null,convergenceError:selected?.convergenceError??null,method:selected?.method||'',note:noDestabilizingLoad?'RF 99 means every recovered spatial web cell is non-destabilizing in every included case; it is not a calculated failure load.':''}};
 }
 const WEB_NOTE='Web buckling retains each actual shell element\'s signed membrane resultants, transformed into the common panel axes, as a piecewise-constant field on the recorded equivalent rectangle. Exact sine/cosine integrals over mapped mesh cells preserve tension/compression gradients and signed shear; a zero mean under in-plane bending is not treated as zero demand. The displayed stresses are area-weighted means for context, not the spatial field used in the eigenproblem. The actual recovered mesh must resolve the gradient: one element through the height cannot reveal sub-element sign variation absent from its centroid resultants. The bending law is the area-averaged effective D (D-BᵀA⁻¹B for coupled laminates), using the existing thin-plate approximation. A double-sine Ritz basis imposes simply supported edges; two successive refinements must change RF by at most 0.5%. The user coefficient multiplies bending stiffness; it is an engineering restraint factor, not an exact clamped solution. Unsupported mappings, holes, overlaps and missing recovery remain unassessed. An unconverged case has no reported case eigenvalue; it can enter a complete envelope only if a conservative positive Gershgorin bending bound times pi^2(1/L^2+1/W^2), divided by the largest positive local principal membrane resultant, proves every possible critical factor is above another fully converged case. The certified lower bound and unresolved-case status are retained. Without that proof, unresolved convergence remains unassessed. No transverse-shear deformation, sandwich-face wrinkling, core failure, plasticity or postbuckling collapse is represented. RF 99 requires every recovered cell to have no destabilizing membrane state in every selected case.';
 const COLUMN_NOTE='Isolated-member Euler check: Pcr = c π² (EI)min / L². Only the actual cap or rib-stiffener section contributes stiffness and recovered axial force; no tributary skin or web stiffness is credited. The unbraced path is rib-to-rib for caps and skin-to-skin for rib stiffeners. The weakest actual section and its local compression are checked along that complete path; the lowest RF across stations and eligible cases governs. This elastic engineering check does not include lateral-torsional buckling, crippling, intermediate elastic bracing, yielding or nonlinear collapse. Rotational restraint is represented only by c (1 for pinned ends).';
 function build(input,cases,mode=input.failureMode){
  const descriptor=MODES[mode];if(!descriptor)throw Error('Unknown component buckling assessment.');
  const rawRows=input.generated===false?[]:rowsFor(input,mode),rows=rawRows.map(original=>{
   const raw=(original.membership_complete===false||original.applicable===false)?{...original,reason:original.reason||(original.applicable===false?'This physical component check is not applicable.':'The full physical component membership is unresolved.')}:original;
   let row;if(descriptor.type==='plate')row=assessWeb(raw,cases,input,mode);
   else if(descriptor.type==='column')row=euler.assessColumn(raw,cases,{endFactor:input.componentFixities?.[mode]??raw.fixity_coefficient});
   else row=blade.assessBlade(raw,cases);
   const propertyIds=[...new Set(raw.property_ids||raw.bars?.map(e=>e.pid)||raw.stations?.flatMap(s=>(s.force_terms||[]).map(t=>t.pid))||[])].filter(n=>Number.isSafeInteger(Number(n))&&Number(n)>0).map(Number);
   const note=descriptor.type==='plate'?WEB_NOTE:descriptor.type==='column'?COLUMN_NOTE:blade.NOTE;
   return{...row,rowKey:mode+':'+raw.key,panelKey:raw.key,label:raw.label||raw.key,pid:propertyIds[0]??row.pid,propertyIds:propertyIds.length?propertyIds:row.propertyIds||[],propertyType:descriptor.type==='plate'?'Physical web plate':descriptor.type==='column'?'Isolated component member':'Rib-stiffener T blade',locations:raw.locations||[],names:[descriptor.label],componentBuckling:{kind:descriptor.kind,method:descriptor.type,scope:raw.label||raw.key,note,fieldMethod:descriptor.type==='plate'?'Spatial piecewise membrane field':descriptor.type==='column'?'Isolated-member section cuts':'Mean signed bar axial stress'}};
  });
  const note=(descriptor.type==='plate'?WEB_NOTE:descriptor.type==='column'?COLUMN_NOTE:blade.NOTE)+' SOL101 and converged full-load SOL106 cases only; nonlinear ratios are elastic demand checks, not predicted load multipliers.'+(!rawRows.length?' No verified generated '+descriptor.kind.replaceAll('_',' ')+' geometry is available.':'');
  return{failureMode:mode,rows,includedCases:cases.included.map(({result,...item})=>item),excludedCases:cases.excluded.map(({result,...item})=>item),missingCases:cases.missing,method:descriptor.type==='plate'?'spatial_field':'maximum',percentile:100,stressUnit:input.sourceUnits?'source stress units':'MPa',stressFactor:input.sourceUnits?1:1e-6,forceUnit:input.sourceUnits?'source force units':'N',forceFactor:1,lengthUnit:input.sourceUnits?'source length units':'m',complete:cases.complete&&rows.length>0&&rows.every(r=>r.complete),coverage:{recovered:rows.reduce((n,r)=>n+r.coverage.recovered,0),total:rows.reduce((n,r)=>n+r.coverage.total,0),properties:rows.length},note};
 }
 return{MODES,rowsFor,normalizedBounds,validateTiling,spatialMatrices,criticalForSpatialBasis,spatialLowerBound,solveSpatialPlate,prepareWeb,spatialDemand,assessWeb,build,WEB_NOTE,COLUMN_NOTE,clearCaches,cacheInfo};
});
