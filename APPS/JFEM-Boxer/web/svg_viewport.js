/* Shared navigation, image alignment and portable export for editable SVG drawings. */
(function (root, factory) {
  const api = factory(root);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingSVGViewport = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (root) {
  "use strict";
  const NS = "http://www.w3.org/2000/svg", MAX_IMAGE_BYTES = 8 * 1024 * 1024;
  const controllers=new Map(),registrations=new WeakMap();let savedStates={};
  const defaultsTools = () => ({grid:{enabled:false,spacing:1,color:"#526579"},snap:{enabled:false,points:true,lines:true},measurements:[]});
  const copyTools = value => ({grid:{...value.grid},snap:{...defaultsTools().snap,...value.snap},measurements:value.measurements.map(m=>({type:m.type,points:m.points.map(p=>({...p})),...(m.label?{label:{...m.label}}:{})}))});
  const defaults = () => ({version:1,theme:"dark",opacity:.55,image:null,transform:{x:0,y:0,scale:1},viewport:{x:0,y:0,scale:1},...defaultsTools()});
  const copyState = value => ({...value,image:value.image?{...value.image}:null,transform:{...value.transform},viewport:{...value.viewport},...copyTools(value)});
  const sameState = (a,b) => !!a && !!b && a.theme===b.theme && a.opacity===b.opacity &&
    ["transform","viewport"].every(k=>["x","y","scale"].every(f=>a[k][f]===b[k][f])) && JSON.stringify(copyTools(a))===JSON.stringify(copyTools(b)) &&
    (a.image===b.image || !!a.image && !!b.image && ["name","dataUrl","width","height"].every(k=>a.image[k]===b.image[k]));
  const clamp = (v,lo,hi) => Math.max(lo,Math.min(hi,v));
  const object = v => !!v && typeof v === "object" && !Array.isArray(v);
  const allowed = (v,names,label) => { if(Object.keys(v).some(k=>!names.includes(k))) throw new Error("Unsupported "+label+" setting."); };
  function validateState(value) {
    const result=defaults(); if(value==null)return result;
    if(!object(value))throw new Error("2D view settings must be an object.");
    allowed(value,["version","theme","opacity","image","transform","viewport","grid","snap","measurements"],"2D view");
    Object.assign(result,validateToolsState({grid:value.grid,snap:value.snap,measurements:value.measurements}));
    if(value.version!==undefined&&value.version!==1)throw new Error("Unsupported 2D view settings version.");
    if(value.theme!==undefined){if(!["dark","white"].includes(value.theme))throw new Error("2D background must be dark or white.");result.theme=value.theme;}
    if(value.opacity!==undefined){if(typeof value.opacity!=="number"||!Number.isFinite(value.opacity)||value.opacity<0||value.opacity>1)throw new Error("Image opacity must be between 0 and 1.");result.opacity=value.opacity;}
    for(const key of ["transform","viewport"])if(value[key]!==undefined){
      if(!object(value[key]))throw new Error("2D "+key+" must be an object.");allowed(value[key],["x","y","scale"],"2D "+key);
      for(const field of ["x","y","scale"]){const v=value[key][field]===undefined?result[key][field]:value[key][field];if(typeof v!=="number"||!Number.isFinite(v)||v<(field==="scale"?1e-6:-1e7)||v>(field==="scale"?1e4:1e7))throw new Error("2D "+key+" "+field+" is outside the supported range.");result[key][field]=v;}
    }
    if(value.image!=null){
      const im=value.image;if(!object(im)||typeof im.name!=="string"||im.name.length>512||typeof im.dataUrl!=="string")throw new Error("Background image metadata is invalid.");
      allowed(im,["name","dataUrl","width","height"],"background image");
      if(!Number.isInteger(im.width)||!Number.isInteger(im.height)||im.width<1||im.height<1||im.width>32768||im.height>32768||im.width*im.height>134217728)throw new Error("Background image dimensions are invalid or too large.");
      if(im.dataUrl.length>Math.ceil(MAX_IMAGE_BYTES/3)*4+64)throw new Error("Background images must be no larger than 8 MiB.");
      const match=/^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$/.exec(im.dataUrl);
      if(!match||match[2].length%4!==0)throw new Error("Use an embedded PNG, JPEG or WebP background image.");
      const bytes=match[2].length*3/4-(match[2].endsWith("==")?2:match[2].endsWith("=")?1:0);
      if(bytes>MAX_IMAGE_BYTES)throw new Error("Background images must be no larger than 8 MiB.");
      const head=root.atob(match[2].slice(0,32)),valid=match[1]==="png"?head.startsWith("\x89PNG\r\n\x1a\n"):match[1]==="jpeg"?head.startsWith("\xff\xd8\xff"):head.startsWith("RIFF")&&head.slice(8,12)==="WEBP";
      if(!valid)throw new Error("Background image content does not match its format.");
      result.image={name:im.name,dataUrl:im.dataUrl,width:im.width,height:im.height};
    }
    return result;
  }
  function validateToolsState(value={}) {
    if(!object(value))throw new Error("2D grid and dimensions must be an object.");
    allowed(value,["grid","snap","measurements"],"2D measurement");const result=defaultsTools();
    if(value.snap!==undefined){if(!object(value.snap))throw new Error("2D snapping must be an object.");allowed(value.snap,["enabled","points","lines"],"2D snapping");for(const key of ["enabled","points","lines"])if(value.snap[key]!==undefined){if(typeof value.snap[key]!=="boolean")throw new Error("2D snapping settings must be true or false.");result.snap[key]=value.snap[key];}}
    const coordinate=p=>{if(!object(p))throw new Error("Dimension coordinates must contain x and y.");allowed(p,["x","y"],"dimension coordinate");if(![p.x,p.y].every(v=>typeof v==="number"&&Number.isFinite(v)&&Math.abs(v)<=1e9))throw new Error("Dimension coordinates must be finite and no larger than 1e9.");return{x:p.x,y:p.y};};
    if(value.grid!==undefined){const g=value.grid;if(!object(g))throw new Error("2D grid must be an object.");allowed(g,["enabled","spacing","color"],"2D grid");
      if(g.enabled!==undefined){if(typeof g.enabled!=="boolean")throw new Error("2D grid visibility must be true or false.");result.grid.enabled=g.enabled;}
      if(g.spacing!==undefined){if(typeof g.spacing!=="number"||!Number.isFinite(g.spacing)||g.spacing<1e-9||g.spacing>1e9)throw new Error("Grid spacing must be between 1e-9 and 1e9 drawing units.");result.grid.spacing=g.spacing;}
      if(g.color!==undefined){if(typeof g.color!=="string"||!/^#[0-9a-fA-F]{6}$/.test(g.color))throw new Error("Grid colour must be a six-digit hex colour.");result.grid.color=g.color.toLowerCase();}
    }
    if(value.measurements!==undefined){if(!Array.isArray(value.measurements)||value.measurements.length>500)throw new Error("A drawing supports up to 500 dimensions.");
      result.measurements=value.measurements.map(m=>{if(!object(m))throw new Error("A dimension must be an object.");allowed(m,["type","points","label"],"dimension");if(!["distance","horizontal","vertical","angle"].includes(m.type))throw new Error("Unknown dimension type.");
        if(!Array.isArray(m.points)||m.points.length!==(m.type==="angle"?3:2))throw new Error("Distance dimensions need two points; angles need endpoint, vertex, endpoint.");
        const points=m.points.map(coordinate);
        if(m.type==="angle"&&[points[0],points[2]].some(p=>Math.hypot(p.x-points[1].x,p.y-points[1].y)<=1e-12))throw new Error("Angle endpoints must differ from the vertex.");return{type:m.type,points,...(m.label!==undefined?{label:coordinate(m.label)}:{})};
      });
    }return result;
  }
  function metricMapping(value={}) {
    const metric={origin:{x:0,y:0},x:{x:1,y:0},y:{x:0,y:1},unit:"drawing units",...value};
    for(const name of ["origin","x","y"])if(!object(metric[name])||![metric[name].x,metric[name].y].every(Number.isFinite))throw new Error("The drawing metric needs finite origin and axis vectors.");
    const det=metric.x.x*metric.y.y-metric.x.y*metric.y.x;
    if(!Number.isFinite(det)||Math.abs(det)<=1e-14*Math.hypot(metric.x.x,metric.x.y)*Math.hypot(metric.y.x,metric.y.y))throw new Error("Drawing metric axes must be independent.");
    if(typeof metric.unit!=="string"||metric.unit.length>40)throw new Error("Drawing units must be a short label.");
    return{...metric,toDrawing:p=>({x:metric.origin.x+p.x*metric.x.x+p.y*metric.y.x,y:metric.origin.y+p.x*metric.x.y+p.y*metric.y.y}),
      toMetric:p=>{const x=p.x-metric.origin.x,y=p.y-metric.origin.y;return{x:(x*metric.y.y-y*metric.y.x)/det,y:(y*metric.x.x-x*metric.x.y)/det};}};
  }
  function measurementValue(type,points) {
    const [a,b,c]=points;if(type==="horizontal")return Math.abs(b.x-a.x);if(type==="vertical")return Math.abs(b.y-a.y);
    if(type==="angle"){const x=a.x-b.x,y=a.y-b.y,u=c.x-b.x,v=c.y-b.y;return Math.atan2(Math.abs(x*v-y*u),x*u+y*v)*180/Math.PI;}
    return Math.hypot(b.x-a.x,b.y-a.y);
  }
  const dimensionNumber=value=>Math.abs(value)>=100?value.toFixed(2):Number(value.toPrecision(5)).toString();
  // Snap in screen space so the hit radius is constant under zoom, pan and
  // unequal/rotated SVG transforms. Endpoints take precedence over segments.
  function nearestSnap(point,targets,{points=true,lines=true,radius=10}={}){
    let best=null,distance=radius;const accept=(p,type)=>{const d=Math.hypot(p.x-point.x,p.y-point.y);if(d<=distance){distance=d;best={...p,type,distance:d};}};
    if(points)for(const p of targets.points||[])accept(p,"point");if(best)return best;
    if(lines)for(const [a,b]of targets.segments||[]){const dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy,t=length?clamp(((point.x-a.x)*dx+(point.y-a.y)*dy)/length,0,1):0;accept({x:a.x+t*dx,y:a.y+t*dy},"line");}
    return best;
  }
  // Current airfoils and all polygonal definition views use straight paths.
  // Preserve their actual vertices instead of resampling away narrow features.
  function linearPathGeometry(path){
    const tokens=String(path).match(/[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?/g)||[],points=[],segments=[];let i=0,command="",p={x:0,y:0},first=null;
    while(i<tokens.length){if(/^[a-zA-Z]$/.test(tokens[i]))command=tokens[i++];if(!command||!/[MLHVZ]/i.test(command))return null;const relative=command===command.toLowerCase(),upper=command.toUpperCase();
      if(upper==="Z"){if(first)segments.push([p,first]);p=first||p;command="";continue;}
      const count=upper==="H"||upper==="V"?1:2;if(i+count>tokens.length||tokens.slice(i,i+count).some(t=>/^[a-zA-Z]$/.test(t)))return null;
      const values=tokens.slice(i,i+count).map(Number);i+=count;if(!values.every(Number.isFinite))return null;let q;
      if(upper==="H")q={x:values[0]+(relative?p.x:0),y:p.y};else if(upper==="V")q={x:p.x,y:values[0]+(relative?p.y:0)};else q={x:values[0]+(relative?p.x:0),y:values[1]+(relative?p.y:0)};
      points.push(q);if(upper==="M"){first=q;command=relative?"l":"L";}else segments.push([p,q]);p=q;
    }return{points,segments};
  }
  function shapeGeometry(node){
    const number=name=>Number(node.getAttribute(name)||0),name=node.localName;let points=[],segments=[];
    if(name==="path")return linearPathGeometry(node.getAttribute("d"));
    if(name==="circle"||name==="ellipse")return{points:[{x:number("cx"),y:number("cy")}],segments};
    if(name==="line")points=[{x:number("x1"),y:number("y1")},{x:number("x2"),y:number("y2")}];
    else if(name==="polyline"||name==="polygon")for(let i=0;i<node.points.numberOfItems;i++){const p=node.points.getItem(i);points.push({x:p.x,y:p.y});}
    else if(name==="rect"){const x=number("x"),y=number("y"),w=number("width"),h=number("height");points=[{x,y},{x:x+w,y},{x:x+w,y:y+h},{x,y:y+h}];}
    for(let i=1;i<points.length;i++)segments.push([points[i-1],points[i]]);if((name==="polygon"||name==="rect")&&points.length)segments.push([points.at(-1),points[0]]);return{points,segments};
  }
  // Standalone tools also serve the detached plan view, which owns its camera.
  function createTools(options) {
    const svg=options.svg,doc=svg.ownerDocument,win=doc.defaultView,listeners=[];
    let state=validateToolsState(options.state||{}),metric=metricMapping(options.metric),spacingDefault=options.state?.grid===undefined,destroyed=false,mode="navigate",pending=[],pointer=null,hover=null,snapped=null,inputError="",gridLayer=null,dimensionLayer=null;
    const snapCache=new WeakMap();
    const controls=doc.createElement("span");controls.className="svgv-drawing-tools";
    controls.innerHTML='<details class="svgv-image-options svgv-grid-options"><summary title="Show a physical grid and choose its spacing and colour">Grid</summary><div><label><input type="checkbox" data-svgv="grid-enabled">Show grid</label><label>Spacing <input type="number" min="0.000000001" max="1000000000" step="any" data-svgv="grid-spacing"><span data-svgv="grid-unit"></span></label><label>Line colour <input type="color" data-svgv="grid-color"></label><small>At wide zoom, minor grid lines are skipped to keep the view clear.</small></div></details><label class="svgv-tool-label">Measure <select data-svgv="measure" aria-label="2D measurement tool"><option value="navigate">Navigate</option><option value="distance">Distance</option><option value="horizontal">Horizontal</option><option value="vertical">Vertical</option><option value="angle">Angle</option></select></label><button type="button" data-svgv="dimension-undo" title="Remove the last dimension">Undo dimension</button><button type="button" data-svgv="dimension-clear" title="Remove every dimension in this drawing">Clear</button><span data-svgv="dimension-status" class="svgv-dimension-status" role="status"></span>';
    (options.toolbarHost||svg.parentElement).append(controls);for(const el of controls.querySelectorAll("input,button,select"))el.dataset.parameterLockExempt="true";
    const snapControls=doc.createElement("span");snapControls.className="svgv-snap-controls";snapControls.innerHTML='<label class="svgv-tool-label" title="Snap dimension anchors to visible geometry within 10 screen pixels; reference images and annotations are ignored"><input type="checkbox" data-svgv="snap-enabled">Snap geometry</label><details class="svgv-image-options svgv-snap-options"><summary title="Choose snapping targets">Targets</summary><div><label><input type="checkbox" data-svgv="snap-points">Points and endpoints</label><label><input type="checkbox" data-svgv="snap-lines">Lines and edges</label><small>Point targets take priority. The 10-pixel tolerance stays constant while zooming. Dimension labels are positioned freely.</small></div></details>';controls.querySelector('.svgv-tool-label').after(snapControls);for(const el of snapControls.querySelectorAll('input'))el.dataset.parameterLockExempt="true";
    const get=name=>controls.querySelector('[data-svgv="'+name+'"]'),layer=()=>typeof options.layer==="function"?options.layer():options.layer||svg;
    const listen=(el,name,fn,opts)=>{el.addEventListener(name,fn,opts);listeners.push(()=>el.removeEventListener(name,fn,opts));};
    const capture=()=>copyTools(state),changed=()=>options.onChange?.(capture()),ink=()=>options.getTheme?.()==="white"?"#855300":"#ffc768";
    const drawPoint=event=>{if(options.getDrawingPoint)return options.getDrawingPoint(event);const p=svg.createSVGPoint();p.x=event.clientX;p.y=event.clientY;const ctm=layer()?.getScreenCTM();return ctm?p.matrixTransform(ctm.inverse()):p;};
    function pickPoint(event){snapped=null;if(state.snap.enabled&&pending.length<(mode==="angle"?3:2)){
      const targetRoot=options.getSnapRoot?.()||layer(),nodes=options.getSnapElements?.()||targetRoot?.querySelectorAll(options.snapSelector||"path,line,polyline,polygon,rect,circle,ellipse")||[],targets={points:[],segments:[]};let count=0;
      for(const node of nodes){if(node.closest("defs,marker,.svgv-grid,.svgv-dimensions,.svgv-background,.svgv-background-image,.dpv-background-image,[data-snap-ignore]"))continue;const style=win.getComputedStyle(node);if(style.display==="none"||style.visibility==="hidden"||Number(style.opacity)===0||!node.getClientRects().length)continue;
        const matrix=node.getScreenCTM();if(!matrix)continue;const key=["d","points","x","y","width","height","x1","y1","x2","y2","cx","cy"].map(k=>node.getAttribute(k)).join("|");let cached=snapCache.get(node);if(!cached||cached.key!==key){cached={key,data:shapeGeometry(node)};snapCache.set(node,cached);}const data=cached.data;if(!data)continue;if((count+=data.points.length+data.segments.length)>150000){inputError="Snapping is unavailable for this drawing: too many geometry targets.";return metric.toMetric(drawPoint(event));}
        const transform=p=>({x:matrix.a*p.x+matrix.c*p.y+matrix.e,y:matrix.b*p.x+matrix.d*p.y+matrix.f});if(state.snap.points)for(const p of data.points)targets.points.push(transform(p));if(state.snap.lines)for(const pair of data.segments)targets.segments.push(pair.map(transform));
      }
      const found=nearestSnap({x:event.clientX,y:event.clientY},targets,state.snap);if(found){const point=metric.toMetric(drawPoint({clientX:found.x,clientY:found.y}));snapped={point,type:found.type};return point;}
    }return metric.toMetric(drawPoint(event));}
    const scale=()=>{const m=layer()?.getScreenCTM(),s=options.getScale?.()??(m?Math.hypot(m.a,m.b):1);return Number.isFinite(s)&&s>0?s:1;};
    function visible(){if(options.getVisibleBounds)return options.getVisibleBounds();const r=svg.getBoundingClientRect(),a=drawPoint({clientX:r.left,clientY:r.top}),b=drawPoint({clientX:r.right,clientY:r.bottom});return{x:Math.min(a.x,b.x),y:Math.min(a.y,b.y),width:Math.abs(a.x-b.x),height:Math.abs(a.y-b.y)};}
    function element(name,attrs,parent){const el=doc.createElementNS(NS,name);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,String(v));parent.append(el);return el;}
    function line(a,b,parent,extra={}){return element("line",{x1:a.x,y1:a.y,x2:b.x,y2:b.y,fill:"none",stroke:ink(),"stroke-width":1,"vector-effect":"non-scaling-stroke",...extra},parent);}
    function label(at,text,parent,s){const e=element("text",{x:at.x,y:at.y,"font-family":"system-ui,sans-serif","font-size":12/s,"text-anchor":"middle","dominant-baseline":"middle",fill:ink(),stroke:options.getTheme?.()==="white"?"#fff":"#0c1520","stroke-width":3,"paint-order":"stroke","vector-effect":"non-scaling-stroke"},parent);e.style.fontSize=12/s+"px";e.style.fill=ink();e.style.stroke=options.getTheme?.()==="white"?"#fff":"#0c1520";e.textContent=text;}
    function tick(at,direction,parent,s){const n={x:-direction.y*4/s,y:direction.x*4/s};line({x:at.x-n.x,y:at.y-n.y},{x:at.x+n.x,y:at.y+n.y},parent);}
    function dimension(m,parent,s,draft=false){const points=m.points.map(metric.toDrawing),[a,b,c]=points;
      const group=element("g",{"class":"svgv-dimension"+(draft?" svgv-dimension-draft":""),"data-dimension-type":m.type,"data-dimension-value":measurementValue(m.type,m.points),opacity:draft?.65:1},parent);
      const placed=m.label?metric.toDrawing(m.label):null;
      if(m.type==="angle"){
        line(b,a,group);line(b,c,group);const av=Math.atan2(a.y-b.y,a.x-b.x),cv=Math.atan2(c.y-b.y,c.x-b.x);let delta=((cv-av+3*Math.PI)%(2*Math.PI))-Math.PI;
        const radius=placed?Math.max(6/s,Math.hypot(placed.x-b.x,placed.y-b.y)):Math.min(28/s,Math.hypot(a.x-b.x,a.y-b.y)*.45,Math.hypot(c.x-b.x,c.y-b.y)*.45),path=[];
        if(placed)for(const endpoint of [a,c]){const length=Math.hypot(endpoint.x-b.x,endpoint.y-b.y);if(radius+6/s>length)line(endpoint,{x:b.x+(endpoint.x-b.x)*(radius+6/s)/length,y:b.y+(endpoint.y-b.y)*(radius+6/s)/length},group,{"class":"svgv-extension","stroke-dasharray":"3 2"});}
        for(let i=0;i<=30;i++){const angle=av+delta*i/30;path.push((i?"L":"M")+(b.x+Math.cos(angle)*radius)+" "+(b.y+Math.sin(angle)*radius));}
        element("path",{d:path.join(" "),fill:"none",stroke:ink(),"stroke-width":1,"vector-effect":"non-scaling-stroke"},group);
        if(placed){const angle=Math.atan2(placed.y-b.y,placed.x-b.x),relative=((angle-av+3*Math.PI)%(2*Math.PI))-Math.PI;const onArc=relative*delta>=0&&Math.abs(relative)<=Math.abs(delta),nearEnd=Math.hypot(placed.x-(b.x+radius*Math.cos(av)),placed.y-(b.y+radius*Math.sin(av)))<Math.hypot(placed.x-(b.x+radius*Math.cos(cv)),placed.y-(b.y+radius*Math.sin(cv))),leaderAngle=onArc?angle:nearEnd?av:cv;const arcPoint={x:b.x+Math.cos(leaderAngle)*radius,y:b.y+Math.sin(leaderAngle)*radius};if(Math.hypot(arcPoint.x-placed.x,arcPoint.y-placed.y)>1/s)line(arcPoint,placed,group,{"class":"svgv-dimension-leader"});}
        label(placed||{x:b.x+Math.cos(av+delta/2)*(radius+13/s),y:b.y+Math.sin(av+delta/2)*(radius+13/s)},dimensionNumber(measurementValue(m.type,m.points))+"°",group,s);
      }else{
        let p=a,q=b;if(m.type==="horizontal")q=metric.toDrawing({x:m.points[1].x,y:m.points[0].y});if(m.type==="vertical")q=metric.toDrawing({x:m.points[0].x,y:m.points[1].y});
        const length=Math.hypot(q.x-p.x,q.y-p.y),direction=length>1e-12?{x:(q.x-p.x)/length,y:(q.y-p.y)/length}:{x:1,y:0},n={x:-direction.y,y:direction.x};
        const offset=placed?(placed.x-p.x)*n.x+(placed.y-p.y)*n.y:18/s,shift=p=>({x:p.x+n.x*offset,y:p.y+n.y*offset});let da=shift(p),db=shift(q);
        if(placed&&m.type==="horizontal"){da=metric.toDrawing({x:m.points[0].x,y:m.label.y});db=metric.toDrawing({x:m.points[1].x,y:m.label.y});}
        if(placed&&m.type==="vertical"){da=metric.toDrawing({x:m.label.x,y:m.points[0].y});db=metric.toDrawing({x:m.label.x,y:m.points[1].y});}
        line(a,da,group,{"class":"svgv-extension","stroke-dasharray":"3 2"});line(b,db,group,{"class":"svgv-extension","stroke-dasharray":"3 2"});line(da,db,group,{"class":"svgv-dimension-line"});tick(da,direction,group,s);tick(db,direction,group,s);
        if(placed){const vx=db.x-da.x,vy=db.y-da.y,l2=vx*vx+vy*vy,t=l2?((placed.x-da.x)*vx+(placed.y-da.y)*vy)/l2:0;if(t<0||t>1)line(t<0?da:db,placed,group,{"class":"svgv-dimension-leader"});}
        label(placed||{x:(da.x+db.x)/2+n.x*12/s,y:(da.y+db.y)/2+n.y*12/s},dimensionNumber(measurementValue(m.type,m.points))+(metric.unit?" "+metric.unit:""),group,s);
      }
      for(const p of points)element("circle",{cx:p.x,cy:p.y,r:2.5/s,fill:ink(),stroke:"none"},group);
    }
    function render(){if(destroyed)return;const parent=layer();if(!parent)return;
      if(gridLayer?.parentNode!==parent){gridLayer?.remove();dimensionLayer?.remove();gridLayer=element("g",{"class":"svgv-grid","pointer-events":"none"},parent);parent.insertBefore(gridLayer,parent.firstChild);dimensionLayer=element("g",{"class":"svgv-dimensions","pointer-events":"none"},parent);}
      // Native drawing refreshes can append geometry; dimensions remain on top.
      parent.append(dimensionLayer);gridLayer.replaceChildren();dimensionLayer.replaceChildren();const s=scale();
      if(state.grid.enabled){const b=visible(),corners=[{x:b.x,y:b.y},{x:b.x+b.width,y:b.y},{x:b.x,y:b.y+b.height},{x:b.x+b.width,y:b.y+b.height}].map(metric.toMetric),lo={x:Math.min(...corners.map(p=>p.x)),y:Math.min(...corners.map(p=>p.y))},hi={x:Math.max(...corners.map(p=>p.x)),y:Math.max(...corners.map(p=>p.y))};
        for(const axis of ["x","y"]){const other=axis==="x"?"y":"x",spacing=state.grid.spacing,pixels=spacing*Math.hypot(metric[axis].x,metric[axis].y)*s,stride=Math.max(1,Math.ceil(6/pixels),Math.ceil((hi[axis]-lo[axis])/spacing/700)),step=spacing*stride;
          for(let k=Math.ceil(lo[axis]/step),end=Math.floor(hi[axis]/step),count=0;k<=end&&count<702;k++,count++){const a=metric.toDrawing({[axis]:k*step,[other]:lo[other]}),b=metric.toDrawing({[axis]:k*step,[other]:hi[other]});line(a,b,gridLayer,{stroke:state.grid.color,"stroke-width":k===0?1:.7,"stroke-opacity":k===0?.8:.5,"data-grid-axis":axis});}
        }
      }
      for(const m of state.measurements)dimension(m,dimensionLayer,s);
      const needed=mode==="angle"?3:2,placing=pending.length===needed,draft=placing?pending:hover?[...pending,hover]:pending;
      if(mode!=="navigate"&&draft.length===needed&&!(mode==="angle"&&[draft[0],draft[2]].some(p=>Math.hypot(p.x-draft[1].x,p.y-draft[1].y)<1e-12)))dimension({type:mode,points:draft,...(placing&&hover?{label:hover}:{})},dimensionLayer,s,true);
      else for(const p of pending.map(metric.toDrawing))element("circle",{cx:p.x,cy:p.y,r:3/s,fill:ink()},dimensionLayer);
      if(snapped&&!placing){const p=metric.toDrawing(snapped.point);element(snapped.type==="point"?"circle":"rect",{"class":"svgv-snap-marker",...(snapped.type==="point"?{cx:p.x,cy:p.y,r:6/s}:{x:p.x-5/s,y:p.y-5/s,width:10/s,height:10/s}),fill:"none",stroke:options.getTheme?.()==="white"?"#005d9c":"#79deff","stroke-width":2,"vector-effect":"non-scaling-stroke","data-snap-kind":snapped.type},dimensionLayer);}
      get("grid-enabled").checked=state.grid.enabled;if(doc.activeElement!==get("grid-spacing"))get("grid-spacing").value=state.grid.spacing;get("grid-color").value=state.grid.color;get("grid-unit").textContent=metric.unit;for(const axis of ["horizontal","vertical"]){const option=get("measure").querySelector('option[value="'+axis+'"]');option.textContent=axis[0].toUpperCase()+axis.slice(1)+(metric[axis+"Label"]?" ("+metric[axis+"Label"]+")":"");}
      get("dimension-undo").disabled=!state.measurements.length;get("dimension-clear").disabled=!state.measurements.length;svg.classList.toggle("svgv-measuring",mode!=="navigate");
      for(const name of ["enabled","points","lines"])get("snap-"+name).checked=state.snap[name];
      if(!pointer)get("dimension-status").textContent=inputError||(mode==="navigate"?"":(placing?"Move dimension and click to place label":mode==="angle"?["Click first endpoint", "Click angle vertex", "Click second endpoint"][pending.length]:"Click "+(pending.length?"second":"first")+" point")+(snapped&&!placing?" · "+(snapped.type==="point"?"Point":"Line")+" snap":"")+" · Esc cancels");
    }
    function cancel(){pending=[];hover=null;snapped=null;inputError="";if(pointer){try{svg.releasePointerCapture(pointer.id);}catch(_){}pointer=null;}}
    function setMode(value){cancel();mode=value;get("measure").value=mode;render();}
    get("measure").onchange=()=>setMode(get("measure").value);
    get("grid-enabled").onchange=()=>{state.grid.enabled=get("grid-enabled").checked;render();changed();};
    get("grid-spacing").onchange=()=>{const v=Number(get("grid-spacing").value);if(Number.isFinite(v)&&v>=1e-9&&v<=1e9){state.grid.spacing=v;spacingDefault=false;get("grid-spacing").setCustomValidity("");render();changed();}else{get("grid-spacing").setCustomValidity("Enter a positive grid spacing between 1e-9 and 1e9.");get("grid-spacing").reportValidity();}};
    get("grid-color").oninput=()=>{state.grid.color=get("grid-color").value;render();};get("grid-color").onchange=changed;
    for(const name of ["enabled","points","lines"])get("snap-"+name).onchange=()=>{state.snap[name]=get("snap-"+name).checked;snapped=null;inputError="";render();changed();};
    get("dimension-undo").onclick=()=>{cancel();state.measurements.pop();render();changed();};get("dimension-clear").onclick=()=>{cancel();state.measurements=[];render();changed();};
    listen(svg,"pointerdown",event=>{if(mode==="navigate"||event.button!==0||event.ctrlKey||event.metaKey)return;event.preventDefault();event.stopImmediatePropagation();svg.focus({preventScroll:true});pointer={id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};svg.setPointerCapture(event.pointerId);},true);
    listen(svg,"pointermove",event=>{if(mode==="navigate")return;if(pointer){if(event.pointerId!==pointer.id)return;event.preventDefault();event.stopImmediatePropagation();pointer.moved ||= Math.hypot(event.clientX-pointer.x,event.clientY-pointer.y)>=5;}if(!event.ctrlKey&&!event.metaKey){inputError="";hover=pickPoint(event);render();}},true);
    listen(svg,"pointerup",event=>{if(!pointer||event.pointerId!==pointer.id)return;event.preventDefault();event.stopImmediatePropagation();const click=!pointer.moved,p=pickPoint(event);pointer=null;try{svg.releasePointerCapture(event.pointerId);}catch(_){}if(click){inputError="";const needed=mode==="angle"?3:2;if(pending.length===needed){try{state=validateToolsState({...state,measurements:[...state.measurements,{type:mode,points:pending,label:p}]});pending=[];hover=null;snapped=null;changed();}catch(e){inputError=e.message;}}else{pending.push(p);hover=null;if(pending.length===needed){try{validateToolsState({measurements:[{type:mode,points:pending}]});snapped=null;}catch(e){pending.pop();inputError=e.message;}}}}render();},true);
    for(const event of ["pointercancel","lostpointercapture"])listen(svg,event,e=>{if(pointer&&e.pointerId===pointer.id){e.stopImmediatePropagation();pointer=null;hover=null;render();}},true);
    for(const event of ["click","dblclick"])listen(svg,event,e=>{if(mode!=="navigate"&&e.button===0&&!e.ctrlKey&&!e.metaKey){e.preventDefault();e.stopImmediatePropagation();}},true);
    listen(svg,"keydown",event=>{if(event.key==="Escape"&&mode!=="navigate"&&!svg.matches(".svgv-panning,.dpv-dragging")){event.preventDefault();event.stopImmediatePropagation();setMode("navigate");}},true);
    const api={capture,render,isMeasuring:()=>mode!=="navigate",setMetric(value){metric=metricMapping(value);if(spacingDefault&&Number.isFinite(value.gridSpacing))state.grid.spacing=value.gridSpacing;render();},restore(value,{defaultSpacing=false}={}){state=validateToolsState(value);spacingDefault=defaultSpacing;if(spacingDefault&&Number.isFinite(metric.gridSpacing))state.grid.spacing=metric.gridSpacing;setMode("navigate");},destroy(){if(destroyed)return;cancel();destroyed=true;listeners.forEach(fn=>fn());controls.remove();gridLayer?.remove();dimensionLayer?.remove();svg.classList.remove("svgv-measuring");},controls};
    if(options.metric?.gridSpacing&&options.state?.grid===undefined)state.grid.spacing=options.metric.gridSpacing;render();return api;
  }
  const STYLE_PROPERTIES=["fill","fill-opacity","fill-rule","stroke","stroke-width","stroke-opacity","stroke-dasharray","stroke-dashoffset","stroke-linecap","stroke-linejoin","stroke-miterlimit","opacity","color","font-family","font-size","font-style","font-weight","letter-spacing","text-anchor","dominant-baseline","alignment-baseline","paint-order","vector-effect","marker-start","marker-mid","marker-end","visibility","display","clip-path","mask","filter"];
  function serializeSVG(svg,options={}) {
    if(!svg||svg.namespaceURI!==NS)throw new Error("Choose an SVG drawing to export.");
    const doc=svg.ownerDocument,win=doc.defaultView,clone=svg.cloneNode(true),sources=[svg,...svg.querySelectorAll("*")],copies=[clone,...clone.querySelectorAll("*")];
    sources.forEach((source,index)=>{
      const target=copies[index],computed=win.getComputedStyle(source);
      for(const property of STYLE_PROPERTIES){let value=computed.getPropertyValue(property);if(!value)continue;value=value.replace(/url\(["']?(?:[^)"']*#)([^)"']+)["']?\)/g,"url(#$1)");target.style.setProperty(property,value);}
      for(const attribute of Array.from(target.attributes))if(/^on/i.test(attribute.name)||attribute.name==="tabindex"||attribute.name.startsWith("data-svgv"))target.removeAttribute(attribute.name);
    });
    clone.querySelectorAll("script,foreignObject,.svgv-dimension-draft,.svgv-snap-marker").forEach(n=>n.remove());
    clone.setAttribute("xmlns",NS);clone.removeAttribute("id");clone.removeAttribute("tabindex");
    const rect=svg.getBoundingClientRect(),box=svg.viewBox.baseVal;
    clone.setAttribute("width",String(Math.max(1,Math.round(rect.width)||box.width||1000)));clone.setAttribute("height",String(Math.max(1,Math.round(rect.height)||box.height||600)));
    clone.style.removeProperty("max-height");clone.style.removeProperty("min-width");
    clone.style.backgroundColor=options.backgroundColor||options.background||(options.theme==="white"?"#ffffff":"#0c1520");
    const background=doc.createElementNS(NS,"rect");background.setAttribute("x",String(box.x));background.setAttribute("y",String(box.y));background.setAttribute("width",String(box.width||rect.width));background.setAttribute("height",String(box.height||rect.height));background.setAttribute("fill",options.backgroundColor||options.background||(options.theme==="white"?"#ffffff":"#0c1520"));background.setAttribute("data-export-background","true");
    clone.insertBefore(background,clone.firstChild);
    return '<?xml version="1.0" encoding="UTF-8"?>\n'+new win.XMLSerializer().serializeToString(clone);
  }
  function downloadSVG(svg,options={}) {
    const source=serializeSVG(svg,options),doc=svg.ownerDocument,win=doc.defaultView,url=win.URL.createObjectURL(new win.Blob([source],{type:"image/svg+xml;charset=utf-8"})),link=doc.createElement("a");
    link.href=url;link.download=String(options.filename||"wing-view.svg").replace(/[<>:"/\\|?*\x00-\x1f]/g,"_");doc.body.append(link);link.click();link.remove();win.setTimeout(()=>win.URL.revokeObjectURL(url),1000);return source;
  }
  function install(svg,options={}) {
    if(!svg||svg.namespaceURI!==NS)throw new Error("A 2D SVG drawing is required.");
    if(svg.__wingSVGViewport)return svg.__wingSVGViewport;
    const doc=svg.ownerDocument,win=doc.defaultView,host=options.host||svg.parentElement,listeners=[];let key=options.key||svg.dataset.viewKey;
    const presentationRecords=new WeakMap();
    let state=defaults(),notifiedState=null,scene=null,geometry=null,image=null,background=null,drag=null,destroyed=false,loading=false,loadToken=0,wheelTimer=0,screen=[],styleRecords=[],geometryCount=0,externalPointer=null,drawingTools=null;
    const toolbar=doc.createElement("div");toolbar.className="svgv-toolbar";
    toolbar.innerHTML='<button type="button" data-svgv="fit" title="Fit the drawing; keep background image alignment">Fit</button><button type="button" data-svgv="smaller" title="Zoom out; Alt for fine adjustment" aria-label="Zoom out">−</button><button type="button" data-svgv="larger" title="Zoom in; Alt for fine adjustment" aria-label="Zoom in">+</button><button type="button" data-svgv="upload" title="Load a PNG, JPEG or WebP reference image (up to 8 MiB)">Image…</button><input type="file" data-svgv="file" accept="image/png,image/jpeg,image/webp" hidden><details class="svgv-image-options"><summary title="Background image scale, opacity and alignment">Image settings</summary><div><label>Scale <input data-svgv="scale" type="number" min="0.0001" max="1000000" step="1">%</label><label>Opacity <input data-svgv="opacity" type="range" min="0" max="1" step="0.05"></label><button type="button" data-svgv="reset">Reset alignment</button><button type="button" data-svgv="remove">Remove image</button></div></details><button type="button" data-svgv="theme" title="Switch the drawing between dark and white backgrounds">White background</button><button type="button" data-svgv="export" title="Export this visible drawing and reference image as a standalone SVG">Export SVG</button><button type="button" data-svgv="help" aria-expanded="false" title="Drawing navigation and image alignment instructions">? Help</button>';
    for(const control of toolbar.querySelectorAll("input,button,select,textarea"))control.dataset.parameterLockExempt="true";
    if(options.toolbarHost)options.toolbarHost.append(toolbar);else svg.parentElement.insertBefore(toolbar,svg);
    const help=doc.createElement("p");help.className="svgv-help";help.hidden=true;help.innerHTML="Drag empty space or use the middle mouse button to pan. Use the wheel or +/− to zoom. Hold <b>Alt</b> for finer zoom. Geometry handles still edit the model. Hold <b>Ctrl</b> (Windows/Linux) or <b>Cmd</b> (Mac) while dragging or zooming to move or scale only the background image. Arrow keys pan; Shift uses larger steps. Fit restores the view without moving the image. Image settings provide exact scale and opacity. Export SVG saves the visible drawing, background and image.";
    toolbar.insertAdjacentElement("afterend",help);
    const error=doc.createElement("p");error.className="svgv-error";error.hidden=true;error.setAttribute("role","alert");help.insertAdjacentElement("afterend",error);
    const get=name=>toolbar.querySelector('[data-svgv="'+name+'"]');
    host.classList.add("svgv-host");svg.classList.add("svgv-canvas");if(!svg.hasAttribute("tabindex"))svg.setAttribute("tabindex","0");
    const listen=(element,type,handler,opts)=>{element.addEventListener(type,handler,opts);listeners.push(()=>element.removeEventListener(type,handler,opts));};
    function changed(){if(destroyed||sameState(state,notifiedState))return;const value=capture();notifiedState=copyState(value);if(key)savedStates[key]=value;options.onChange?.(value);svg.dispatchEvent(new win.CustomEvent("svgviewchange",{bubbles:true,detail:{key,state:value}}));}
    function capture(){return copyState({...state,...(drawingTools?drawingTools.capture():{})});}
    const bounds=()=>{const b=svg.viewBox.baseVal;return{x:b.x,y:b.y,width:b.width||760,height:b.height||340};};
    const center=()=>{const b=bounds();return{x:b.x+b.width/2,y:b.y+b.height/2};};
    const fitScale=()=>state.image?Math.min(bounds().width*.8/state.image.width,bounds().height*.8/state.image.height):1;
    function local(event){const p=svg.createSVGPoint();p.x=event.clientX;p.y=event.clientY;const ctm=svg.getScreenCTM();return ctm?p.matrixTransform(ctm.inverse()):p;}
    function toDrawingPoint(event){const p=local(event);return{x:(p.x-state.viewport.x)/state.viewport.scale,y:(p.y-state.viewport.y)/state.viewport.scale};}
    function rememberPresentation(){
      screen=[];styleRecords=[];geometryCount=geometry.querySelectorAll("*").length;
      for(const element of geometry.querySelectorAll("*")){
        let original=presentationRecords.get(element);if(!original){original={transform:element.getAttribute("transform"),r:element.getAttribute("r"),markerWidth:element.getAttribute("markerWidth"),markerHeight:element.getAttribute("markerHeight"),vectorEffect:element.getAttribute("vector-effect"),strokeWidth:element.style.getPropertyValue("stroke-width")};presentationRecords.set(element,original);}else for(const attr of ["transform","r","markerWidth","markerHeight"]){if(original[attr]===null)element.removeAttribute(attr);else element.setAttribute(attr,original[attr]);}
        if(["path","line","polyline","polygon","rect","circle","ellipse","text"].includes(element.localName))element.setAttribute("vector-effect","non-scaling-stroke");
        if(element.localName==="marker"){const width=Number(element.getAttribute("markerWidth"))||7,height=Number(element.getAttribute("markerHeight"))||7;element.setAttribute("markerUnits","userSpaceOnUse");if(!element.hasAttribute("viewBox"))element.setAttribute("viewBox",`0 0 ${width} ${height}`);screen.push({kind:"marker",element,width,height});}
        if(element.localName==="circle")screen.push({kind:"circle",element,radius:Number(element.getAttribute("r"))||0});
        if(element.localName==="text")screen.push({kind:"text",element,transform:element.getAttribute("transform")||"",x:Number(element.getAttribute("x"))||0,y:Number(element.getAttribute("y"))||0,size:parseFloat(win.getComputedStyle(element).fontSize)||14});
        if(["path","line","polyline","polygon","rect","circle","ellipse","text"].includes(element.localName)){styleRecords.push({element,fill:element.style.getPropertyValue("fill"),stroke:element.style.getPropertyValue("stroke"),fillPriority:element.style.getPropertyPriority("fill"),strokePriority:element.style.getPropertyPriority("stroke")});if(original.strokeWidth)element.style.setProperty("stroke-width",original.strokeWidth);else element.style.removeProperty("stroke-width");const width=parseFloat(win.getComputedStyle(element).strokeWidth);if(width>0&&width<.15)screen.push({kind:"stroke",element,width});}
      }
    }
    function whiteColor(value,isText,stroke){
      const m=/^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+))?\s*\)$/.exec(value);if(!m)return value;
      const rgb=m.slice(1,4).map(Number),alpha=m[4]===undefined?1:Number(m[4]);if(alpha===0)return value;
      const lum=(.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2])/255;
      if(isText&&stroke&&lum<.25)return`rgba(255,255,255,${alpha})`;
      if(isText&&!stroke)return`rgba(29,48,65,${alpha})`;
      if(lum>.43){const factor=.36/lum;return`rgba(${rgb.map(v=>Math.round(v*factor)).join(",")},${alpha})`;}
      return value;
    }
    function theme(){
      host.dataset.svgvTheme=state.theme;svg.style.backgroundColor=state.theme==="white"?"#ffffff":"#0c1520";
      for(const r of styleRecords){for(const key of ["fill","stroke"]){if(r[key])r.element.style.setProperty(key,r[key],r[key+"Priority"]);else r.element.style.removeProperty(key);}}
      if(state.theme==="white")for(const r of styleRecords){const computed=win.getComputedStyle(r.element);for(const key of ["fill","stroke"]){const before=computed.getPropertyValue(key),after=whiteColor(before,r.element.localName==="text",key==="stroke");if(after!==before)r.element.style.setProperty(key,after);}}
      get("theme").textContent=state.theme==="white"?"Dark background":"White background";get("theme").setAttribute("aria-pressed",String(state.theme==="white"));
    }
    function screenPresentation(){const matrix=svg.getScreenCTM(),base=matrix?Math.hypot(matrix.a,matrix.b):0,scale=base*state.viewport.scale;if(!(scale>0))return;
      for(const item of screen){if(item.kind==="marker"){item.element.setAttribute("markerWidth",String(item.width/scale));item.element.setAttribute("markerHeight",String(item.height/scale));}else if(item.kind==="stroke")item.element.style.strokeWidth=String(item.width*base);else if(item.kind==="circle")item.element.setAttribute("r",String(item.radius*(item.radius<.2?base:1)/scale));else{const factor=Math.max(10,item.size*base)/(item.size*scale);item.element.setAttribute("transform",`${item.transform} translate(${item.x} ${item.y}) scale(${factor}) translate(${-item.x} ${-item.y})`);}}
    }
    function render(){if(destroyed||!scene)return;scene.setAttribute("transform",`translate(${state.viewport.x} ${state.viewport.y}) scale(${state.viewport.scale})`);
      const b=bounds();background.setAttribute("x",b.x);background.setAttribute("y",b.y);background.setAttribute("width",b.width);background.setAttribute("height",b.height);background.setAttribute("fill",state.theme==="white"?"#ffffff":"#0c1520");
      if(state.image){if(!image){image=doc.createElementNS(NS,"image");image.classList.add("svgv-background-image");image.setAttribute("pointer-events","none");scene.insertBefore(image,geometry);}if(image.getAttribute("href")!==state.image.dataUrl)image.setAttribute("href",state.image.dataUrl);image.setAttribute("width",state.image.width);image.setAttribute("height",state.image.height);image.setAttribute("opacity",state.opacity);image.setAttribute("transform",`translate(${state.transform.x} ${state.transform.y}) scale(${state.transform.scale})`);}else{image?.remove();image=null;}
      for(const name of ["scale","opacity","reset","remove"])get(name).disabled=!state.image||loading;get("upload").disabled=loading;get("upload").textContent=loading?"Reading image…":"Image…";get("upload").title=state.image?state.image.name:"Load a PNG, JPEG or WebP reference image (up to 8 MiB)";
      if(doc.activeElement!==get("scale"))get("scale").value=String(Number((state.transform.scale/fitScale()*100).toPrecision(8)));get("opacity").value=state.opacity;
      svg.classList.toggle("svgv-panning",!!drag);svg.classList.toggle("svgv-image-only",drag?.target==="transform");screenPresentation();drawingTools?.render();
    }
    function refresh(){if(destroyed)return;
      if(!scene||scene.parentNode!==svg){
        const children=Array.from(svg.childNodes);background=doc.createElementNS(NS,"rect");background.classList.add("svgv-background");background.setAttribute("pointer-events","all");scene=doc.createElementNS(NS,"g");scene.classList.add("svgv-scene");geometry=doc.createElementNS(NS,"g");geometry.classList.add("svgv-geometry");geometry.setAttribute("data-svgview-geometry","");for(const child of children)geometry.append(child);scene.append(geometry);svg.append(background,scene);image=null;rememberPresentation();theme();
      }else{
        // Some drawings append new annotations after the main SVG refresh.
        const children=Array.from(svg.childNodes).filter(n=>n!==scene&&n!==background);if(children.length||geometry.querySelectorAll("*").length!==geometryCount){for(const child of children)geometry.append(child);for(const r of styleRecords)for(const key of ["fill","stroke"]){if(r[key])r.element.style.setProperty(key,r[key],r[key+"Priority"]);else r.element.style.removeProperty(key);}rememberPresentation();theme();}
      }
      render();
    }
    function zoom(target,factor,anchor=center()){if(target==="transform"&&!state.image||!Number.isFinite(factor)||factor<=0)return;const before=state[target],scale=clamp(before.scale*factor,1e-6,1e4);if(scale===before.scale)return;const a=target==="transform"?{x:(anchor.x-state.viewport.x)/state.viewport.scale,y:(anchor.y-state.viewport.y)/state.viewport.scale}:anchor,ratio=scale/before.scale;state[target]={x:clamp(a.x-(a.x-before.x)*ratio,-1e7,1e7),y:clamp(a.y-(a.y-before.y)*ratio,-1e7,1e7),scale};render();}
    function stop(cancel=false){if(!drag)return;const prior=drag;drag=null;if(cancel)state[prior.target]=prior.original;try{svg.releasePointerCapture(prior.pointerId);}catch(_){}render();if(!cancel)changed();}
    function fit(){stop(true);state.viewport={x:0,y:0,scale:1};render();changed();}
    function resetImage(notify=true){if(!state.image)return;const b=bounds(),scale=fitScale();state.transform={x:b.x+(b.width-state.image.width*scale)/2,y:b.y+(b.height-state.image.height*scale)/2,scale};render();if(notify)changed();}
    const targetFor=e=>e.ctrlKey||e.metaKey?"transform":"viewport";
    const control=(target,event)=>options.isGeometryTarget?options.isGeometryTarget(target,event):!!target.closest?.('[role="button"],[data-control],[data-point],[data-edge],[data-rib-part],.pf-point,.sp-point,.rl-handle,.rl-angle-handle,.rl-line-handle');
    drawingTools=createTools({svg,toolbarHost:toolbar,layer:()=>scene,getSnapRoot:()=>geometry,snapSelector:options.snapSelector,getSnapElements:options.getSnapElements,getDrawingPoint:toDrawingPoint,getTheme:()=>state.theme,metric:options.metric,onChange:value=>{Object.assign(state,value);changed();}});
    help.append(doc.createTextNode(" Grid uses the drawing's physical units; choose spacing and line colour in Grid settings. Pick two anchors for a distance, horizontal or vertical dimension; pick endpoint, vertex, endpoint for an angle. Then move the label and dimension lines and click once more to place them. Snap geometry targets visible points/endpoints and lines within 10 screen pixels; background images, axes and annotations are excluded. Snap settings choose points and/or edges. Labels are placed freely. Measurements do not edit geometry. Middle-drag still pans; Ctrl/Cmd still aligns the image. Escape cancels the pending dimension and returns to Navigate. Undo dimension removes the last dimension; Clear removes all dimensions. Grid, snapping and completed dimension label positions are included in Study/TOML state and SVG export."));
    listen(svg,"pointerdown",event=>{const target=targetFor(event);if(![0,1].includes(event.button))return;if(event.button===0&&target==="viewport"&&control(event.target,event))return;if(target==="transform"&&!state.image)return;event.preventDefault();event.stopImmediatePropagation();svg.focus({preventScroll:true});drag={pointerId:event.pointerId,target,start:local(event),original:{...state[target]},divisor:target==="transform"?state.viewport.scale:1};svg.setPointerCapture(event.pointerId);render();},true);
    listen(svg,"pointermove",event=>{if(!drag||event.pointerId!==drag.pointerId)return;event.preventDefault();event.stopImmediatePropagation();const p=local(event);state[drag.target]={...drag.original,x:clamp(drag.original.x+(p.x-drag.start.x)/drag.divisor,-1e7,1e7),y:clamp(drag.original.y+(p.y-drag.start.y)/drag.divisor,-1e7,1e7)};render();},true);
    for(const name of ["pointerup","pointercancel","lostpointercapture"])listen(svg,name,event=>{if(!drag)return;event.stopImmediatePropagation();stop(name!=="pointerup");},true);
    listen(svg,"gotpointercapture",event=>{if(!drag)externalPointer=event.pointerId;});listen(svg,"lostpointercapture",event=>{if(externalPointer===event.pointerId)externalPointer=null;});
    listen(svg,"wheel",event=>{event.preventDefault();event.stopImmediatePropagation();if(drag||externalPointer!==null)return;const target=targetFor(event);if(target==="transform"&&!state.image)return;const delta=event.deltaY*(event.deltaMode===1?16:event.deltaMode===2?svg.clientHeight||600:1);zoom(target,Math.exp(-clamp(delta,-1000,1000)*.0015*(event.altKey?.1:1)),local(event));win.clearTimeout(wheelTimer);wheelTimer=win.setTimeout(changed,120);},{passive:false,capture:true});
    listen(svg,"keydown",event=>{if(event.key==="Escape"&&drag){event.preventDefault();event.stopImmediatePropagation();stop(true);return;}if(control(event.target,event)&&!event.ctrlKey&&!event.metaKey)return;const target=targetFor(event);if(target==="transform"&&!state.image)return;if(["+","=","-","_"].includes(event.key)){event.preventDefault();event.stopImmediatePropagation();zoom(target,Math.pow(event.key==="-"||event.key==="_"?1/1.1:1.1,event.altKey?.1:1));changed();return;}if(!["ArrowLeft","ArrowRight","ArrowUp","ArrowDown"].includes(event.key))return;event.preventDefault();event.stopImmediatePropagation();const step=(event.shiftKey?20:4)/(target==="transform"?state.viewport.scale:1),key=event.key==="ArrowLeft"||event.key==="ArrowRight"?"x":"y",sign=event.key==="ArrowLeft"||event.key==="ArrowUp"?-1:1;state[target][key]=clamp(state[target][key]+step*sign,-1e7,1e7);render();changed();},true);
    get("fit").onclick=fit;get("smaller").onclick=e=>{zoom("viewport",Math.pow(1/1.1,e.altKey?.1:1));changed();};get("larger").onclick=e=>{zoom("viewport",Math.pow(1.1,e.altKey?.1:1));changed();};
    get("theme").onclick=()=>{state.theme=state.theme==="white"?"dark":"white";theme();render();changed();};get("export").onclick=()=>downloadSVG(svg,{theme:state.theme,filename:options.exportName||"wing-view.svg"});
    get("help").onclick=()=>{help.hidden=!help.hidden;get("help").setAttribute("aria-expanded",String(!help.hidden));};get("reset").onclick=()=>resetImage();get("remove").onclick=()=>{stop(true);state.image=null;state.transform={x:0,y:0,scale:1};error.hidden=true;render();changed();};
    get("scale").onchange=()=>{const value=Number(get("scale").value);if(state.image&&Number.isFinite(value)&&value>0){zoom("transform",value/100*fitScale()/state.transform.scale);changed();}else render();};get("opacity").oninput=()=>{state.opacity=Number(get("opacity").value);render();};get("opacity").onchange=changed;
    get("upload").onclick=()=>get("file").click();
    get("file").onchange=async()=>{const file=get("file").files?.[0];if(!file)return;const token=++loadToken;loading=true;error.hidden=true;stop(true);render();try{
      if(!["image/png","image/jpeg","image/webp"].includes(file.type))throw new Error("Choose a PNG, JPEG or WebP image.");if(file.size>MAX_IMAGE_BYTES)throw new Error("Background images must be no larger than 8 MiB.");
      const dataUrl=await new Promise((resolve,reject)=>{const reader=new win.FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error("The image file could not be read."));reader.readAsDataURL(file);});
      if(destroyed||token!==loadToken)return;
      const size=await new Promise((resolve,reject)=>{const img=new win.Image();img.onload=()=>resolve({width:img.naturalWidth,height:img.naturalHeight});img.onerror=()=>reject(new Error("The image could not be decoded."));img.src=dataUrl;});if(destroyed||token!==loadToken)return;
      state=validateState({...state,image:{name:file.name,dataUrl,...size}});resetImage(false);changed();
    }catch(e){if(!destroyed&&token===loadToken){error.textContent=e.message;error.hidden=false;}}finally{if(!destroyed&&token===loadToken){loading=false;get("file").value="";render();}}};
    const observer=typeof win.ResizeObserver==="function"?new win.ResizeObserver(()=>{screenPresentation();drawingTools?.render();}):null;observer?.observe(svg);
    const api={refresh,toDrawingPoint,capture,setMetric(value){drawingTools.setMetric(value);Object.assign(state,drawingTools.capture());},isMeasuring:()=>drawingTools.isMeasuring(),restore(value){const next=validateState(value);stop(true);loadToken++;loading=false;win.clearTimeout(wheelTimer);get("file").value="";state=next;drawingTools.restore(copyTools(next),{defaultSpacing:value?.grid===undefined});Object.assign(state,drawingTools.capture());notifiedState=copyState(next);error.hidden=true;theme();render();},fit,exportSVG(){return serializeSVG(svg,{theme:state.theme});},download(){return downloadSVG(svg,{theme:state.theme,filename:options.exportName||"wing-view.svg"});},destroy({forget=false}={}){if(destroyed)return;if(key){if(forget)delete savedStates[key];else savedStates[key]=capture();if(controllers.get(key)===api)controllers.delete(key);}registrations.delete(api);drawingTools.destroy();destroyed=true;loadToken++;win.clearTimeout(wheelTimer);observer?.disconnect();for(const remove of listeners)remove();toolbar.remove();help.remove();error.remove();for(const r of styleRecords)for(const field of ["fill","stroke"]){if(r[field])r.element.style.setProperty(field,r[field],r[field+"Priority"]);else r.element.style.removeProperty(field);}for(const element of geometry.querySelectorAll("*")){const prior=presentationRecords.get(element);if(prior){for(const attr of ["transform","r","markerWidth","markerHeight"]){if(prior[attr]===null)element.removeAttribute(attr);else element.setAttribute(attr,prior[attr]);}if(prior.vectorEffect===null)element.removeAttribute("vector-effect");else element.setAttribute("vector-effect",prior.vectorEffect);if(prior.strokeWidth)element.style.setProperty("stroke-width",prior.strokeWidth);else element.style.removeProperty("stroke-width");}}if(scene?.parentNode===svg){for(const child of Array.from(geometry.childNodes))svg.insertBefore(child,scene);scene.remove();background.remove();}host.classList.remove("svgv-host");delete host.dataset.svgvTheme;svg.classList.remove("svgv-canvas","svgv-panning","svgv-image-only");svg.style.removeProperty("background-color");delete svg.__wingSVGViewport;delete svg.wingViewport;},toolbar};
    registrations.set(api,{getKey:()=>key,setKey(value){key=value;svg.dataset.viewKey=value;}});svg.__wingSVGViewport=api;svg.wingViewport=api;if(key){controllers.get(key)?.destroy();controllers.set(key,api);if(savedStates[key])state=validateState(savedStates[key]);}if(options.metric?.gridSpacing&&!savedStates[key])state.grid.spacing=options.metric.gridSpacing;drawingTools.restore(copyTools(state),{defaultSpacing:!savedStates[key]});Object.assign(state,drawingTools.capture());notifiedState=copyState(state);refresh();return api;
  }
  // Reassign dynamic view identities together so swapping two sections cannot
  // destroy a controller or read another section's cached image midway through.
  function rekeyAll(entries){
    if(!Array.isArray(entries))throw new Error("Drawing key changes must be an array.");
    const destinations=new Set(),sources=new Set(),moving=new Set(entries.map(e=>e.controller).filter(Boolean));
    const changes=entries.map(entry=>{
      const registration=entry.controller&&registrations.get(entry.controller);
      if(entry.controller&&!registration)throw new Error("Cannot rename a destroyed drawing controller.");
      const from=registration?registration.getKey():entry.from,key=entry.key;
      if(typeof key!=="string"||!key||destinations.has(key)||from&&sources.has(from))throw new Error("Drawing keys must be distinct non-empty strings.");
      destinations.add(key);if(from)sources.add(from);
      const occupant=controllers.get(key);if(occupant&&!moving.has(occupant))throw new Error("Drawing key is already in use: "+key);
      if(!entry.controller&&controllers.has(from))throw new Error("Cannot move a cached drawing while its controller is active.");
      return{from,key,controller:entry.controller,registration,value:entry.controller?entry.controller.capture():entry.state?validateState(entry.state):savedStates[from]?copyState(savedStates[from]):defaults()};
    });
    if(changes.every(change=>change.from===change.key))return;
    for(const {from,controller}of changes)if(from){if(!controller||controllers.get(from)===controller)controllers.delete(from);delete savedStates[from];}
    for(const {key,controller,registration,value}of changes){savedStates[key]=copyState(value);if(controller){registration.setKey(key);controllers.set(key,controller);}}
  }
  function forget(key){if(controllers.has(key))throw new Error("Destroy the drawing before forgetting its saved state.");delete savedStates[key];}
  // Images are validated when loaded, not rescanned on each Study dirty check.
  function captureAll(){const result=Object.fromEntries(Object.entries(savedStates).map(([key,value])=>[key,copyState(value)]));for(const [key,controller]of controllers)result[key]=controller.capture();return result;}
  function restoreAll(values={}){if(!object(values))throw new Error("2D drawing settings must be an object.");const next=Object.fromEntries(Object.entries(values).map(([key,value])=>[key,validateState(value)]));savedStates=next;for(const [key,controller]of controllers)controller.restore(next[key]||null);}
  function destroyAll(){for(const controller of Array.from(controllers.values()))controller.destroy();}
  return{defaults,defaultsTools,validateToolsState,metricMapping,measurementValue,nearestSnap,linearPathGeometry,createTools,validateState,install,serializeSVG,downloadSVG,captureAll,restoreAll,destroyAll,rekeyAll,forget,MAX_IMAGE_BYTES};
});
