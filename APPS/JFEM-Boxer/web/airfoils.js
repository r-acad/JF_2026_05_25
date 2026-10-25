(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingAirfoils=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 let catalogue=null,pending=null,catalogueVersion=0;
 const STATIONS_KEY="airfoil.stations",MAX_STATIONS=100;
 function nacaProfile(name,{n=121,closed=true}={}){
  const digits=String(name||"").trim().toUpperCase().replace(/NACA/g,"").replace(/[\s_-]/g,"");
  if(!/^\d{4,5}$/.test(digits))throw Error("Enter a NACA 4- or 5-digit code, for example 2412 or 23012.");
  if(!Number.isInteger(n)||n<21||n>20000)throw Error("Section points must be an integer between 21 and 20000.");
  const t=Number(digits.slice(-2))/100;if(!(t>0))throw Error("The NACA airfoil must have nonzero thickness.");
  const result={name:"NACA "+digits,id:"NACA"+digits,source:"naca",thickness_ratio:t,xu:[],zu:[],xl:[],zl:[]};
  const table=[[.05,.058,361.4],[.1,.126,51.64],[.15,.2025,15.957],[.2,.29,6.643],[.25,.391,3.23]];
  function camber(x){
   if(digits.length===4){const m=Number(digits[0])/100,p=Number(digits[1])/10;if(!m||!p)return[0,0];return x<p?[m/(p*p)*(2*p*x-x*x),2*m/(p*p)*(p-x)]:[m/((1-p)**2)*(1-2*p+2*p*x-x*x),2*m/((1-p)**2)*(p-x)];}
   const cl=Number(digits[0])*.15,p=Number(digits[1])/20;if(!cl)return[0,0];let r,k;
   if(p<=table[0][0])[,r,k]=table[0];else if(p>=table.at(-1)[0])[,r,k]=table.at(-1);else{let i=0;while(table[i+1][0]<=p)i++;const w=(p-table[i][0])/(table[i+1][0]-table[i][0]);r=table[i][1]+w*(table[i+1][1]-table[i][1]);k=table[i][2]+w*(table[i+1][2]-table[i][2]);}
   const scale=cl/.3;return x<=r?[scale*k/6*(x**3-3*r*x*x+r*r*(3-r)*x),scale*k/6*(3*x*x-6*r*x+r*r*(3-r))]:[scale*k*r**3/6*(1-x),-scale*k*r**3/6];
  }
  for(let i=0;i<n;i++){const x=.5*(1-Math.cos(Math.PI*i/(n-1))),[z,dz]=camber(x),yt=5*t*(.2969*Math.sqrt(x)-.126*x-.3516*x*x+.2843*x**3+(closed?-.1036:-.1015)*x**4),angle=Math.atan(dz);result.xu.push(x-yt*Math.sin(angle));result.zu.push(z+yt*Math.cos(angle));result.xl.push(x+yt*Math.sin(angle));result.zl.push(z-yt*Math.cos(angle));}
  for(const key of["xu","xl"]){const x=result[key];x[0]=0;x[n-1]=1;for(let i=1;i<n;i++)if(x[i]<=x[i-1]+1e-9)x[i]=x[i-1]+1e-9;x[n-1]=Math.max(x[n-1],1);}
  if(digits.length===5&&digits[2]!=="0"&&digits[0]!=="0")result.warning="Reflexed 5-digit mean lines are not implemented; the preview and generated model use the standard mean line.";
  return result;
 }
 const MAX_FILE_BYTES=2000000;
 function parseCoordinateFile(text,{filename="airfoil.dat"}={}){
  if(typeof text!=="string"||new TextEncoder().encode(text).length>MAX_FILE_BYTES)throw Error("Choose an airfoil coordinate text file no larger than 2 MB.");
  if(text.includes("\u0000"))throw Error("This is not a coordinate text file. Export a single airfoil as XFoil/Selig coordinates first.");
  filename=String(filename).split(/[\\/]/).at(-1)||"airfoil.dat";
  const numeric=/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eEdD][+-]?\d+)?$/,points=[];let name="",format="XFoil / Selig",domainHeader=false;
  for(const [index,line]of text.replace(/^\uFEFF/,"").replace(/\u001a/g,"").split(/\r?\n/).entries()){
   const clean=line.split("#",1)[0].trim();if(!clean||clean.startsWith("!"))continue;
   const words=clean.replace(/,/g," ").trim().split(/\s+/),numbers=words.map(word=>numeric.test(word)?Number(word.replace(/[dD]/,"e")):NaN),allFinite=numbers.every(Number.isFinite);
   if(words.length===2&&allFinite){if(numbers[0]===999&&numbers[1]===999)throw Error("Multiple-element MSES files are not supported. Export the desired single airfoil as a separate XFoil/Selig file; remove other elements, not just their separator.");points.push(numbers);}
   else if(!points.length&&name&&!domainHeader&&words.length>=4&&words.length<=16&&allFinite){domainHeader=true;format="ISES single-element";}
   else if(!points.length&&!name&&!words.every(word=>numeric.test(word)||/^[+-]?(?:NaN|Infinity)$/i.test(word)))name=clean;
   else throw Error("Invalid coordinate line "+(index+1)+": expected two finite numbers (x y).");
   if(points.length>40001)throw Error("Use no more than 40000 airfoil coordinates.");
  }
  let ordered=points;
  const counts=points[0];
  if(counts&&counts.every(v=>Number.isInteger(v)&&v>=3)&&counts[0]+counts[1]===points.length-1){
   const a=points.slice(1,1+counts[0]),b=points.slice(1+counts[0]);if(a[0][0]>a.at(-1)[0])a.reverse();if(b[0][0]>b.at(-1)[0])b.reverse();
   const scale=Math.max(Math.hypot(a.at(-1)[0]-a[0][0],a.at(-1)[1]-a[0][1]),Math.hypot(b.at(-1)[0]-b[0][0],b.at(-1)[1]-b[0][1]));
   if(!(scale>0)||Math.hypot(a[0][0]-b[0][0],a[0][1]-b[0][1])>1e-5*scale)throw Error("The two Lednicer surfaces do not meet at one leading edge.");ordered=[...a.reverse(),...b.slice(1)];format="Lednicer surface counts";
  }
  ordered=ordered.filter((point,i)=>!i||point[0]!==ordered[i-1][0]||point[1]!==ordered[i-1][1]);
  if(ordered.length<7||ordered.length>40000)throw Error("Expected 7 to 40000 coordinates around one airfoil, from trailing edge through leading edge to trailing edge.");
  const te=[(ordered[0][0]+ordered.at(-1)[0])/2,(ordered[0][1]+ordered.at(-1)[1])/2];let nose=0;
  for(let i=1;i<ordered.length;i++)if(Math.hypot(ordered[i][0]-te[0],ordered[i][1]-te[1])>Math.hypot(ordered[nose][0]-te[0],ordered[nose][1]-te[1]))nose=i;
  if(nose<2||nose>ordered.length-3)throw Error("Coordinates must trace a single airfoil from trailing edge to leading edge and back, in either direction. For Lednicer files, check the two surface counts.");
  const le=ordered[nose],dx=te[0]-le[0],dz=te[1]-le[1],chord=Math.hypot(dx,dz);
  if(!(chord>1e-10)||!Number.isFinite(chord))throw Error("The airfoil has a zero or invalid chord.");
  const normalized=ordered.map(p=>{const x=(p[0]-le[0])/chord,z=(p[1]-le[1])/chord;return[x*dx/chord+z*dz/chord,-x*dz/chord+z*dx/chord];});
  function surface(values){
   const first=values[0],last=values.at(-1);if(Math.abs(first[0])>=1e-8||Math.abs(last[0]-1)>=.01)throw Error("Each airfoil surface must span the whole chord. Check coordinate ordering and the trailing-edge endpoints.");
   first[0]=0;first[1]=0;last[0]=1;const kept=[];
   for(const point of values){const previous=kept.at(-1);if(previous&&Math.abs(point[0]-previous[0])<1e-10&&Math.abs(point[1]-previous[1])<1e-10)continue;if(previous&&point[0]<=previous[0])throw Error("Overhanging or multiple-element surfaces cannot be represented as one height at each x/c. Export a single monotone airfoil surface.");kept.push(point);}
   if(kept.length<3||kept.length>20000)throw Error("Each surface needs 3 to 20000 distinct coordinates.");return{x:kept.map(p=>p[0]),z:kept.map(p=>p[1])};
  }
  let upper=surface(normalized.slice(0,nose+1).reverse()),lower=surface(normalized.slice(nose));
  if(tableOrdinate(upper.x,upper.z,.5)<tableOrdinate(lower.x,lower.z,.5))[upper,lower]=[lower,upper];
  const profile={version:1,id:filename,filename,name:name||filename,source_kind:"file",source:"Local airfoil coordinate file",format,normalization:"Unit chord from the sampled leading edge to the trailing-edge midpoint; TE x/c aligned to 1, original gap retained.",xu:upper.x,zu:upper.z,xl:lower.x,zl:lower.z};
  const metrics=profileMetrics(profile);if(!(metrics.maxThickness.value>1e-8))throw Error("The airfoil has zero thickness.");profile.thickness_ratio=metrics.maxThickness.value;return profile;
 }
 async function readCoordinateFile(file){
  if(!file||typeof file.arrayBuffer!=="function")throw Error("Choose an airfoil coordinate file.");if(file.size>MAX_FILE_BYTES)throw Error("Choose an airfoil coordinate text file no larger than 2 MB.");
  const buffer=await file.arrayBuffer();if(buffer.byteLength>MAX_FILE_BYTES)throw Error("Choose an airfoil coordinate text file no larger than 2 MB.");let text;try{text=new TextDecoder("utf-8",{fatal:true}).decode(buffer);}catch(_){throw Error("The coordinate file is not UTF-8 text. Save a text copy in UTF-8, then select it again.");}
  const profile=parseCoordinateFile(text,{filename:file.name});if(!globalThis.crypto?.subtle)throw Error("This browser cannot verify local file provenance. Open Boxer at its localhost address in a current browser.");
  profile.raw_sha256=Array.from(new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256",buffer)),b=>b.toString(16).padStart(2,"0")).join("");profile.imported_at=new Date().toISOString();return profile;
 }
 function fileProfileReady(profile){return profile?.source_kind==="file"&&profile.version===1&&typeof profile.filename==="string"&&profile.filename.length>0&&/^[a-f0-9]{64}$/.test(profile.raw_sha256)&&typeof profile.imported_at==="string";}
 function embeddedSource(profile){return profile?(Object.hasOwn(profile,"source_kind")?profile.source_kind:"uiuc"):null;}
 function profileReady(profile,source){return source==="file"?fileProfileReady(profile):source==="uiuc"&&embeddedSource(profile)==="uiuc";}
 const sourcePage="https://m-selig.ae.illinois.edu/ads/coord_database.html";
 async function read(url){const activity=globalThis.WingActivity,token=activity?.begin("Loading airfoil data",{detail:url.includes("profile")?"Reading selected coordinates…":"Reading the UIUC catalogue…"});try{const response=await fetch(url,{cache:"no-store"});const data=await response.json();if(!response.ok||data.ok===false)throw Error(data.error||"Could not load airfoil data");return data;}finally{activity?.end(token);}}
 async function list(refresh=false){
  if(catalogue&&!refresh)return catalogue;
  if(pending&&!refresh)return pending;
  const version=++catalogueVersion;
  const current=read("/api/airfoils"+(refresh?"?refresh=true":"")).then(data=>{if(version===catalogueVersion)catalogue=data;return data;}).finally(()=>{if(pending===current)pending=null;});
  pending=current;return current;
 }
 function element(tag,cls,text){const el=document.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;}
 function parsed(input){try{const profile=JSON.parse(input?.value||"");return profile&&["xu","zu","xl","zl"].every(key=>Array.isArray(profile[key])&&profile[key].length>=3&&profile[key].length<=20000&&profile[key].every(Number.isFinite))&&profile.xu.length===profile.zu.length&&profile.xl.length===profile.zl.length?profile:null;}catch(_){return null;}}
 function selectionMessage(doc=document){
  const custom=doc.querySelector(".airfoil-stations-editor")?.dataset.invalidMessage;if(custom)return custom;
  for(const station of ["root","tip"]){const card=doc.getElementById("airfoil-"+station+"-card");if(card?.dataset.invalidMessage)return card.dataset.invalidMessage;}
  const missing=["root","tip"].filter(station=>{const source=doc.getElementById("p-airfoil."+station+"_source")?.value,profile=parsed(doc.getElementById("p-airfoil."+station+"_profile"));return ["uiuc","file"].includes(source)&&!profileReady(profile,source);});
  if(!missing.length)return "";
  const loading=missing.filter(station=>doc.getElementById("airfoil-"+station+"-card")?.dataset.profileState==="loading-profile");
  if(loading.length)return "Loading the selected "+loading.join(" and ")+" airfoil coordinates. FEM generation resumes when selection completes.";
  return "Select the "+missing.join(" and ")+" airfoil coordinates in Airfoils: choose a local coordinate file or a UIUC profile.";
 }
 // The solver interpolates each surface linearly at fixed x/c. Differences
 // and averages are therefore piecewise linear on the UNION of their knots;
 // checking those knots finds their exact extrema, without a NACA assumption.
 function tableOrdinate(xs,zs,x){
  if(x<=xs[0])return zs[0];if(x>=xs.at(-1))return zs.at(-1);
  let lo=0,hi=xs.length-1;while(hi-lo>1){const mid=(lo+hi)>>1;if(xs[mid]<=x)lo=mid;else hi=mid;}
  const t=(x-xs[lo])/(xs[hi]-xs[lo]);return (1-t)*zs[lo]+t*zs[hi];
 }
 function profileMetrics(profile){
  for(const [xkey,zkey]of[["xu","zu"],["xl","zl"]]){
   const x=profile[xkey],z=profile[zkey];
   if(!Array.isArray(x)||!Array.isArray(z)||x.length<3||x.length!==z.length||!x.every(Number.isFinite)||!z.every(Number.isFinite)||x.some((v,i)=>i&&v<=x[i-1])||Math.abs(x[0])>1e-10||Math.abs(x.at(-1)-1)>1e-10)throw Error("The preview needs finite, increasing unit-chord surface coordinates from x/c = 0 to 1.");
  }
  const xs=[...new Set([...profile.xu,...profile.xl])].sort((a,b)=>a-b),upper=xs.map(x=>tableOrdinate(profile.xu,profile.zu,x)),lower=xs.map(x=>tableOrdinate(profile.xl,profile.zl,x)),thickness=upper.map((z,i)=>z-lower[i]),camber=upper.map((z,i)=>(z+lower[i])/2),tol=1e-12;
  if(Math.min(...thickness)<-1e-8)throw Error("Upper and lower airfoil surfaces cross.");
  function extrema(values,absolute=false){
   const scores=absolute?values.map(Math.abs):values,value=Math.max(...scores),locations=[];
   for(let i=0;i<xs.length;i++)if(Math.abs(scores[i]-value)<=tol){
    const last=locations.at(-1);if(last&&last.lastIndex===i-1&&Math.abs(values[i]-values[i-1])<=tol){last.end=xs[i];last.lastIndex=i;}else locations.push({start:xs[i],end:xs[i],lastIndex:i});
   }
   const index=scores.findIndex(v=>Math.abs(v-value)<=tol);
   return {value,signedValue:values[index],x:xs[index],locations:locations.map(({start,end})=>({start,end})),zero:value<=tol};
  }
  return {xs,upper,lower,thickness,camber,maxThickness:extrema(thickness),maxCamber:extrema(camber,true)};
 }
 const interpolationHelp="Between adjacent stations eta_i and eta_j, t=(eta−eta_i)/(eta_j−eta_i). At fixed x/c, blend upper and lower z/c separately: z=(1−w)z_i+w z_j. Linear: w=t. Cosine: w=(1−cos(pi*t))/2. Both reproduce the station profiles. Cosine has zero blend slope at each station; Linear has constant blend rate within an interval and can change slope at a station. Chord, twist and planform transformations follow the section blend.";
 const measurementHelp="Measurements use the plotted surface tables, linearly interpolated at a common x/c. Thickness t/c=z_upper/c−z_lower/c is perpendicular to the chord; the midcamber line is m/c=(z_upper/c+z_lower/c)/2. Maximum camber is the largest absolute chordwise midline ordinate, reported with its sign. Extrema are exact for these sampled, piecewise-linear tables, not an analytic fit or thickness normal to the curved midline. UIUC coordinates use the sampled leading edge to trailing-edge midpoint as unit chord; NACA uses its generating unit chord.";
 function locationLabel(extremum){
  if(extremum.zero)return "all x/c (zero throughout)";
  const fmt=x=>x.toFixed(4),parts=extremum.locations.map(p=>p.start===p.end?fmt(p.start):fmt(p.start)+"–"+fmt(p.end));
  return parts.length>3?parts.slice(0,3).join(", ")+" … ("+parts.length+" tied locations)":parts.join(", ");
 }
 function plot(profile){
  const metrics=profileMetrics(profile),svg=document.createElementNS("http://www.w3.org/2000/svg","svg"),blue="#79c2eb",green="#a4deb0",muted="#8fa7b9",t=metrics.maxThickness,m=metrics.maxCamber;
  const yMin=-Math.max(...metrics.upper,...metrics.lower),yMax=-Math.min(...metrics.upper,...metrics.lower),top=yMin-.155,bottom=yMax+.215;
  svg.setAttribute("viewBox",[-.06,top,1.12,bottom-top].join(" "));svg.setAttribute("role","img");svg.setAttribute("class","airfoil-section-plot");svg.setAttribute("aria-label",(profile.name||profile.id||"Airfoil")+"; maximum thickness "+(100*t.value).toFixed(2)+"% of chord at x/c "+locationLabel(t)+"; maximum absolute camber "+(100*m.signedValue).toFixed(2)+"% of chord at "+locationLabel(m));
  function node(tag,attrs={},text){const el=document.createElementNS(svg.namespaceURI,tag);for(const[k,v]of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;svg.append(el);return el;}
  node("title",{},(profile.name||profile.id||"Airfoil")+" — sampled section dimensions");node("desc",{},measurementHelp);
  const path=(points,attrs)=>node("path",{d:points.map(([x,y],i)=>(i?"L":"M")+x+","+y).join(" "),fill:"none","stroke-width":1.2,"vector-effect":"non-scaling-stroke",...attrs});
  const line=(x1,y1,x2,y2,color,cls,dashed=false)=>node("line",{x1,y1,x2,y2,stroke:color,"stroke-width":1,"vector-effect":"non-scaling-stroke",class:cls,...(dashed?{"stroke-dasharray":"3 3"}:{})});
  const label=(x,y,text,color,cls,anchor="start")=>node("text",{x,y,fill:color,"font-size":.031,"font-family":"system-ui, sans-serif","text-anchor":anchor,class:cls,"data-snap-ignore":"true"},text);
  const points=[...profile.xu.map((x,i)=>[x,-profile.zu[i]]).reverse(),...profile.xl.map((x,i)=>[x,-profile.zl[i]])];
  const outline=path(points,{class:"airfoil-outline",stroke:blue,fill:"#79c2eb22"});outline.setAttribute("d",outline.getAttribute("d")+" Z");
  line(0,0,1,0,muted,"airfoil-chord",true);
  path(metrics.xs.map((x,i)=>[x,-metrics.camber[i]]),{class:"airfoil-midcamber",stroke:green,"stroke-dasharray":"5 3"});
  function vertical(x,ya,yb,color,cls){line(x,ya,x,yb,color,cls);for(const y of[ya,yb])line(x-.012,y,x+.012,y,color,cls);}
  vertical(t.x,-tableOrdinate(profile.xu,profile.zu,t.x),-tableOrdinate(profile.xl,profile.zl,t.x),blue,"airfoil-thickness-dimension");
  if(!m.zero)vertical(m.x,0,-m.signedValue,green,"airfoil-camber-dimension");
  label(.0,yMin-.102,"Max thickness t/c = "+(100*t.value).toFixed(2)+"%",blue,"airfoil-thickness-label");
  const oppositeTies=!m.zero&&metrics.camber.some(v=>Math.abs(v+m.signedValue)<=1e-12);
  label(.0,yMin-.047,m.zero?"Midcamber m/c = 0 (symmetric section)":oppositeTies?"Max |m|/c = "+(100*m.value).toFixed(2)+"% (±)":"Max camber m/c = "+(m.signedValue<0?"−":"+")+(100*m.value).toFixed(2)+"%",green,"airfoil-camber-label");
  function stationDimension(extremum,y,color,cls,symbol){
   if(!extremum.zero){line(0,y,extremum.x,y,color,cls);for(const x of[0,extremum.x])line(x,y-.009,x,y+.009,color,cls);line(extremum.x,yMax+.01,extremum.x,y,color,cls,true);}
   label(.0,y+.044,symbol+" = "+locationLabel(extremum),color,cls+"-label");
  }
  stationDimension(t,yMax+.048,blue,"airfoil-thickness-station","x_t/c");stationDimension(m,yMax+.132,green,"airfoil-camber-station","x_m/c");
  svg.airfoilMetrics=metrics;return svg;
 }
 function install(host,{onEdit,onHelp,onViewChange,isLocked=()=>false}={}){
  if(host.__wingAirfoils)return host.__wingAirfoils;
  const doc=host.ownerDocument,allCards=[],rows=[],listeners=new Set();let destroyed=false,serial=0,stationEditor=null,stationList=null,stationError=null;
  const storedStations=doc.getElementById("p-"+STATIONS_KEY),nInput=doc.getElementById("p-airfoil.n_points"),closedInput=doc.getElementById("p-airfoil.closed_trailing_edge");
  const listen=(target,type,fn,options)=>{target?.addEventListener(type,fn,options);const remove=()=>{target?.removeEventListener(type,fn,options);listeners.delete(remove);};listeners.add(remove);return remove;};
  const nacaOptions=()=>({n:nInput?Number(nInput.value):121,closed:closedInput?closedInput.checked:true});
  const intro=element("p","group-note","Define root, tip and optional intermediate sections using NACA codes, the UIUC database or local XFoil coordinate files. Each section is drawn immediately. Embedded coordinates are saved with the study and work offline.");
  host.insertBefore(intro,host.children[1]||null);const help=element("button","mini","?");help.type="button";help.title="Define root, tip and intermediate sections with NACA codes, UIUC coordinates or local XFoil coordinate files. Spanwise interpolation blends the upper and lower ordinates separately between stations. Click for interpolation equations, profile measurements and offline storage details.";help.setAttribute("aria-label","Help: airfoil sources");intro.append(" ",help);
  const interpolation=doc.getElementById("row-airfoil.interpolation");if(interpolation){intro.insertAdjacentElement("afterend",interpolation);const select=interpolation.querySelector("select");if(select){select.title=interpolationHelp;for(const option of select.options)option.title=option.value==="cosine"?"w=(1−cos(pi*t))/2; zero blend slope at both section stations.":"w=t; constant blend slope within each station interval.";}}
  help.onclick=()=>onHelp?.({title:"Airfoil sources and dimensions",paragraphs:["Root and tip define eta 0 and 1. Add intermediate sections at distinct eta values strictly between 0 and 1. Each may use a NACA 4/5 digit code, UIUC coordinates or a local XFoil coordinate file. Valid rows are saved in eta order.",interpolationHelp,measurementHelp,"NACA previews use the same thickness-normal-to-camber construction, cosine point spacing and monotone surface tables as the generator. The measured chordwise thickness may differ slightly from the nominal thickness in the NACA code. Section points and Closed trailing edge apply only to NACA profiles. The preview updates while typing, before any mesh is built.","Switching to UIUC opens the chooser if no coordinates are embedded. Search by filename or select a profile to preview its section immediately. Use selected profile applies it; Cancel selection (or Escape) restores the original source and airfoil. Previewing does not replace the embedded coordinates. Browse reopens the chooser to change an existing selection. Saved coordinates include their source provenance and need no network when reopened. Local files use the normal file chooser and may be plain or labelled XFoil/Selig, Lednicer, or single-element ISES. Each surface must be a single-valued height over the chord. MSES multi-element files must first be exported as one selected airfoil. Original filename and SHA-256 are saved; a malformed replacement leaves the previous embedded profile unchanged.","Drawing navigation, background images and SVG export work independently for each section. Image alignment stays with its section when eta is edited or another section is removed.",sourcePage]});
  function updateNacaOptions(){const allEmbedded=allCards.length&&allCards.every(c=>c.source.value!=="naca");for(const key of["n_points","closed_trailing_edge"]){const row=doc.getElementById("row-airfoil."+key);if(row)row.hidden=allEmbedded;}}
  function createCard({station,label,source,stored,code,sourceRow,codeRow,storedRow,change,header}){
   const card=element("fieldset","airfoil-source-editor"),legend=element("legend","",label);card.id="airfoil-"+station+"-card";card.append(legend);if(header)card.append(header);
   if(sourceRow)card.append(sourceRow);if(codeRow)card.append(codeRow);if(storedRow){storedRow.hidden=true;card.append(storedRow);}
   if(!Array.from(source.options).some(option=>option.value==="file")){const option=element("option","","Local XFoil / coordinate file");option.value="file";source.append(option);}for(const option of source.options)option.textContent=option.value==="naca"?"NACA 4 / 5 digit":option.value==="file"?"Local XFoil / coordinate file":"UIUC database";
   const selected=element("div","airfoil-selected"),database=element("div","airfoil-database"),browse=element("button","mini","Browse UIUC profiles"),panel=element("div","airfoil-browser");browse.type="button";browse.id="airfoil-"+station+"-browse";panel.hidden=true;
   const search=element("input"),choices=element("select"),use=element("button","mini airfoil-use-profile","Use selected profile"),cancel=element("button","mini ghost","Cancel selection"),candidateView=element("div","airfoil-candidate"),refresh=element("button","mini ghost","Refresh catalogue"),status=element("p","pick-note");
   search.type="search";search.placeholder="Search e.g. clarky or s1223";search.id="airfoil-"+station+"-search";search.setAttribute("aria-label","Search UIUC "+label+" profiles");
   choices.size=6;choices.id="airfoil-"+station+"-choices";choices.setAttribute("aria-label","UIUC "+label+" profile");use.type=cancel.type=refresh.type="button";cancel.id="airfoil-"+station+"-cancel";candidateView.hidden=true;use.id="airfoil-"+station+"-use";use.disabled=true;status.setAttribute("role","status");
   panel.append(search,choices,candidateView,use,cancel,refresh,status);database.append(browse,panel);
   const local=element("div","airfoil-local-file"),file=element("input"),fileLabel=element("label","","Choose airfoil coordinate file"),fileStatus=element("p","pick-note"),fileError=element("p","airfoil-preview-error");file.type="file";file.accept=".dat,.txt,.xy,.foil,.csv,text/plain";file.id="airfoil-"+station+"-file";file.setAttribute("aria-label",label+" coordinate file");fileLabel.htmlFor=file.id;fileLabel.append(file);fileStatus.setAttribute("role","status");fileError.setAttribute("role","alert");fileError.hidden=true;local.append(fileLabel,element("p","pick-note","Single-element XFoil/Selig, labelled or plain coordinates, Lednicer surface counts, or ISES. Files are normalized to unit chord and embedded in the study."),fileStatus,fileError);card.append(selected,database,local);
   let request=0,catalogueRequest=0,items=[],loadingCatalogue=false,loadingProfile=false,viewport=null,savedView=null,previewKey="airfoil-"+station,previewSignature=null,alive=true,candidate=null,selectionOrigin=null,lastSource=source.value,restoringSource=false;
   const sourceProfiles=new Map();let savedNacaCode=code.value;
   try{nacaProfile(savedNacaCode,nacaOptions());}catch(_){savedNacaCode="";}
   // A source selector is a change of definition, not a relabelling of the
   // old coordinates. Keep source-specific choices for a reversible switch,
   // but serialize only the profile belonging to the active source.
   function rememberProfile(){const profile=parsed(stored),kind=embeddedSource(profile);if(profileReady(profile,kind))sourceProfiles.set(kind,stored.value);}
   function selectSourceProfile(){rememberProfile();stored.value=sourceProfiles.get(source.value)||"";if(source.value==="naca")code.value=savedNacaCode;fileError.hidden=true;fileStatus.textContent="";}
   rememberProfile();
   const controls=()=>{const locked=isLocked();use.disabled=locked||loadingCatalogue||loadingProfile||!candidate||candidate.profile.id!==choices.value;cancel.disabled=locked;for(const node of[source,code,browse,refresh,search,choices,file])node.disabled=locked;};
   const state=value=>{card.dataset.profileState=value;};
   function describe(force=false){
    const signature=source.value+"|"+code.value+"|"+nInput?.value+"|"+closedInput?.checked+"|"+stored.value;
    if(!force&&signature===previewSignature)return;previewSignature=signature;
    let profile,error="";try{profile=source.value==="naca"?nacaProfile(code.value,nacaOptions()):parsed(stored);if(source.value==="file"&&!profileReady(profile,"file"))error="Choose a local coordinate file for "+label.toLowerCase()+".";else if(source.value==="uiuc"&&!profileReady(profile,"uiuc"))error="Select a UIUC "+label.toLowerCase()+" airfoil: search the catalogue and click Use selected profile.";else profileMetrics(profile);}catch(e){error=label+": "+e.message;}
    card.dataset.invalidMessage=error;
    if(viewport){savedView=viewport.capture();viewport.destroy();viewport=null;}selected.replaceChildren();
    if(error){selected.append(element("p","airfoil-preview-error",error));return;}
    selected.append(element("strong","",profile.name||profile.id));
    selected.append(element("p","pick-note",(profile.id||profile.name)+" | "+(profile.xu.length+profile.xl.length-1)+" points | unit chord"));
    const canvas=element("div","airfoil-preview-canvas"),svg=plot(profile);svg.dataset.viewKey=previewKey;canvas.append(svg);selected.append(canvas);
    viewport=globalThis.WingSVGViewport?.install(svg,{host:canvas,snapSelector:"path",title:label,exportName:previewKey+".svg",onChange:onViewChange});viewport?.setMetric?.({origin:{x:0,y:0},x:{x:1,y:0},y:{x:0,y:-1},unit:"c",gridSpacing:.1});if(savedView)viewport?.restore(savedView);
    if(profile.warning)selected.append(element("p","airfoil-preview-warning",profile.warning));
    if(source.value==="uiuc"){
     const link=element("a","","UIUC coordinate source");if(String(profile.source_url).startsWith("https://m-selig.ae.illinois.edu/ads/"))link.href=profile.source_url;link.target="_blank";link.rel="noopener noreferrer";selected.append(link);
     const details=element("details"),summary=element("summary","","Saved source details"),text=element("p","pick-note","Downloaded "+profile.fetched_at+" | SHA-256 "+profile.raw_sha256+". "+profile.normalization);details.append(summary,text);selected.append(details);
    }
    if(source.value==="file"){const details=element("details"),summary=element("summary","","Embedded file details"),text=element("p","pick-note",profile.filename+" | "+profile.format+" | imported "+profile.imported_at+" | SHA-256 "+profile.raw_sha256+". "+profile.normalization+" Coordinates are stored in the study; the original file is not required when reopening it.");details.append(summary,text);selected.append(details);}
   }
   function snapshotSelection(){return{source:source.value,code:code.value,stored:stored.value};}
   function clearCandidate(){candidate=null;candidateView.replaceChildren();candidateView.hidden=true;selected.hidden=false;}
   function cancelSelection(){
    const original=selectionOrigin;selectionOrigin=null;setOpen(false);
    if(original&&(source.value!==original.source||code.value!==original.code||stored.value!==original.stored)){
     source.value=original.source;code.value=original.code;stored.value=original.stored;lastSource=source.value;if(source.value==="naca")savedNacaCode=code.value;rememberProfile();update(true);
     restoringSource=true;try{source.dispatchEvent(new Event("change",{bubbles:true}));}finally{restoringSource=false;}change("source");
    }else describe(true);
   }
   function setOpen(open){if(!open){request++;loadingProfile=false;clearCandidate();}else if(!selectionOrigin)selectionOrigin=snapshotSelection();panel.hidden=!open;browse.textContent=open?"Close browser":"Browse UIUC profiles";browse.setAttribute("aria-expanded",String(open));controls();}
   function update(sourceChanged=false){
    request++;loadingProfile=false;clearCandidate();if(sourceChanged){catalogueRequest++;loadingCatalogue=false;}
    const uiuc=source.value==="uiuc",fromFile=source.value==="file",profile=parsed(stored),ready=profileReady(profile,source.value);database.hidden=!uiuc;local.hidden=!fromFile;if(codeRow)codeRow.hidden=source.value!=="naca";state(source.value==="naca"?"naca":ready?"ready":"needs-selection");describe();updateNacaOptions();controls();
    if(uiuc&&!loadingCatalogue)status.textContent=ready?"Using embedded "+profile.id+". Choose another profile and click Use selected profile to change it.":"Select a profile and click Use selected profile.";
    if(uiuc&&!ready&&!isLocked()){setOpen(true);if(!items.length&&!loadingCatalogue)loadCatalogue(false);else if(items.length)previewCandidate();}
   }
   async function previewCandidate(){
    if(isLocked()||!choices.value||source.value!=="uiuc"||panel.hidden)return;
    const current=++request,id=choices.value;clearCandidate();loadingProfile=true;controls();status.textContent="Loading preview for "+id+"... The current airfoil is unchanged.";
    try{const data=await read("/api/airfoils/profile?id="+encodeURIComponent(id));if(current!==request||!alive||!host.isConnected||source.value!=="uiuc"||isLocked()||choices.value!==id||panel.hidden)return;
     const encoded=JSON.stringify(data.profile),profile=parsed({value:encoded});if(!profileReady(profile,"uiuc")||profile.id!==id)throw Error("The downloaded coordinates do not match the selected profile.");profileMetrics(profile);
     candidate={profile,encoded,cached:data.cached===true};candidateView.append(element("strong","","Preview: "+(profile.name||id)),element("p","pick-note","Not applied. Use selected profile replaces the current section; Cancel selection keeps the original airfoil."),plot(profile));candidateView.hidden=false;selected.hidden=true;
     status.textContent="Preview ready for "+id+". The model changes only when you click Use selected profile.";
    }catch(error){if(current===request&&alive&&host.isConnected&&source.value==="uiuc"){clearCandidate();status.textContent=error.message+" Select a profile again to retry, or cancel to keep the original airfoil.";}}
    finally{if(current===request){loadingProfile=false;controls();}}
   }
   function filter(){request++;loadingProfile=false;clearCandidate();const query=search.value.trim().toLowerCase(),matches=items.filter(item=>(item.id+" "+item.label).toLowerCase().includes(query));choices.replaceChildren();for(const item of matches.slice(0,200)){const option=element("option","",item.label);option.value=item.id;choices.append(option);}if(choices.options.length)choices.selectedIndex=0;controls();state(profileReady(parsed(stored),source.value)?"ready":"needs-selection");status.textContent=matches.length?matches.length+" profiles"+(matches.length>200?"; showing first 200, refine the search":"")+". Select one to preview it.":"No matching profiles. Try another name.";if(matches.length)previewCandidate();}
   async function loadCatalogue(force){
    const current=++catalogueRequest;request++;loadingProfile=false;clearCandidate();loadingCatalogue=true;status.textContent="Loading UIUC catalogue...";state("loading-catalogue");controls();
    try{const data=await list(force);if(current!==catalogueRequest||!alive||!host.isConnected||source.value!=="uiuc")return;if(!Array.isArray(data.items))throw Error("The UIUC catalogue did not contain a profile list.");items=data.items;loadingCatalogue=false;filter();}
    catch(error){if(current===catalogueRequest&&alive&&host.isConnected&&source.value==="uiuc"){status.textContent=error.message+" Try Refresh catalogue to retry.";state("error");}}
    finally{if(current===catalogueRequest){loadingCatalogue=false;controls();}}
   }
   browse.onclick=()=>{if(isLocked())return;if(!panel.hidden){cancelSelection();return;}setOpen(true);loadCatalogue(false);search.focus();};refresh.onclick=()=>{if(!isLocked())loadCatalogue(true);};search.oninput=filter;choices.onchange=previewCandidate;cancel.onclick=()=>{if(!isLocked())cancelSelection();};listen(panel,"keydown",event=>{if(event.key==="Escape"&&!isLocked()){event.preventDefault();event.stopPropagation();cancelSelection();}});
   use.onclick=()=>{
    if(isLocked()||!candidate||loadingCatalogue||loadingProfile||candidate.profile.id!==choices.value||source.value!=="uiuc")return;
    stored.value=candidate.encoded;rememberProfile();selectionOrigin=null;setOpen(false);state("ready");describe(true);status.textContent="Profile selected and embedded. Save the Study or TOML to keep it.";change("profile");
   };
   file.onchange=async()=>{const selectedFile=file.files?.[0];file.value="";if(!selectedFile||isLocked())return;const current=++request;loadingProfile=true;fileError.hidden=true;fileStatus.textContent="Reading "+selectedFile.name+"…";controls();try{const profile=await readCoordinateFile(selectedFile);if(current!==request||!alive||!host.isConnected||source.value!=="file"||isLocked())return;stored.value=JSON.stringify(profile);update();fileStatus.textContent="Embedded "+profile.filename+". Save the study to retain its coordinates offline.";change("profile");}catch(error){if(current===request&&alive&&host.isConnected){fileError.textContent=error.message+" The previous embedded profile has not been changed.";fileError.hidden=false;fileStatus.textContent="File not loaded.";}}finally{if(current===request){loadingProfile=false;controls();}}};
   const cardListeners=[listen(source,"change",()=>{if(restoringSource)return;if(source.value==="uiuc"&&lastSource!=="uiuc")selectionOrigin={source:lastSource,code:code.value,stored:stored.value};else if(source.value!=="uiuc")selectionOrigin=null;lastSource=source.value;selectSourceProfile();update(true);change("source");},true),listen(code,"input",()=>{if(source.value==="naca")savedNacaCode=code.value;describe();change("code");})];
   const api={card,source,code,stored,describe,update,registryEntry(key){return{controller:viewport,from:previewKey,key,...(!viewport&&savedView?{state:savedView}:{})};},setKey(key){previewKey=key;const svg=selected.querySelector("svg");if(svg)svg.dataset.viewKey=key;},destroy({forget=false}={}){alive=false;request++;catalogueRequest++;for(const remove of cardListeners)remove();if(viewport)viewport.destroy({forget});else if(forget)globalThis.WingSVGViewport?.forget(previewKey);savedView=null;card.remove();}};allCards.push(api);return api;
  }
  for(const station of["root","tip"]){
   const prefix="airfoil."+station,source=doc.getElementById("p-"+prefix+"_source"),stored=doc.getElementById("p-"+prefix+"_profile"),code=doc.getElementById("p-"+prefix);if(!source||!stored||!code)continue;
   const sourceRow=doc.getElementById("row-"+prefix+"_source"),codeRow=doc.getElementById("row-"+prefix),storedRow=doc.getElementById("row-"+prefix+"_profile"),anchor=doc.createComment(station+" profile");host.insertBefore(anchor,sourceRow);
   const card=createCard({station,label:station==="root"?"Root profile (eta 0)":"Tip profile (eta 1)",source,stored,code,sourceRow,codeRow,storedRow,change:kind=>{if(kind==="profile")onEdit?.(prefix+"_profile");}});host.insertBefore(card.card,anchor);anchor.remove();
  }
  function sortedRows(){return [...rows].sort((a,b)=>{const av=a.eta.value.trim()===""?NaN:Number(a.eta.value),bv=b.eta.value.trim()===""?NaN:Number(b.eta.value);return Number.isFinite(av)&&Number.isFinite(bv)?av-bv:a.uid-b.uid;});}
  function drafts(){return sortedRows().map(row=>{const eta=row.eta.value.trim()===""?NaN:Number(row.eta.value),source=row.card.source.value,profile=parsed(row.card.stored);return{eta:Number.isFinite(eta)?eta:null,source,code:source==="naca"?row.card.code.value:(profile?.id||row.card.code.value),...(["uiuc","file"].includes(source)?{profile}:{} )};});}
  function validate(){
   const values=drafts();let error="";if(values.length>MAX_STATIONS)error="Use no more than "+MAX_STATIONS+" intermediate sections.";
   for(let i=0;!error&&i<values.length;i++){const row=values[i];if(!(row.eta>0&&row.eta<1))error="Intermediate airfoil eta must be greater than 0 and less than 1; root and tip are already defined.";else if(i&&Math.abs(row.eta-values[i-1].eta)<1e-8)error="Intermediate airfoils need distinct eta positions (at least 1e-8 apart).";else if(row.source==="file"&&!fileProfileReady(row.profile))error="Choose a local coordinate file for the intermediate airfoil at eta "+row.eta+".";else if(row.source==="uiuc"&&!profileReady(row.profile,"uiuc"))error="Select a UIUC intermediate airfoil at eta "+row.eta+": search the catalogue and click Use selected profile.";else try{row.source==="naca"?nacaProfile(row.code,nacaOptions()):profileMetrics(row.profile);}catch(e){error="Airfoil at eta "+row.eta+": "+e.message;}}
   if(stationEditor)stationEditor.dataset.invalidMessage=error;if(stationError){stationError.textContent=error;stationError.hidden=!error;}
   const ordered=sortedRows(),keys=ordered.map((row,i)=>row.card.registryEntry("airfoil-station-"+(i+1)));
   if(keys.some(entry=>entry.from!==entry.key))globalThis.WingSVGViewport?.rekeyAll(keys);
   ordered.forEach((row,i)=>{row.card.setKey("airfoil-station-"+(i+1));row.card.card.dataset.stationOrder=String(i+1);});return error;
  }
  function sync(notify=true){validate();if(storedStations)storedStations.value=JSON.stringify(drafts());updateNacaOptions();if(notify)onEdit?.(STATIONS_KEY);}
  function addStation(value,notify=true){
   if(rows.length>=MAX_STATIONS)return;const uid=++serial,station="station-"+uid,source=element("select"),code=element("input"),stored=element("input"),eta=element("input"),header=element("div","airfoil-station-header"),remove=element("button","mini ghost","Remove section");
   source.id="airfoil-"+station+"-source";for(const choice of["naca","uiuc","file"]){const option=element("option","",choice);option.value=choice;source.append(option);}source.value=value.source||"naca";code.id="airfoil-"+station+"-code";code.value=value.code||"NACA0012";stored.type="hidden";stored.value=value.profile?JSON.stringify(value.profile):"";
   eta.type="number";eta.min="0";eta.max="1";eta.step="0.1";eta.value=value.eta??"";eta.setAttribute("aria-label","Intermediate airfoil eta");eta.dataset.airfoilEta=String(uid);const etaLabel=element("label","","Eta ");etaLabel.append(eta);remove.type="button";remove.dataset.airfoilRemove=String(uid);header.append(etaLabel,remove);
   const sourceRow=element("label","row","Section source"),codeRow=element("label","row","NACA code");sourceRow.append(source);codeRow.append(code);
   const card=createCard({station,label:"Intermediate section",source,stored,code,sourceRow,codeRow,header,change:()=>sync()});card.card.append(stored);const row={uid,eta,remove,card};rows.push(row);stationList.append(card.card);
   const rowListeners=[listen(eta,"input",()=>{if(!isLocked())sync();}),listen(eta,"change",()=>{if(!validate())for(const entry of sortedRows())stationList.append(entry.card.card);})];remove.onclick=()=>{if(isLocked())return;for(const detach of rowListeners)detach();card.destroy({forget:true});rows.splice(rows.indexOf(row),1);allCards.splice(allCards.indexOf(card),1);sync();};card.update();sync(notify);
  }
  if(storedStations){
   const hidden=doc.getElementById("row-"+STATIONS_KEY);if(hidden)hidden.hidden=true;
   stationEditor=element("section","airfoil-stations-editor");stationEditor.id="airfoil-intermediate-sections";const heading=element("div","airfoil-stations-heading"),title=element("h3","","Intermediate sections"),add=element("button","mini","+ Add section");add.id="airfoil-add-station";add.type="button";heading.append(title,add);stationList=element("div","airfoil-station-list");stationError=element("p","airfoil-preview-error");stationError.setAttribute("role","alert");stationError.hidden=true;
   stationEditor.append(heading,element("p","pick-note","Place sections by eta (0 = root, 1 = tip). Use a NACA code, UIUC profile or local coordinate file for each section. Definitions are saved in span order."),stationError,stationList);
   const tip=doc.getElementById("airfoil-tip-card");host.insertBefore(stationEditor,tip||null);
   let initial=[];try{initial=JSON.parse(storedStations.value||"[]");if(!Array.isArray(initial))throw Error("array required");}catch(_){stationEditor.dataset.invalidMessage="Intermediate airfoils must be a valid section table.";}
   for(const value of initial)addStation(value,false);
   add.onclick=()=>{if(isLocked()||rows.length>=MAX_STATIONS)return;const etas=[0,...drafts().map(v=>v.eta).filter(v=>v>0&&v<1),1].sort((a,b)=>a-b);let best=0;for(let i=1;i<etas.length-1;i++)if(etas[i+1]-etas[i]>etas[best+1]-etas[best])best=i;addStation({eta:(etas[best]+etas[best+1])/2,source:"naca",code:doc.getElementById("p-airfoil.root")?.value||"NACA0012"});};
  }
  function refresh(){if(destroyed)return;for(const card of allCards)card.describe();validate();updateNacaOptions();}
  for(const input of[nInput,closedInput])listen(input,"input",refresh);
  listen(host,"parameterlockchange",()=>{for(const card of allCards)card.update();for(const row of rows){row.eta.disabled=isLocked();row.remove.disabled=isLocked();}if(stationEditor)stationEditor.querySelector("#airfoil-add-station").disabled=isLocked()||rows.length>=MAX_STATIONS;validate();});
  for(const card of allCards)card.update();validate();updateNacaOptions();
  const api={refresh,readDrafts:()=>({[STATIONS_KEY]:drafts()}),assertValidDraft(){const message=selectionMessage(doc);if(message)throw Error(message);},destroy(){destroyed=true;for(const remove of listeners)remove();for(const card of allCards)card.destroy();stationEditor?.remove();intro.remove();delete host.__wingAirfoils;}};host.__wingAirfoils=api;return api;
 }
 return{install,plot,profileMetrics,tableOrdinate,locationLabel,interpolationHelp,measurementHelp,selectionMessage,nacaProfile,parseCoordinateFile,readCoordinateFile,fileProfileReady,MAX_FILE_BYTES,STATIONS_KEY,MAX_STATIONS};
});
