/* Spanwise engineering plots. Values and equilibrium come from the generator;
 * this module only displays samples, including repeated cut positions. */
(function (root, factory) {
  const api = factory(root,typeof module === "object" && module.exports ? require("./numbers.js") : null);
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingLoadPlots = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function (root,numbers) {
  "use strict";
  const SPECS = [
    {key:"cl_chord_m",source:"distribution",title:"Section lift coefficient × chord",symbol:"cₗ c",unit:"m",color:"#6ebdff"},
    {key:"shear_z_N",source:"resultants",title:"Vertical shear",symbol:"V_z",unit:"N",color:"#63ddb1"},
    {key:"bending_x_Nm",source:"resultants",title:"Bending moment",symbol:"M_x",unit:"N·m",color:"#f7bd66"},
    {key:"torque_y_Nm",source:"resultants",title:"Torque",symbol:"M_y",unit:"N·m",color:"#c7a0ff"},
  ];
  const COMPONENTS=[
    {key:"aerodynamic",label:"Aerodynamic",color:"#6ebdff"},
    {key:"structure",label:"Structural inertia",color:"#f7bd66"},
    {key:"fuel",label:"Fuel inertia",color:"#c7a0ff"},
    {key:"total",label:"Total",color:"#63ddb1"},
  ];
  function validateState(value){
    if(value==null)return {mode:"distributed",visible:COMPONENTS.map(c=>c.key)};
    if(typeof value!=="object"||Array.isArray(value)||Object.keys(value).some(key=>!['mode','visible'].includes(key))||!['distributed','fe'].includes(value.mode)||!Array.isArray(value.visible)||value.visible.some(key=>!COMPONENTS.some(c=>c.key===key))||new Set(value.visible).size!==value.visible.length)throw new Error("Invalid load-plot display settings.");
    return {mode:value.mode,visible:COMPONENTS.filter(c=>value.visible.includes(c.key)).map(c=>c.key)};
  }
  function samples(data,spec,component="total",mode="distributed") {
    const source=spec.source==="resultants"?(mode==="fe"?data?.fe_resultants?.[component]:data?.components?.[component])??(component==="total"?data?.resultants:null):data?.[spec.source];
    if (!source || !source.y_m || !source[spec.key]) return [];
    const points = Array.from(source.y_m,(x,i)=>({x:Number(x),y:source[spec.key][i],eta:source.eta?.[i],side:source.side?.[i] || ""}))
      .filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y));
    if (spec.source === "distribution" && source.strip_width_m?.length === points.length)
      return points.flatMap((p,i)=>[{...p,x:p.x-source.strip_width_m[i]/2},{...p,x:p.x+source.strip_width_m[i]/2}]);
    return points;
  }
  function bounds(points) {
    let lo=0,hi=0,xmin=Infinity,xmax=-Infinity;
    for (const p of points) { lo=Math.min(lo,p.y);hi=Math.max(hi,p.y);xmin=Math.min(xmin,p.x);xmax=Math.max(xmax,p.x); }
    if(!Number.isFinite(xmin)){xmin=0;xmax=1;}else if(xmax===xmin)xmax=xmin+1;
    const pad=(hi-lo || Math.abs(hi) || 1)*.08;
    return {xmin,xmax,ymin:lo-pad,ymax:hi+pad};
  }
  const format=x=>(numbers||root.WingNumbers)?.format(x,4)??root.eng(x,4);
  function create(host,onCase,onChange=()=>{}) {
    const doc=host.ownerDocument;
    const element=(tag,cls,text)=>{const e=doc.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const svgElement=(tag,attrs,text)=>{const e=doc.createElementNS("http://www.w3.org/2000/svg",tag);for(const [k,v] of Object.entries(attrs||{}))e.setAttribute(k,String(v));if(text!==undefined)e.textContent=text;return e;};
    let cases=[],active=1,dirty=false,lastWidth=0,mode="distributed",visible=new Set(COMPONENTS.map(c=>c.key));
    function plot(data,spec,width) {
      const card=element("section","span-plot");card.dataset.quantity=spec.key;
      card.appendChild(element("h3","",spec.title+" · "+spec.symbol+" ["+spec.unit+"]"));
      const curves=spec.source==="distribution"?[{key:"aerodynamic",label:spec.symbol,color:spec.color,points:samples(data,spec)}]:
        COMPONENTS.filter(c=>visible.has(c.key)).map(c=>({...c,points:samples(data,spec,c.key,mode)})).filter(c=>c.points.length);
      const points=curves.flatMap(c=>c.points);
      if(!points.length) {card.appendChild(element("p","pick-note",spec.source==="resultants"&&!visible.size?"Select at least one resultant curve above.":"This quantity is unavailable for this load case."));return card;}
      const widthPx=Math.max(268,width-28),height=218,left=65,right=16,top=15,bottom=40;
      const b=bounds(points),sx=x=>left+(x-b.xmin)/(b.xmax-b.xmin)*(widthPx-left-right),sy=y=>height-bottom-(y-b.ymin)/(b.ymax-b.ymin)*(height-top-bottom);
      const svg=svgElement("svg",{viewBox:`0 0 ${widthPx} ${height}`,width:"100%",height,role:"img","aria-label":spec.title+" versus span y in metres"});
      svg.appendChild(svgElement("title",{},spec.title+" ["+spec.unit+"]"));
      for(let k=0;k<5;k++) {
        const y=b.ymin+(b.ymax-b.ymin)*k/4,x=b.xmin+(b.xmax-b.xmin)*k/4;
        svg.appendChild(svgElement("line",{x1:left,y1:sy(y),x2:widthPx-right,y2:sy(y),class:"plot-grid"}));
        svg.appendChild(svgElement("text",{x:left-8,y:sy(y)+4,"text-anchor":"end",class:"plot-tick"},format(y)));
        svg.appendChild(svgElement("text",{x:sx(x),y:height-bottom+19,"text-anchor":"middle",class:"plot-tick"},format(x)));
      }
      svg.appendChild(svgElement("line",{x1:left,y1:sy(0),x2:widthPx-right,y2:sy(0),class:"plot-zero"}));
      svg.appendChild(svgElement("text",{x:(left+widthPx-right)/2,y:height-3,"text-anchor":"middle",class:"plot-tick"},"Global y [m] · root → tip"));
      if(Number.isFinite(data.box_end_eta)&&data.box_end_eta<1&&Number.isFinite(data.semispan_m)){
        const end=(data.root_ref_y_m||0)+data.box_end_eta*data.semispan_m;
        if(end>=b.xmin&&end<=b.xmax){
          const marker=svgElement("line",{x1:sx(end),x2:sx(end),y1:top,y2:height-bottom,stroke:"#8997a8","stroke-dasharray":"4 4",class:"plot-box-end"});
          marker.appendChild(svgElement("title",{},"Final structural rib · y = "+format(end)+" m"));svg.appendChild(marker);
        }
      }
      for(const curve of curves){
        const path=curve.points.map((p,i)=>(i?"L":"M")+sx(p.x).toFixed(3)+","+sy(p.y).toFixed(3)).join(" ");
        const line=svgElement("path",{d:path,fill:"none",stroke:curve.color,"stroke-width":curve.key==="total"?2.8:1.6,"vector-effect":"non-scaling-stroke",class:"plot-series","data-component":curve.key});
        line.appendChild(svgElement("title",{},curve.label));svg.appendChild(line);
      }
      const cursor=svgElement("line",{x1:0,x2:0,y1:top,y2:height-bottom,stroke:"#d8e5ef","stroke-dasharray":"3 3",visibility:"hidden"});svg.appendChild(cursor);
      const dot=svgElement("circle",{cx:0,cy:0,r:4,fill:"#d8e5ef",visibility:"hidden"});svg.appendChild(dot);
      const readout=element("p","plot-readout","Move over the graph to read values.");
      svg.addEventListener("pointermove",event=>{
        const rect=svg.getBoundingClientRect(),px=(event.clientX-rect.left)*widthPx/rect.width,py=(event.clientY-rect.top)*height/rect.height;
        let nearest=points[0],distance=Infinity;
        for(const p of points) {const d=Math.abs(sx(p.x)-px)+.02*Math.abs(sy(p.y)-py);if(d<distance){nearest=p;distance=d;}}
        cursor.setAttribute("x1",sx(nearest.x));cursor.setAttribute("x2",sx(nearest.x));cursor.setAttribute("visibility","visible");
        dot.setAttribute("cx",sx(nearest.x));dot.setAttribute("cy",sy(nearest.y));dot.setAttribute("visibility","visible");
        const values=curves.map(c=>{const match=c.points.find(p=>p.x===nearest.x&&p.side===nearest.side);return match?c.label+" = "+format(match.y)+" "+spec.unit:null;}).filter(Boolean);
        readout.textContent="y = "+format(nearest.x)+" m"+(nearest.side&&nearest.side!=="cut"?" · "+nearest.side:"")+" · "+values.join(" · ");
      });
      svg.addEventListener("pointerleave",()=>{cursor.setAttribute("visibility","hidden");dot.setAttribute("visibility","hidden");});
      card.append(svg,readout);return card;
    }
    function render() {
      const width=host.clientWidth || 330;lastWidth=width;host.replaceChildren();
      const label=element("label","case-picker-label","Displayed load case");label.htmlFor="plots-case-select";
      const select=element("select");select.id="plots-case-select";select.setAttribute("aria-label","Load plots case");
      for(const c of cases){const option=element("option","",c.id+" · "+c.label);option.value=c.id;select.appendChild(option);}
      select.value=String(active);select.disabled=cases.length<2;select.onchange=()=>onCase(Number(select.value));host.append(label,select);
      const current=cases.find(c=>Number(c.id)===Number(active)),data=current?.loads?.spanwise;
      if(!data){host.appendChild(element("p","pick-note",current?.loads?.method==="imported" ? "Wing spanwise load plots do not apply to imported decks. The viewport shows native equivalent nodal loads; the original load cards and subcase selections remain authoritative." : "Create the model to plot its load distributions. A supported load case with RBE3 stations is required."));return;}
      const status=element("p",dirty?"plot-status stale":"plot-status",dirty?"Parameters changed — these graphs belong to the last created mesh.":"Applied loads · "+current.label);status.setAttribute("role","status");host.appendChild(status);
      if(data.components){
        const tools=element("fieldset","plot-controls"),legend=element("legend","","Resultant curves");tools.appendChild(legend);
        const label=element("label","plot-mode-label","Load representation"),view=element("select");view.id="plots-representation";
        for(const [value,text]of[["distributed","Distributed sources"],["fe","Exact FE point loads"]]){const option=element("option","",text);option.value=value;view.appendChild(option);}
        view.value=mode;view.onchange=()=>{mode=view.value;render();onChange();};label.appendChild(view);tools.appendChild(label);
        const toggles=element("div","plot-component-toggles");
        for(const component of COMPONENTS){const item=element("label","plot-component"),check=element("input");check.type="checkbox";check.checked=visible.has(component.key);check.dataset.component=component.key;check.setAttribute("aria-label",component.label+" curve");
          check.onchange=()=>{if(check.checked)visible.add(component.key);else visible.delete(component.key);render();onChange();};
          const swatch=element("span","plot-swatch");swatch.style.background=component.color;item.append(check,swatch,doc.createTextNode(component.label));toggles.appendChild(item);}
        tools.appendChild(toggles);host.appendChild(tools);
        host.appendChild(element("p","plot-explanation",mode==="fe"?"Exact deck application: separate upward aerodynamic and downward inertia loads create real steps at their FE nodes. These steps depend on the load transfer mesh.":"Distributed sources: panel loads, filled fuel volumes and structural element masses are integrated along the span. Root forces and moments match the deck; concentrated rib loads keep their jumps."));
        if(!data.structure_inertia)host.appendChild(element("p","plot-explanation","Structural inertia is disabled for this case. Enable Include structural inertia in Cases to apply the shared acceleration to the dry structure."));
      }
      const stack=element("div","span-plot-stack");for(const spec of SPECS)stack.appendChild(plot(data,spec,width));host.appendChild(stack);
      const notes=element("details","plot-notes");notes.appendChild(element("summary","","Definitions, axes and signs"));
      for(const text of [data.distribution?.note,data.reference_note,data.sign_note,data.resultant_note,data.structure_inertia_migration_note])if(text)notes.appendChild(element("p","pick-note",text));
      host.appendChild(notes);
    }
    const Observer=doc.defaultView?.ResizeObserver;
    const observer=Observer?new Observer(()=>{if(Math.abs(host.clientWidth-lastWidth)>2)render();}):null;
    observer?.observe(host);
    return {update(next,id,stale){cases=next||[];active=id;dirty=!!stale;render();},
      capture(){return {mode,visible:COMPONENTS.filter(c=>visible.has(c.key)).map(c=>c.key)};},
      restore(value){const next=validateState(value);mode=next.mode;visible=new Set(next.visible);render();},
      dispose(){observer?.disconnect();host.replaceChildren();}};
  }
  return {SPECS,COMPONENTS,samples,bounds,format,create,validateState};
});
