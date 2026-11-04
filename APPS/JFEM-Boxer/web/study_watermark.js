/* Editable Study identification. Presentation metadata never changes FE input. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingStudyWatermark=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const MAX_LENGTH=120,NS="http://www.w3.org/2000/svg";
 let active={text:"",visible:false};
 const managers=new Set(),subscribers=new Set();
 function normalize(value){
  if(value==null)return{text:"",visible:false};
  if(!value||typeof value!=="object"||Array.isArray(value)||Object.keys(value).some(key=>!["text","visible"].includes(key))||typeof value.text!=="string"||value.text.length>MAX_LENGTH||typeof value.visible!=="boolean"||/[\u0000-\u001f\u007f]/.test(value.text))throw Error("Study identification requires a single line of up to "+MAX_LENGTH+" characters and a boolean visibility setting.");
  return{text:value.text.trim(),visible:value.visible};
 }
 function current(){return{...active};}
 function publish(value){active=normalize(value);for(const listener of subscribers)listener(current());for(const manager of managers)manager.refresh();return current();}
 function subscribe(listener){subscribers.add(listener);return()=>subscribers.delete(listener);}
 const escape=text=>String(text).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&apos;"}[c]));
 function placement(width,height,text){return{x:width/2,y:height/2,size:Math.max(6,Math.min(42,height*.09,width*.84/Math.max(1,text.length*.62)))};}
 function svgMarkup(width,height,value=active){
  const data=normalize(value);if(!data.visible||!data.text)return"";const p=placement(width,height,data.text);
  return`<g data-study-watermark="true" pointer-events="none" aria-hidden="true"><text x="${p.x}" y="${p.y}" transform="rotate(-22 ${p.x} ${p.y})" text-anchor="middle" dominant-baseline="middle" font-family="system-ui,sans-serif" font-weight="600" font-size="${p.size}" fill="#7089a1" fill-opacity="0.32" stroke="#ffffff" stroke-opacity="0.18" stroke-width="0.6" paint-order="stroke">${escape(data.text)}</text></g>`;
 }
 function stampSVG(svg,value=active){
  svg.querySelectorAll("[data-study-watermark]").forEach(node=>node.remove());
  const data=normalize(value);if(!data.visible||!data.text)return;
  const doc=svg.ownerDocument,box=svg.viewBox?.baseVal||{x:0,y:0,width:Number(svg.getAttribute("width"))||1000,height:Number(svg.getAttribute("height"))||600};
  const p=placement(box.width,box.height,data.text),x=box.x+p.x,y=box.y+p.y,g=doc.createElementNS(NS,"g"),text=doc.createElementNS(NS,"text");
  g.setAttribute("data-study-watermark","true");g.setAttribute("pointer-events","none");g.setAttribute("aria-hidden","true");
  for(const[key,val]of Object.entries({x,y,transform:`rotate(-22 ${x} ${y})`,"text-anchor":"middle","dominant-baseline":"middle","font-family":"system-ui,sans-serif","font-weight":600,"font-size":p.size,fill:"#7089a1","fill-opacity":.32,stroke:"#ffffff","stroke-opacity":.18,"stroke-width":.6,"paint-order":"stroke"}))text.setAttribute(key,String(val));
  text.textContent=data.text;g.append(text);svg.append(g);
 }
 function paintCanvas(context,width,height,value=active){
  const data=normalize(value);if(!data.visible||!data.text)return;const p=placement(width,height,data.text);
  context.save();context.translate(p.x,p.y);context.rotate(-22*Math.PI/180);context.font=`600 ${p.size}px system-ui,sans-serif`;context.textAlign="center";context.textBaseline="middle";context.globalAlpha=.32;context.fillStyle="#7089a1";context.fillText(data.text,0,0);context.restore();
 }
 function stampExport(markup,type,{document:doc=globalThis.document}={}){
  const mime=String(type).split(";")[0].trim().toLowerCase();
  if(!active.visible||!active.text||!["image/svg+xml","text/html"].includes(mime))return markup;
  const win=doc.defaultView,parsed=new win.DOMParser().parseFromString(markup,mime);
  if(parsed.querySelector("parsererror"))throw Error("Cannot add Study identification to an invalid SVG export.");
  // A composed SVG/HTML report may contain nested axes SVGs and may already
  // carry the native 3D stamp. One stamp belongs to each top-level figure.
  for(const svg of parsed.querySelectorAll("svg"))if(!svg.parentElement?.closest("svg"))stampSVG(svg);
  return mime==="image/svg+xml"?new win.XMLSerializer().serializeToString(parsed.documentElement):"<!doctype html>\n"+parsed.documentElement.outerHTML;
 }
 function create({document:doc=globalThis.document,host=null,initial=null,onChange=()=>{}}={}){
  const win=doc.defaultView,overlays=new Map();let destroyed=false,frame=0,setting=false;
  let input=null,visible=null,status=null;
  function eligible(svg){
   // The aerodynamic axes SVG overlays the same viewport as its 3D canvas.
   // Its annotations must not receive a second copy of the identification.
   if(svg.matches(".aero-reference-overlay")||svg.closest("button,a,.viewport-tools,.svgv-toolbar,.dpv-toolbar"))return false;
   const box=svg.viewBox?.baseVal,r=svg.getBoundingClientRect();
   return !!(svg.matches(".svgv-canvas,.loft-distribution-plot,.dpv-stage svg,[data-view-key]")||r.width>=120&&r.height>=80||box?.width>=200&&box?.height>=100);
  }
  function sync(){if(input&&doc.activeElement!==input)input.value=active.text;if(visible)visible.checked=active.visible;if(status){const text=active.visible&&!active.text?"Enter identification text to show a watermark.":"Shown in 2D and 3D views and SVG exports when enabled. Saved with this Study.";if(status.textContent!==text)status.textContent=text;}}
  function update(){
   frame=0;if(destroyed)return;setting=true;
   const views=[...doc.querySelectorAll("svg")].filter(eligible);
   views.push(...doc.querySelectorAll("canvas#render,canvas.aero-canvas"));
   const keep=new Set(views);
   for(const[target,overlay]of overlays)if(!keep.has(target)||!target.isConnected){observer?.unobserve(target);overlay.remove();overlays.delete(target);}
   for(const target of views){
    const parent=target.parentElement;if(!parent)continue;
    let overlay=overlays.get(target);
    if(!overlay||overlay.parentElement!==parent){overlay?.remove();overlay=doc.createElement("div");overlay.className="study-watermark-overlay";overlay.setAttribute("aria-hidden","true");overlay.setAttribute("data-study-watermark-overlay","true");overlay.append(doc.createElement("span"));parent.classList.add("study-watermark-host");parent.append(overlay);overlays.set(target,overlay);observer?.observe(target);}
    const rect=target.getBoundingClientRect(),bounds=parent.getBoundingClientRect(),hidden=!active.visible||!active.text||!rect.width||!rect.height||win.getComputedStyle(target).visibility==="hidden";
    if(overlay.hidden!==hidden)overlay.hidden=hidden;
    const label=overlay.firstElementChild;if(label.textContent!==active.text)label.textContent=active.text;
    const style={left:(rect.left-bounds.left+parent.scrollLeft-parent.clientLeft)+"px",top:(rect.top-bounds.top+parent.scrollTop-parent.clientTop)+"px",width:rect.width+"px",height:rect.height+"px"};
    for(const[key,value]of Object.entries(style))if(overlay.style[key]!==value)overlay.style[key]=value;
    const size=placement(rect.width,rect.height,active.text).size+"px";if(label.style.fontSize!==size)label.style.fontSize=size;
   }
   sync();setting=false;
  }
  function refresh(){if(!destroyed&&!frame)frame=win.requestAnimationFrame(update);}
  const observer=typeof win.ResizeObserver==="function"?new win.ResizeObserver(refresh):null;
  const mutation=typeof win.MutationObserver==="function"?new win.MutationObserver(records=>{if(setting||records.every(record=>record.target.closest?.("[data-study-watermark-overlay],#study-watermark-controls")))return;refresh();}):null;
  mutation?.observe(doc.body,{subtree:true,childList:true,attributes:true,attributeFilter:["class","style","hidden","open","viewBox"]});
  doc.addEventListener("scroll",refresh,true);win.addEventListener("resize",refresh);doc.addEventListener("fullscreenchange",refresh);
  if(host){
   const fieldset=doc.createElement("fieldset"),legend=doc.createElement("legend"),textLabel=doc.createElement("label"),toggle=doc.createElement("label");
   legend.textContent="Study identification";fieldset.className="study-watermark-controls";
   input=doc.createElement("input");input.type="text";input.id="study-identification-text";input.maxLength=MAX_LENGTH;input.placeholder="Name / student ID / CONFIDENTIAL";input.title="Short identification text saved in the Study and displayed over every view when the watermark is enabled.";input.autocomplete="off";input.dataset.parameterLockExempt="true";
   textLabel.htmlFor=input.id;textLabel.textContent="Watermark text";textLabel.append(input);
   visible=doc.createElement("input");visible.type="checkbox";visible.id="show-study-watermark";visible.dataset.parameterLockExempt="true";toggle.className="layer";toggle.append(visible,doc.createTextNode("Show in all 2D and 3D views"));toggle.title="Toggle the saved Study identification overlay without changing the mesh or analysis.";
   status=doc.createElement("p");status.className="pick-note";status.setAttribute("role","status");fieldset.append(legend,textLabel,toggle,status);host.replaceChildren(fieldset);
   input.addEventListener("input",()=>{publish({text:input.value,visible:visible.checked});onChange({textChanged:true,value:current()});});
   visible.addEventListener("change",()=>{publish({text:input.value,visible:visible.checked});onChange({textChanged:false,value:current()});});
  }
  const manager={refresh,capture:current,restore(value){publish(value);sync();},destroy(){destroyed=true;if(frame)win.cancelAnimationFrame(frame);mutation?.disconnect();observer?.disconnect();doc.removeEventListener("scroll",refresh,true);win.removeEventListener("resize",refresh);doc.removeEventListener("fullscreenchange",refresh);for(const overlay of overlays.values())overlay.remove();overlays.clear();managers.delete(manager);}};
  managers.add(manager);publish(initial);sync();refresh();return manager;
 }
 return{MAX_LENGTH,normalize,current,publish,subscribe,create,svgMarkup,stampSVG,paintCanvas,stampExport};
});
