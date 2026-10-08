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
  const missing=["root","tip"].filter(station=>doc.getElementById("p-airfoil."+station+"_source")?.value==="uiuc"&&!parsed(doc.getElementById("p-airfoil."+station+"_profile")));
  if(!missing.length)return "";
  const loading=missing.filter(station=>doc.getElementById("airfoil-"+station+"-card")?.dataset.profileState==="loading-profile");
  if(loading.length)return "Loading the selected UIUC "+loading.join(" and ")+" airfoil coordinates. FEM generation resumes when selection completes.";
  return "Select a UIUC "+missing.join(" and ")+" airfoil in Airfoils: search the catalogue and click Use selected profile.";
 }
 function plot(profile){
  const svg=document.createElementNS("http://www.w3.org/2000/svg","svg");svg.setAttribute("viewBox","-.03 -.22 1.06 .40");svg.setAttribute("role","img");svg.setAttribute("aria-label",profile.name+" normalized section profile");
  const path=document.createElementNS(svg.namespaceURI,"path"),points=[...profile.xu.map((x,i)=>[x,-profile.zu[i]]).reverse(),...profile.xl.map((x,i)=>[x,-profile.zl[i]])];
  path.setAttribute("d",points.map(([x,y],i)=>(i?"L":"M")+x+","+y).join(" ")+" Z");svg.appendChild(path);return svg;
 }
 function install(host,{onEdit,onHelp,onViewChange,isLocked=()=>false}={}){
  if(host.__wingAirfoils)return host.__wingAirfoils;
  const doc=host.ownerDocument,allCards=[],rows=[],listeners=new Set();let destroyed=false,serial=0,stationEditor=null,stationList=null,stationError=null;
  const storedStations=doc.getElementById("p-"+STATIONS_KEY),nInput=doc.getElementById("p-airfoil.n_points"),closedInput=doc.getElementById("p-airfoil.closed_trailing_edge");
  const listen=(target,type,fn)=>{target?.addEventListener(type,fn);const remove=()=>{target?.removeEventListener(type,fn);listeners.delete(remove);};listeners.add(remove);return remove;};
  const nacaOptions=()=>({n:nInput?Number(nInput.value):121,closed:closedInput?closedInput.checked:true});
  const intro=element("p","group-note","Define root, tip and optional intermediate sections. Each section is drawn immediately. Intermediate eta is the fraction of semi-span; the selected interpolation blends adjacent sections. Saved UIUC coordinates work offline.");
  host.insertBefore(intro,host.children[1]||null);const help=element("button","mini","?");help.type="button";help.title="Help: airfoil sources";help.setAttribute("aria-label",help.title);intro.append(" ",help);
  const interpolation=doc.getElementById("row-airfoil.interpolation");if(interpolation)intro.insertAdjacentElement("afterend",interpolation);
  help.onclick=()=>onHelp?.({title:"Airfoil sources",paragraphs:["Root and tip define eta 0 and 1. Add intermediate sections at distinct eta values strictly between 0 and 1. Each may use a NACA 4/5 digit code or embedded UIUC coordinates. Valid rows are saved in eta order.","Section interpolation applies separately between each adjacent pair of sections. Cosine varies the blend smoothly and flattens its slope at section stations; Linear retains a constant blend rate within each interval. Planform and twist are applied to the resulting section.","NACA previews use the same thickness-normal-to-camber construction, cosine point spacing and monotone surface tables as the generator. Section points and Closed trailing edge apply only to NACA profiles. The preview updates while typing, before any mesh is built.","Switching to UIUC opens the chooser if no coordinates are embedded. Search by filename, select a profile and press Use selected profile. Browse reopens the chooser to change an existing selection. Saved coordinates include their source provenance and need no network when reopened.","Drawing navigation, background images and SVG export work independently for each section. Image alignment stays with its section when eta is edited or another section is removed.",sourcePage]});
  function updateNacaOptions(){const allUiuc=allCards.length&&allCards.every(c=>c.source.value==="uiuc");for(const key of["n_points","closed_trailing_edge"]){const row=doc.getElementById("row-airfoil."+key);if(row)row.hidden=allUiuc;}}
  function createCard({station,label,source,stored,code,sourceRow,codeRow,storedRow,change,header}){
   const card=element("fieldset","airfoil-source-editor"),legend=element("legend","",label);card.id="airfoil-"+station+"-card";card.append(legend);if(header)card.append(header);
   if(sourceRow)card.append(sourceRow);if(codeRow)card.append(codeRow);if(storedRow){storedRow.hidden=true;card.append(storedRow);}
   for(const option of source.options)option.textContent=option.value==="naca"?"NACA 4 / 5 digit":"UIUC database";
   const selected=element("div","airfoil-selected"),database=element("div","airfoil-database"),browse=element("button","mini","Browse UIUC profiles"),panel=element("div","airfoil-browser");browse.type="button";browse.id="airfoil-"+station+"-browse";panel.hidden=true;
   const search=element("input"),choices=element("select"),use=element("button","mini","Use selected profile"),refresh=element("button","mini ghost","Refresh catalogue"),status=element("p","pick-note");
   search.type="search";search.placeholder="Search e.g. clarky or s1223";search.id="airfoil-"+station+"-search";search.setAttribute("aria-label","Search UIUC "+label+" profiles");
   choices.size=6;choices.id="airfoil-"+station+"-choices";choices.setAttribute("aria-label","UIUC "+label+" profile");use.type=refresh.type="button";use.id="airfoil-"+station+"-use";use.disabled=true;status.setAttribute("role","status");
   panel.append(search,choices,use,refresh,status);database.append(browse,panel);card.append(selected,database);
   let request=0,catalogueRequest=0,items=[],loadingCatalogue=false,loadingProfile=false,viewport=null,savedView=null,previewKey="airfoil-"+station,previewSignature=null,alive=true;
   const controls=()=>{const locked=isLocked();use.disabled=locked||loadingCatalogue||loadingProfile||!choices.value;for(const node of[source,code,browse,refresh,search,choices])node.disabled=locked;};
   const state=value=>{card.dataset.profileState=value;};
   function describe(force=false){
    const signature=source.value+"|"+code.value+"|"+nInput?.value+"|"+closedInput?.checked+"|"+stored.value;
    if(!force&&signature===previewSignature)return;previewSignature=signature;
    let profile,error="";try{profile=source.value==="naca"?nacaProfile(code.value,nacaOptions()):parsed(stored);if(!profile)error="Select a UIUC "+label.toLowerCase()+" airfoil: search the catalogue and click Use selected profile.";}catch(e){error=label+": "+e.message;}
    card.dataset.invalidMessage=error;
    if(viewport){savedView=viewport.capture();viewport.destroy();viewport=null;}selected.replaceChildren();
    if(error){selected.append(element("p","airfoil-preview-error",error));return;}
    selected.append(element("strong","",profile.name||profile.id));
    selected.append(element("p","pick-note",(profile.id||profile.name)+" | "+(profile.xu.length+profile.xl.length-1)+" points"+(Number.isFinite(profile.thickness_ratio)?" | "+(100*profile.thickness_ratio).toFixed(2)+"% thickness":"")));
    const canvas=element("div","airfoil-preview-canvas"),svg=plot(profile);svg.dataset.viewKey=previewKey;canvas.append(svg);selected.append(canvas);
    viewport=globalThis.WingSVGViewport?.install(svg,{host:canvas,snapSelector:"path",title:label,exportName:previewKey+".svg",onChange:onViewChange});viewport?.setMetric?.({origin:{x:0,y:0},x:{x:1,y:0},y:{x:0,y:-1},unit:"c",gridSpacing:.1});if(savedView)viewport?.restore(savedView);
    if(profile.warning)selected.append(element("p","airfoil-preview-warning",profile.warning));
    if(source.value==="uiuc"){
     const link=element("a","","UIUC coordinate source");if(String(profile.source_url).startsWith("https://m-selig.ae.illinois.edu/ads/"))link.href=profile.source_url;link.target="_blank";link.rel="noopener noreferrer";selected.append(link);
     const details=element("details"),summary=element("summary","","Saved source details"),text=element("p","pick-note","Downloaded "+profile.fetched_at+" | SHA-256 "+profile.raw_sha256+". "+profile.normalization);details.append(summary,text);selected.append(details);
    }
   }
   function setOpen(open){panel.hidden=!open;browse.textContent=open?"Close browser":"Browse UIUC profiles";browse.setAttribute("aria-expanded",String(open));}
   function update(sourceChanged=false){
    request++;loadingProfile=false;if(sourceChanged){catalogueRequest++;loadingCatalogue=false;}
    const uiuc=source.value==="uiuc";database.hidden=!uiuc;if(codeRow)codeRow.hidden=uiuc;state(uiuc?(parsed(stored)?"ready":"needs-selection"):"naca");describe();updateNacaOptions();controls();
    if(uiuc&&!loadingCatalogue){const profile=parsed(stored);status.textContent=profile?"Using embedded "+profile.id+". Choose another profile and click Use selected profile to change it.":"Select a profile and click Use selected profile.";}
    if(uiuc&&!parsed(stored)&&!isLocked()){setOpen(true);if(!items.length&&!loadingCatalogue)loadCatalogue(false);}
   }
   function filter(){request++;loadingProfile=false;const query=search.value.trim().toLowerCase(),matches=items.filter(item=>(item.id+" "+item.label).toLowerCase().includes(query));choices.replaceChildren();for(const item of matches.slice(0,200)){const option=element("option","",item.label);option.value=item.id;choices.append(option);}if(choices.options.length)choices.selectedIndex=0;controls();state(parsed(stored)?"ready":"needs-selection");status.textContent=matches.length?matches.length+" profiles"+(matches.length>200?"; showing first 200, refine the search":"")+". Select one, then click Use selected profile.":"No matching profiles. Try another name.";}
   async function loadCatalogue(force){
    const current=++catalogueRequest;request++;loadingProfile=false;loadingCatalogue=true;status.textContent="Loading UIUC catalogue...";state("loading-catalogue");controls();
    try{const data=await list(force);if(current!==catalogueRequest||!alive||!host.isConnected||source.value!=="uiuc")return;if(!Array.isArray(data.items))throw Error("The UIUC catalogue did not contain a profile list.");items=data.items;loadingCatalogue=false;filter();status.textContent+=" "+(data.warning||(data.cached?"Cached catalogue.":"Downloaded from UIUC."));}
    catch(error){if(current===catalogueRequest&&alive&&host.isConnected&&source.value==="uiuc"){status.textContent=error.message+" Try Refresh catalogue to retry.";state("error");}}
    finally{if(current===catalogueRequest){loadingCatalogue=false;controls();}}
   }
   browse.onclick=()=>{if(isLocked())return;setOpen(panel.hidden);if(!panel.hidden){loadCatalogue(false);search.focus();}};refresh.onclick=()=>{if(!isLocked())loadCatalogue(true);};search.oninput=filter;choices.onchange=()=>{request++;loadingProfile=false;state(parsed(stored)?"ready":"needs-selection");controls();status.textContent="Selected "+choices.value+". Click Use selected profile to apply it.";};
   use.onclick=async()=>{
    if(isLocked()||!choices.value||loadingCatalogue||loadingProfile)return;const current=++request,id=choices.value;loadingProfile=true;state("loading-profile");controls();status.textContent="Loading "+id+"...";
    try{const data=await read("/api/airfoils/profile?id="+encodeURIComponent(id));if(current!==request||!alive||!host.isConnected||source.value!=="uiuc"||isLocked()||choices.value!==id)return;
     const encoded=JSON.stringify(data.profile);if(!parsed({value:encoded})||data.profile.id!==id)throw Error("The downloaded coordinates do not match the selected profile.");stored.value=encoded;state("ready");describe();status.textContent="Profile selected and embedded"+(data.cached?" from cache":" from UIUC")+". Save the Study or TOML to keep it.";change("profile");
    }catch(error){if(current===request&&alive&&host.isConnected&&source.value==="uiuc"){status.textContent=error.message+" Choose a profile and retry.";state("error");}}finally{if(current===request){loadingProfile=false;controls();}}
   };
   const cardListeners=[listen(source,"change",()=>{update(true);change("source");}),listen(code,"input",()=>{describe();change("code");})];
   const api={card,source,code,stored,describe,update,registryEntry(key){return{controller:viewport,from:previewKey,key,...(!viewport&&savedView?{state:savedView}:{})};},setKey(key){previewKey=key;const svg=selected.querySelector("svg");if(svg)svg.dataset.viewKey=key;},destroy({forget=false}={}){alive=false;request++;catalogueRequest++;for(const remove of cardListeners)remove();if(viewport)viewport.destroy({forget});else if(forget)globalThis.WingSVGViewport?.forget(previewKey);savedView=null;card.remove();}};allCards.push(api);return api;
  }
  for(const station of["root","tip"]){
   const prefix="airfoil."+station,source=doc.getElementById("p-"+prefix+"_source"),stored=doc.getElementById("p-"+prefix+"_profile"),code=doc.getElementById("p-"+prefix);if(!source||!stored||!code)continue;
   const sourceRow=doc.getElementById("row-"+prefix+"_source"),codeRow=doc.getElementById("row-"+prefix),storedRow=doc.getElementById("row-"+prefix+"_profile"),anchor=doc.createComment(station+" profile");host.insertBefore(anchor,sourceRow);
   const card=createCard({station,label:station==="root"?"Root profile (eta 0)":"Tip profile (eta 1)",source,stored,code,sourceRow,codeRow,storedRow,change:kind=>{if(kind==="profile")onEdit?.(prefix+"_profile");}});host.insertBefore(card.card,anchor);anchor.remove();
  }
  function sortedRows(){return [...rows].sort((a,b)=>{const av=a.eta.value.trim()===""?NaN:Number(a.eta.value),bv=b.eta.value.trim()===""?NaN:Number(b.eta.value);return Number.isFinite(av)&&Number.isFinite(bv)?av-bv:a.uid-b.uid;});}
  function drafts(){return sortedRows().map(row=>{const eta=row.eta.value.trim()===""?NaN:Number(row.eta.value),source=row.card.source.value,profile=parsed(row.card.stored);return{eta:Number.isFinite(eta)?eta:null,source,code:source==="naca"?row.card.code.value:(profile?.id||row.card.code.value),...(source==="uiuc"?{profile}:{} )};});}
  function validate(){
   const values=drafts();let error="";if(values.length>MAX_STATIONS)error="Use no more than "+MAX_STATIONS+" intermediate sections.";
   for(let i=0;!error&&i<values.length;i++){const row=values[i];if(!(row.eta>0&&row.eta<1))error="Intermediate airfoil eta must be greater than 0 and less than 1; root and tip are already defined.";else if(i&&Math.abs(row.eta-values[i-1].eta)<1e-8)error="Intermediate airfoils need distinct eta positions (at least 1e-8 apart).";else if(row.source==="uiuc"&&!row.profile)error="Select a UIUC intermediate airfoil at eta "+row.eta+": search the catalogue and click Use selected profile.";else if(row.source==="naca")try{nacaProfile(row.code,nacaOptions());}catch(e){error="Airfoil at eta "+row.eta+": "+e.message;}}
   if(stationEditor)stationEditor.dataset.invalidMessage=error;if(stationError){stationError.textContent=error;stationError.hidden=!error;}
   const ordered=sortedRows(),keys=ordered.map((row,i)=>row.card.registryEntry("airfoil-station-"+(i+1)));
   if(keys.some(entry=>entry.from!==entry.key))globalThis.WingSVGViewport?.rekeyAll(keys);
   ordered.forEach((row,i)=>{row.card.setKey("airfoil-station-"+(i+1));row.card.card.dataset.stationOrder=String(i+1);});return error;
  }
  function sync(notify=true){validate();if(storedStations)storedStations.value=JSON.stringify(drafts());updateNacaOptions();if(notify)onEdit?.(STATIONS_KEY);}
  function addStation(value,notify=true){
   if(rows.length>=MAX_STATIONS)return;const uid=++serial,station="station-"+uid,source=element("select"),code=element("input"),stored=element("input"),eta=element("input"),header=element("div","airfoil-station-header"),remove=element("button","mini ghost","Remove section");
   source.id="airfoil-"+station+"-source";for(const choice of["naca","uiuc"]){const option=element("option","",choice);option.value=choice;source.append(option);}source.value=value.source||"naca";code.id="airfoil-"+station+"-code";code.value=value.code||"NACA0012";stored.type="hidden";stored.value=value.profile?JSON.stringify(value.profile):"";
   eta.type="number";eta.min="0";eta.max="1";eta.step="0.01";eta.value=value.eta??"";eta.setAttribute("aria-label","Intermediate airfoil eta");eta.dataset.airfoilEta=String(uid);const etaLabel=element("label","","Eta ");etaLabel.append(eta);remove.type="button";remove.dataset.airfoilRemove=String(uid);header.append(etaLabel,remove);
   const sourceRow=element("label","row","Section source"),codeRow=element("label","row","NACA code");sourceRow.append(source);codeRow.append(code);
   const card=createCard({station,label:"Intermediate section",source,stored,code,sourceRow,codeRow,header,change:()=>sync()});card.card.append(stored);const row={uid,eta,remove,card};rows.push(row);stationList.append(card.card);
   const rowListeners=[listen(eta,"input",()=>{if(!isLocked())sync();}),listen(eta,"change",()=>{if(!validate())for(const entry of sortedRows())stationList.append(entry.card.card);})];remove.onclick=()=>{if(isLocked())return;for(const detach of rowListeners)detach();card.destroy({forget:true});rows.splice(rows.indexOf(row),1);allCards.splice(allCards.indexOf(card),1);sync();};card.update();sync(notify);
  }
  if(storedStations){
   const hidden=doc.getElementById("row-"+STATIONS_KEY);if(hidden)hidden.hidden=true;
   stationEditor=element("section","airfoil-stations-editor");stationEditor.id="airfoil-intermediate-sections";const heading=element("div","airfoil-stations-heading"),title=element("h3","","Intermediate sections"),add=element("button","mini","+ Add section");add.id="airfoil-add-station";add.type="button";heading.append(title,add);stationList=element("div","airfoil-station-list");stationError=element("p","airfoil-preview-error");stationError.setAttribute("role","alert");stationError.hidden=true;
   stationEditor.append(heading,element("p","pick-note","Place sections by eta (0 = root, 1 = tip). Edit the NACA code or select a UIUC profile for each section. Definitions are saved in span order."),stationError,stationList);
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
 return{install,plot,selectionMessage,nacaProfile,STATIONS_KEY,MAX_STATIONS};
});
