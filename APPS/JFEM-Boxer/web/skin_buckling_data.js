/* Simply supported rectangular-plate Ritz assessment of actual skin regions.
 * Curvature and membrane-gradient energies are integrated analytically. Both
 * parity sectors are retained; no empirical compression/shear interaction is
 * substituted for the coupled eigenvalue problem. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSkinBucklingData=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0;
 const failure=reason=>({reason,converged:false});
 const matrixCache=new Map(),resultCache=new Map();let matrixBytes=0;
 const MATRIX_BYTE_LIMIT=24*1024*1024,MAX_DIMENSION=256,RESULT_LIMIT=2048,TOLERANCE=.005;
 function cacheGet(cache,key){const value=cache.get(key);if(value){cache.delete(key);cache.set(key,value);}return value;}
 function rememberMatrix(key,value){const bytes=3*value.blocks.reduce((sum,block)=>sum+block.n*block.n,0)*8;matrixCache.set(key,{...value,bytes});matrixBytes+=bytes;while(matrixBytes>MATRIX_BYTE_LIMIT||matrixCache.size>128){const first=matrixCache.keys().next().value;matrixBytes-=matrixCache.get(first).bytes;matrixCache.delete(first);}return value;}
 function clearCaches(){matrixCache.clear();resultCache.clear();matrixBytes=0;}
 function cacheInfo(){return{matrixEntries:matrixCache.size,matrixBytes,resultEntries:resultCache.size,matrixByteLimit:MATRIX_BYTE_LIMIT,resultLimit:RESULT_LIMIT};}
 const flatten=D=>Array.isArray(D)&&D.length===3&&D.every(r=>Array.isArray(r)&&r.length===3)?D.flat():Array.from(D||[]);
 function cholesky(A,n){
  const L=new Float64Array(n*n);
  for(let i=0;i<n;i++)for(let j=0;j<=i;j++){let v=A[i*n+j];for(let k=0;k<j;k++)v-=L[i*n+k]*L[j*n+k];if(i===j){if(!positive(v))return null;L[i*n+j]=Math.sqrt(v);}else L[i*n+j]=v/L[j*n+j];}
  return L;
 }
 function validateGeometry(length,width,D){
  if(!positive(length)||!positive(width))return 'Positive average panel length and width are required.';
  const d=flatten(D);if(d.length!==9||!d.every(finite))return 'A finite 3 by 3 effective plate bending matrix is required.';
  const scale=Math.max(...d.map(Math.abs));if(!positive(scale))return 'The effective plate bending matrix has no positive stiffness.';
  for(let i=0;i<3;i++)for(let j=0;j<i;j++)if(Math.abs(d[3*i+j]-d[3*j+i])>64*Number.EPSILON*scale)return 'The effective plate bending matrix must be symmetric.';
  if(!cholesky(d.map(x=>x/scale),3))return 'The effective plate bending matrix is not positive definite.';
  return '';
 }
 // Integrals divided by L/2, the common sine-mode norm. This expression is
 // evaluated only at integer modes: same parity has an exact zero integral.
 const sc=(m,p)=>((m+p)%2===0||m===p)?0:4*m/(Math.PI*(m*m-p*p));
 function buildMatrices(length,width,D,mMax,nMax){
  const d=flatten(D),modes=[];for(let m=1;m<=mMax;m++)for(let n=1;n<=nMax;n++)modes.push({m,n,alpha:m*Math.PI/length,beta:n*Math.PI/width});
  const size=modes.length,bending=new Float64Array(size*size),gx=new Float64Array(size*size),gy=new Float64Array(size*size),gxy=new Float64Array(size*size);
  for(let i=0;i<size;i++){
   const a=modes[i],aa=a.alpha*a.alpha,bb=a.beta*a.beta;
   bending[i*size+i]=d[0]*aa*aa+2*(d[1]+2*d[8])*aa*bb+d[4]*bb*bb;gx[i*size+i]=aa;gy[i*size+i]=bb;
   for(let j=0;j<i;j++){
    const b=modes[j],sscc=sc(a.m,b.m)*sc(a.n,b.n),ccss=sc(b.m,a.m)*sc(b.n,a.n);
    const B=-2*(d[2]*(aa*b.alpha*b.beta*sscc+a.alpha*a.beta*b.alpha*b.alpha*ccss)+d[5]*(bb*b.alpha*b.beta*sscc+a.alpha*a.beta*b.beta*b.beta*ccss));
    const G=a.alpha*b.beta*sc(b.m,a.m)*sc(a.n,b.n)+a.beta*b.alpha*sc(a.m,b.m)*sc(b.n,a.n);
    bending[i*size+j]=bending[j*size+i]=B;gxy[i*size+j]=gxy[j*size+i]=G;
   }
  }
  return{bending,gx,gy,gxy,modes,n:size};
 }
 // Symmetric Householder reduction, followed by Sturm bisection. Unlike a
 // power iteration, this finds the largest algebraic eigenvalue even when
 // tensile stabilization produces large negative eigenvalues or parity
 // separates the governing mode from a chosen initial vector.
 function largestEigenvalue(matrix,n){
  if(!Number.isSafeInteger(n)||n<1||matrix.length!==n*n)return null;
  let scale=0;for(const v of matrix){if(!finite(v))return null;scale=Math.max(scale,Math.abs(v));}if(scale===0)return 0;
  const A=Float64Array.from(matrix,x=>x/scale),off=new Float64Array(Math.max(0,n-1));
  for(let k=0;k<n-2;k++){
   const count=n-k-1,v=new Float64Array(count);let norm=0;for(let i=0;i<count;i++){v[i]=A[(k+1+i)*n+k];norm=Math.hypot(norm,v[i]);}
   if(norm===0){off[k]=0;continue;}
   const sign=v[0]>=0?1:-1;off[k]=-sign*norm;v[0]+=sign*norm;let vnorm=0;for(const x of v)vnorm=Math.hypot(vnorm,x);for(let i=0;i<count;i++)v[i]/=vnorm;
   const p=new Float64Array(count);for(let i=0;i<count;i++){let s=0;for(let j=0;j<count;j++)s+=A[(k+1+i)*n+k+1+j]*v[j];p[i]=s;}
   let alpha=0;for(let i=0;i<count;i++)alpha+=v[i]*p[i];for(let i=0;i<count;i++)p[i]=2*(p[i]-alpha*v[i]);
   for(let i=0;i<count;i++)for(let j=0;j<=i;j++){const value=A[(k+1+i)*n+k+1+j]-v[i]*p[j]-p[i]*v[j];A[(k+1+i)*n+k+1+j]=A[(k+1+j)*n+k+1+i]=value;}
  }
  if(n>1)off[n-2]=A[(n-1)*n+n-2];const diag=new Float64Array(n);let lower=Infinity,upper=-Infinity;
  for(let i=0;i<n;i++){diag[i]=A[i*n+i];const radius=(i?Math.abs(off[i-1]):0)+(i+1<n?Math.abs(off[i]):0);lower=Math.min(lower,diag[i]-radius);upper=Math.max(upper,diag[i]+radius);}
  const pad=64*Number.EPSILON*Math.max(1,Math.abs(lower),Math.abs(upper));lower-=pad;upper+=pad;
  function below(x){let count=0,pivot=diag[0]-x;if(Math.abs(pivot)<1e-280)pivot=-1e-280;if(pivot<0)count++;for(let i=1;i<n;i++){pivot=diag[i]-x-off[i-1]*off[i-1]/pivot;if(Math.abs(pivot)<1e-280)pivot=-1e-280;if(pivot<0)count++;}return count;}
  for(let iteration=0;iteration<100;iteration++){const mid=(lower+upper)/2;if(below(mid)<n)lower=mid;else upper=mid;if(upper-lower<=32*Number.EPSILON*Math.max(1,Math.abs(lower),Math.abs(upper)))break;}
  return scale*(lower+upper)/2;
 }
 function transformGeometric(L,G,n){
  const left=new Float64Array(n*n),answer=new Float64Array(n*n);
  for(let j=0;j<n;j++)for(let i=0;i<n;i++){let value=G[i*n+j];for(let k=0;k<i;k++)value-=L[i*n+k]*left[k*n+j];left[i*n+j]=value/L[i*n+i];}
  for(let i=0;i<n;i++)for(let j=0;j<n;j++){let value=left[i*n+j];for(let k=0;k<j;k++)value-=L[j*n+k]*answer[i*n+k];answer[i*n+j]=value/L[j*n+j];}
  for(let i=0;i<n;i++)for(let j=0;j<i;j++){const value=.5*(answer[i*n+j]+answer[j*n+i]);answer[i*n+j]=answer[j*n+i]=value;}return answer;
 }
 function basisPrepared(length,width,D,mMax,nMax){
  const key=[length,width,...flatten(D),mMax,nMax].join('|'),cached=cacheGet(matrixCache,key);if(cached)return cached;
  const matrices=buildMatrices(length,width,D,mMax,nMax),blocks=[];
  // D16/D26 and shear couple modes only when both longitudinal and transverse
  // mode parity change. Thus m+n parity is conserved. Solve both independent
  // families, preserving the lower symmetric OR antisymmetric buckling root.
  for(const parity of [0,1]){const indices=matrices.modes.map((mode,i)=>(mode.m+mode.n)%2===parity?i:-1).filter(i=>i>=0),n=indices.length;if(!n)continue;
   const extract=A=>Float64Array.from({length:n*n},(_,k)=>A[indices[Math.floor(k/n)]*matrices.n+indices[k%n]]),L=cholesky(extract(matrices.bending),n);if(!L)return failure('The plate basis has a singular or numerically indefinite bending matrix.');
   blocks.push({n,gx:transformGeometric(L,extract(matrices.gx),n),gy:transformGeometric(L,extract(matrices.gy),n),gxy:transformGeometric(L,extract(matrices.gxy),n)});
  }
  return rememberMatrix(key,{n:matrices.n,blocks});
 }
 function criticalForBasis(length,width,D,N,mMax,nMax){
  const why=validateGeometry(length,width,D);if(why)return failure(why);if(!Array.isArray(N)||N.length!==3||!N.every(finite))return failure('Three finite signed membrane resultants are required.');
  if(!Number.isSafeInteger(mMax)||!Number.isSafeInteger(nMax)||Math.min(mMax,nMax)<1||mMax*nMax>MAX_DIMENSION)return failure('The requested plate basis exceeds the assessment size limit.');
  const p=basisPrepared(length,width,D,mMax,nMax);if(p.reason)return p;let mu=-Infinity;
  for(const block of p.blocks){const G=new Float64Array(block.n*block.n);for(let i=0;i<G.length;i++)G[i]=N[0]*block.gx[i]+N[1]*block.gy[i]+N[2]*block.gxy[i];const eigenvalue=largestEigenvalue(G,block.n);if(eigenvalue===null||!finite(eigenvalue))return failure('The plate eigenvalue calculation is numerically unresolved.');mu=Math.max(mu,eigenvalue);}
  return{reserveFactor:mu>0?1/mu:null,largestEigenvalue:mu,basisM:mMax,basisN:nMax,basisSize:p.n};
 }
 function diagonalPlate(length,width,d,N){
  const [Nx,Ny]=N,D11=d[0],D22=d[4],H=d[1]+2*d[8],ax=(Math.PI/length)**2,by=(Math.PI/width)**2;
  let best=Infinity,modeM=null,modeN=null;
  function trial(m,n){const x=ax*m*m,y=by*n*n,den=Nx*x+Ny*y;if(den>0){const ratio=(D11*x*x+2*H*x*y+D22*y*y)/den;if(positive(ratio)&&ratio<best){best=ratio;modeM=m;modeN=n;}}}
  for(let m=1;m<=3;m++)for(let n=1;n<=3;n++)trial(m,n);
  if(Nx>0){const start=Math.max(1,Math.floor(Math.sqrt(Math.max(0,-Ny*by/(Nx*ax))))+1);trial(start,1);const a=D11*Nx,b=2*D11*Ny*by,c=(2*H*Ny-D22*Nx)*by*by,disc=b*b-4*a*c;if(disc>=0){const x=(-b+Math.sqrt(disc))/(2*a),m=Math.sqrt(Math.max(0,x/ax));for(const k of [Math.floor(m),Math.ceil(m)])if(k>=1)trial(k,1);}}
  if(Ny>0){const start=Math.max(1,Math.floor(Math.sqrt(Math.max(0,-Nx*ax/(Ny*by))))+1);trial(1,start);const a=D22*Ny,b=2*D22*Nx*ax,c=(2*H*Nx-D11*Ny)*ax*ax,disc=b*b-4*a*c;if(disc>=0){const y=(-b+Math.sqrt(disc))/(2*a),n=Math.sqrt(Math.max(0,y/by));for(const k of [Math.floor(n),Math.ceil(n)])if(k>=1)trial(1,k);}}
  if(!positive(best))return failure('No finite destabilizing plate mode could be resolved.');
  const coupling=Math.min(0,H),large=(D11+D22+Math.hypot(D11-D22,2*coupling))/2,C=(D11*D22-coupling*coupling)/large;
  if(!positive(C))return failure('A lower bound for the plate high-mode stiffness is numerically unresolved.');
  // B >= C/2 (alpha²+beta²)² and G <= max(Nx,Ny)(alpha²+beta²).
  // This excludes every omitted integer mode, rather than assuming m=n=1.
  const radius=2*Math.max(Nx,Ny)*best/C,mMax=Math.max(1,Math.floor(Math.sqrt(radius/ax))),nMax=Math.max(1,Math.floor(Math.sqrt(radius/by)));
  if(!Number.isSafeInteger(mMax)||!Number.isSafeInteger(nMax)||mMax*nMax>1e6)return failure('The exact diagonal plate mode search is too large for an interactive assessment.');
  for(let m=1;m<=mMax;m++)for(let n=1;n<=nMax;n++)if(ax*m*m+by*n*n<=radius*(1+64*Number.EPSILON))trial(m,n);
  return{reserveFactor:best,converged:true,convergenceError:0,basisOrder:0,basisM:mMax,basisN:nMax,basisSize:mMax*nMax,modeM,modeN,method:'Exact uncoupled sine-mode search with a high-mode bound'};
 }
 function solvePlate(length,width,D,N,options={}){
  const why=validateGeometry(length,width,D);if(why)return failure(why);if(!Array.isArray(N)||N.length!==3||!N.every(finite))return failure('Three finite signed membrane resultants are required.');
  const d=flatten(D),magnitude=Math.max(...N.map(Math.abs));if(magnitude===0)return{reserveFactor:99,noDestabilizingLoad:true,converged:true,convergenceError:0,basisOrder:0,basisSize:0,method:'No destabilizing mean membrane stress'};
  // A rotated isotropic tensor can retain floating-point D16/D26 and shear
  // remnants. Remove only coupling terms below relative roundoff; normal
  // compression/tension components are never clipped, however small.
  const roundoff=64*Number.EPSILON,stiffnessScale=Math.max(...d.map(Math.abs));if(Math.abs(d[2])<=roundoff*stiffnessScale)d[2]=d[6]=0;if(Math.abs(d[5])<=roundoff*stiffnessScale)d[5]=d[7]=0;
  const direction=N.map(x=>x/magnitude);if(Math.abs(direction[2])<=roundoff)direction[2]=0;
  const trace=direction[0]+direction[1],gap=Math.hypot(direction[0]-direction[1],2*direction[2]),minor=.5*(trace-gap),principal=direction[2]===0?Math.max(direction[0],direction[1]):trace<0?(direction[0]*direction[1]-direction[2]*direction[2])/minor:.5*(trace+gap);
  if(principal<=0)return{reserveFactor:99,noDestabilizingLoad:true,converged:true,convergenceError:0,basisOrder:0,basisSize:0,method:'No destabilizing mean membrane stress'};
  const tolerance=options.tolerance??TOLERANCE,maxDimension=options.maxDimension??MAX_DIMENSION,key=[length,width,...d,...direction,tolerance,maxDimension].join('|'),cached=cacheGet(resultCache,key);
  if(cached)return{...cached,reserveFactor:cached.reserveFactor==null?null:cached.reserveFactor/magnitude};
  let answer;
  if(d[2]===0&&d[5]===0&&direction[2]===0)answer=diagonalPlate(length,width,d,direction);
  else{
   const aspect=length/width*(d[4]/d[0])**.25,orders=[3,5,7,9,11,13,15,17,19],history=[];let stable=0,previous=null;
   for(const q of orders){
    const m=Math.max(q,Math.ceil(aspect)+q-1),n=Math.max(q,Math.ceil(1/aspect)+q-1);if(m*n>maxDimension)break;
    const trial=criticalForBasis(length,width,d,direction,m,n);if(trial.reason){answer=trial;break;}
    if(!positive(trial.reserveFactor)){previous=null;stable=0;continue;}
    const error=previous===null?null:Math.abs(previous-trial.reserveFactor)/trial.reserveFactor;history.push({order:q,m,n,reserveFactor:trial.reserveFactor,relativeChange:error});
    stable=error!==null&&error<=tolerance?stable+1:0;previous=trial.reserveFactor;
    answer={...trial,converged:stable>=2,basisOrder:q,convergenceError:error,method:'Simply supported double-sine Ritz plate',history};
    if(stable>=2)break;
   }
   if(!answer?.converged)answer={...answer,reserveFactor:null,converged:false,reason:answer?.reason||'The coupled plate basis has not converged within the interactive mode limit; no reserve factor is assigned.'};
  }
  resultCache.set(key,answer);while(resultCache.size>RESULT_LIMIT)resultCache.delete(resultCache.keys().next().value);
  return{...answer,reserveFactor:answer.reserveFactor==null?null:answer.reserveFactor/magnitude};
 }
 const recordsOf=result=>result?.elementResults??result?.element_results;
 const recordAt=(records,eid)=>records instanceof Map?records.get(eid)??records.get(String(eid)):records?.[String(eid)];
 function preparePanel(panel){
  if(panel?.reason)return failure(panel.reason);const elements=panel?.elements;if(!Array.isArray(elements)||!elements.length)return failure('No actual skin elements belong to this panel.');
  const seen=new Set(),D=new Array(9).fill(0);let area=0;
  for(const e of elements){if(!Number.isSafeInteger(Number(e.eid))||Number(e.eid)<=0||seen.has(Number(e.eid)))return failure('Skin element ownership is missing or duplicated.');seen.add(Number(e.eid));if(!positive(e.area_m2)||!positive(e.thickness_m))return failure('Every skin element needs positive physical area and thickness.');const d=flatten(e.bending_matrix_Nm),t=flatten(e.stress_transform);if(d.length!==9||!d.every(finite)||t.length!==9||!t.every(finite))return failure('A skin element lacks a finite plate stiffness or stress transformation.');area+=e.area_m2;for(let i=0;i<9;i++)D[i]+=e.area_m2*d[i];}
  if(!positive(area))return failure('The physical panel area exceeds the numeric range.');for(let i=0;i<9;i++)D[i]/=area;
  const why=validateGeometry(panel.length_m,panel.width_m,D);return why?failure(why):{D,area,elements,length:panel.length_m,width:panel.width_m};
 }
 function panelDemand(prepared,records){
  const stress=[0,0,0],membrane=[0,0,0],reasons=[];let recovered=0;
  for(const e of prepared.elements){const record=recordAt(records,e.eid),forces=record?.forces,raw=[forces?.fx,forces?.fy,forces?.fxy];
   if(!raw.every(finite)){reasons.push({reason:'Element '+e.eid+' has no complete signed membrane resultants fx, fy and fxy.',count:1});continue;}
   const units=record?.force_units;if(units&&['fx','fy','fxy'].some(k=>units[k]&&units[k]!=='N/m')){reasons.push({reason:'Element '+e.eid+' membrane resultant units are not verified N/m.',count:1});continue;}
   const T=flatten(e.stress_transform),rotated=[0,1,2].map(i=>raw.reduce((sum,x,j)=>sum+T[3*i+j]*x,0));if(!rotated.every(finite)){reasons.push({reason:'Element '+e.eid+' projected membrane resultants exceed the numeric range.',count:1});continue;}
   const weight=e.area_m2/prepared.area;for(let i=0;i<3;i++){membrane[i]+=weight*rotated[i];stress[i]+=weight*rotated[i]/e.thickness_m;}recovered++;
  }
  if(!stress.every(finite)||!membrane.every(finite))reasons.push({reason:'The area-weighted panel membrane demand exceeds the numeric range.',count:1});
  return{stress,membrane,compressionResultants:membrane.map(x=>-x),recovered,total:prepared.elements.length,reasons,complete:reasons.length===0&&recovered===prepared.elements.length};
 }
 function panelLocations(panel){const strip=Number(panel.strip_index),bay=Number(panel.rib_bay),segment=Number(panel.segment)||1;if(!['upper','lower'].includes(panel.skin)||!Number.isSafeInteger(strip)||strip<1||!Number.isSafeInteger(bay)||bay<1)return[];return[{group:panel.skin,rowKey:'skin_strip:'+strip,rowLabel:Array.isArray(panel.boundary_labels)&&panel.boundary_labels.length>=2?panel.boundary_labels.join('–'):panel.boundary_labels?.left&&panel.boundary_labels?.right?panel.boundary_labels.left+'–'+panel.boundary_labels.right:panel.label||'Skin strip '+strip,index:bay,columnLabel:'R'+bay+'–R'+(bay+1),key:panel.key,part:'skin_panel',cellLabel:'Skin panel'+(segment>1?' · segment '+segment:''),ribs:false,stripIndex:strip,segment,panelKey:panel.key}];}
 function assessPanel(panel,cases,input){
  const prepared=preparePanel(panel),c=input.skinFixityCoefficient??panel.fixity_coefficient??1,baseReason=prepared.reason||(!positive(c)?'The skin-panel fixity coefficient must be a finite positive number.':''),caseResults=[],reasons=[];
  let governing=null,recovered=0,allNonDestabilizing=true;
  for(const item of cases.included){
   const demand=baseReason?{recovered:0,total:Math.max(1,panel.elements?.length||0),complete:false,reasons:[{reason:baseReason,count:1}]}:panelDemand(prepared,recordsOf(item.result));recovered+=demand.recovered;for(const reason of demand.reasons)reasons.push({...reason,caseLabel:item.label});
   const assessment=demand.complete?solvePlate(prepared.length,prepared.width,prepared.D,demand.compressionResultants):failure('Incomplete skin-panel membrane recovery.');if(demand.complete&&assessment.reason)reasons.push({reason:assessment.reason,count:1,caseLabel:item.label});
   const rf=assessment.converged?(assessment.noDestabilizingLoad?99:assessment.reserveFactor*c):null,valid=assessment.converged&&positive(rf);
   const row={caseKey:item.caseKey,caseId:item.caseId,label:item.label,solution:item.solution,total:demand.total,recovered:demand.recovered,averageStressX:demand.complete?demand.stress[0]:null,averageStressY:demand.complete?demand.stress[1]:null,averageShear:demand.complete?demand.stress[2]:null,membraneResultants:demand.complete?demand.membrane:null,reserveFactor:valid?rf:null,noDestabilizingLoad:assessment.noDestabilizingLoad===true,converged:valid,basisOrder:assessment.basisOrder??null,basisM:assessment.basisM??null,basisN:assessment.basisN??null,basisSize:assessment.basisSize??null,convergenceError:assessment.convergenceError??null,modeM:assessment.modeM??null,modeN:assessment.modeN??null,method:assessment.method||'',reason:assessment.reason||''};caseResults.push(row);
   if(valid&&!row.noDestabilizingLoad){allNonDestabilizing=false;if(!governing||rf<governing.reserveFactor)governing=row;}
  }
  if(baseReason&&!reasons.length)reasons.push({reason:baseReason,count:1,caseLabel:''});
  const complete=!baseReason&&cases.complete&&caseResults.length>0&&caseResults.every(r=>r.recovered===r.total&&r.converged),noDestabilizingLoad=complete&&allNonDestabilizing,reserveFactor=complete?(noDestabilizingLoad?99:governing?.reserveFactor??null):null,selected=governing||caseResults.find(r=>r.converged)||caseResults.find(r=>[r.averageStressX,r.averageStressY,r.averageShear].every(finite))||null;
  const propertyIds=[...new Set((panel.property_ids||panel.elements?.map(e=>e.pid)||[]).map(Number).filter(n=>Number.isSafeInteger(n)&&n>0))],materialIds=[...new Set((panel.elements||[]).flatMap(e=>e.material_ids||[]).map(Number).filter(n=>Number.isSafeInteger(n)&&n>0))];
  const reserveFactorReason=baseReason||(!complete?'Incomplete case or membrane recovery, or unconverged plate basis; panel reserve factor is not assessed.':''),total=Math.max(1,panel.elements?.length||0)*(cases.included.length+cases.excluded.filter(c=>c.relevant).length+cases.missing.length);
  const note=noDestabilizingLoad?'RF 99 means the fully recovered mean membrane stress has no destabilizing compression/shear combination in any included case; it is a display sentinel, not a calculated failure multiplier.':'';
  return{rowKey:'skin:'+panel.key,panelKey:panel.key,pid:propertyIds[0],propertyIds,panelIds:panel.panel_ids||[],label:(panel.skin==='upper'?'Upper':'Lower')+' · R'+panel.rib_bay+'–R'+(Number(panel.rib_bay)+1)+' · '+(panel.label||panel.key)+(Number(panel.segment)>1?' · segment '+panel.segment:''),names:['Skin panel buckling'],propertyType:'Skin panel plate',materialIds,locations:panelLocations(panel),elementCount:panel.elements?.length||0,maxStress:null,envelopeStress:null,allowableStress:null,envelopeCaseLabel:governing?.label||'',envelopeCaseKey:governing?.caseKey||'',reserveFactor,reserveFactorReason,complete,status:complete?'complete':recovered?'partial':'unavailable',coverage:{recovered,total},caseResults,reasons,
   skinBuckling:{averageStressX:selected?.averageStressX??null,averageStressY:selected?.averageStressY??null,averageShear:selected?.averageShear??null,membraneResultants:selected?.membraneResultants??null,criticalFactor:noDestabilizingLoad?null:reserveFactor,length:panel.length_m,width:panel.width_m,fixityCoefficient:c,sourceCount:panel.elements?.length||0,noDestabilizingLoad,governingCase:governing?.label||'',basisOrder:selected?.basisOrder??null,basisM:selected?.basisM??null,basisN:selected?.basisN??null,basisSize:selected?.basisSize??null,convergenceError:selected?.convergenceError??null,modeM:selected?.modeM??null,modeN:selected?.modeN??null,method:selected?.method||'',note}};
 }
 const NOTE='Skin-panel buckling uses an equivalent rectangular plate bounded by the actual ribs and stringer/spar paths. Length and width are the mean lengths of the two opposite physical sides. Recovered shell membrane resultants divided by each actual thickness give the mean membrane stresses; they are transformed to common panel span/transverse axes and area averaged. The buckling demand is the area-weighted membrane resultant, not average thickness multiplied by average stress. Tension is positive in the displayed stresses; both normal components and signed shear enter one geometric-stiffness matrix, retaining tensile stabilization. The area-weighted effective plate bending matrix includes the full anisotropic terms. For coupled laminates, membrane-free D − Bᵀ A⁻¹ B is an equivalent-plate approximation. A double-sine Rayleigh–Ritz basis imposes simply supported edges; two successive refinements must change the reserve factor by no more than 0.5%. Uncoupled compression uses an exact integer-mode search with an omitted-mode bound. The user skin fixity coefficient multiplies bending stiffness (1 is simply supported); it is an engineering restraint factor, not an exact clamped-edge solution. This elastic homogenized thin-plate check omits transverse-shear deformation, sandwich-face wrinkling, core instability, local peaks, variable-field instability, plasticity and nonlinear/postbuckling collapse. The worst complete SOL101/full-load SOL106 case governs. Incomplete recovery, unsupported panel topology and unresolved basis convergence are unassessed. RF 99 means no destabilizing averaged membrane load, not a finite calculated buckling multiplier. Stress-percentile trimming and stringer Euler fixity do not apply.';
 function build(input,cases){const panels=Array.isArray(input.skinBucklingPanels)?input.skinBucklingPanels:[],rows=panels.map(panel=>assessPanel(panel,cases,input));return{failureMode:'skin_buckling',rows,includedCases:cases.included.map(({result,...item})=>item),excludedCases:cases.excluded.map(({result,...item})=>item),missingCases:cases.missing,method:'area_mean',percentile:100,stressUnit:'MPa',stressFactor:1e-6,lengthUnit:'m',complete:cases.complete&&rows.length>0&&rows.every(r=>r.complete),coverage:{recovered:rows.reduce((a,r)=>a+r.coverage.recovered,0),total:rows.reduce((a,r)=>a+r.coverage.total,0),properties:rows.length},note:NOTE+(!panels.length?' No actual skin-panel geometry is available for this model.':'')};}
 return{buildMatrices,largestEigenvalue,cholesky,criticalForBasis,solvePlate,preparePanel,panelDemand,panelLocations,assessPanel,build,clearCaches,cacheInfo,NOTE};
});
