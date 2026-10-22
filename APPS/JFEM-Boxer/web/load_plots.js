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
  const THEMES={dark:{background:'#111c27',text:'#e0eaf2',muted:'#a6bbcd',grid:'#26394a',zero:'#72899a',cursor:'#d8e5ef',colors:{aerodynamic:'#6ebdff',structure:'#f7bd66',fuel:'#c7a0ff',total:'#63ddb1',elliptical:'#ffd276'}},light:{background:'#ffffff',text:'#20384d',muted:'#415b70',grid:'#dce5ec',zero:'#718394',cursor:'#263f54',colors:{aerodynamic:'#0969b4',structure:'#a95b00',fuel:'#7b3fb0',total:'#00785b',elliptical:'#a95b00'}}};
  const plotHeight=width=>Math.round(Math.max(340,Math.min(520,width*.43)));
  const MAX_GRID_LINES=400;
  function verticalGridLines(xmin,xmax,requested=null){
    if(!Number.isFinite(xmin)||!Number.isFinite(xmax)||xmax<=xmin)return {values:[],spacing:null,limited:false};
    const span=xmax-xmin,raw=span/8,power=10**Math.floor(Math.log10(raw));
    const automatic=[1,2,5,10].map(n=>n*power).find(n=>n>=raw)||power*10;
    const spacing=requested===null?automatic:requested;
    if(!Number.isFinite(spacing)||spacing<=0)throw new Error('Grid spacing must be a positive finite distance in metres.');
    const tolerance=1e-10,first=Math.ceil(xmin/spacing-tolerance),last=Math.floor(xmax/spacing+tolerance),count=last-first+1;
    const limited=count>MAX_GRID_LINES||!Number.isSafeInteger(first)||!Number.isSafeInteger(last);
    return {spacing,limited,minimumSpacing:span/(MAX_GRID_LINES-1),values:limited?[]:Array.from({length:Math.max(0,count)},(_,i)=>{const x=(first+i)*spacing;return Object.is(x,-0)?0:x;})};
  }
  function validateState(value){
    if(value==null)return {mode:"distributed",visible:COMPONENTS.map(c=>c.key),theme:"dark",verticalGrid:true,gridSpacing:null};
    if(typeof value!=="object"||Array.isArray(value)||Object.keys(value).some(key=>!['mode','visible','theme','verticalGrid','gridSpacing'].includes(key))||!['distributed','fe'].includes(value.mode)||!Array.isArray(value.visible)||value.visible.some(key=>!COMPONENTS.some(c=>c.key===key))||new Set(value.visible).size!==value.visible.length||value.theme!==undefined&&!Object.hasOwn(THEMES,value.theme)||value.verticalGrid!==undefined&&typeof value.verticalGrid!=='boolean'||value.gridSpacing!==undefined&&value.gridSpacing!==null&&(!Number.isFinite(value.gridSpacing)||value.gridSpacing<=0))throw new Error("Invalid load-plot display settings.");
    return {mode:value.mode,visible:COMPONENTS.filter(c=>value.visible.includes(c.key)).map(c=>c.key),theme:value.theme||"dark",verticalGrid:value.verticalGrid??true,gridSpacing:value.gridSpacing??null};
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
    let cases=[],active=1,dirty=false,lastWidth=0,mode="distributed",theme="dark",visible=new Set(COMPONENTS.map(c=>c.key)),verticalGrid=true,gridSpacing=null;
    function aerodynamicPerformance(summary,data) {
      const box=element("div","plot-aero-performance");
      const solved=summary?.method==="vortex_lattice",ar=solved?(summary.aspect_ratio??((2*data.semispan_m)**2/summary.reference_area_m2)):null;
      const cl=solved?summary.CL:null,cdi=solved?summary.CDi:null;
      const efficiency=solved?(summary.span_efficiency??(Number.isFinite(cl)&&Number.isFinite(cdi)&&cdi>0&&Number.isFinite(ar)&&ar>0?cl*cl/(Math.PI*ar*cdi):null)):null;
      for(const [key,label,value]of[["span-efficiency","Oswald / span efficiency e (inviscid)",efficiency],["induced-drag","Induced drag Cᴅᵢ",cdi],["lift-coefficient","Lift Cₗ",cl],["aspect-ratio","Aspect ratio AR",ar]]){
        const item=element("div","plot-aero-metric"),term=element("span","",label),number=element("strong","",Number.isFinite(value)?format(value):"Unavailable");number.dataset.metric=key;number.dataset.value=Number.isFinite(value)?String(value):"";item.append(term,number);box.appendChild(item);
      }
      const note=solved?"Selected aerodynamic case · full-span coefficients before the structural load multiplier. Inviscid e is not the viscous Oswald factor; profile drag is not modeled.":"Prescribed lift has no aerodynamic wake solution: induced drag and span efficiency are unavailable. The equal-lift ellipse remains a geometric comparison.";
      box.appendChild(element("p","plot-explanation",note));return box;
    }
    function exportSVG(data,spec,summary,caseLabel) {
      // Rebuild at a publication-friendly vector width, independent of a
      // narrow options pane. The exported diagram carries its own styles.
      const card=plot(data,spec,988,summary,{exporting:true}),graph=card.querySelector('svg');if(!graph)return null;
      const palette=THEMES[theme],width=1000,pad=20,svg=svgElement('svg',{xmlns:'http://www.w3.org/2000/svg',width,role:'img','aria-label':spec.title+' — '+caseLabel});
      svg.append(svgElement('title',{},spec.title+' · '+spec.symbol+' ['+spec.unit+']'),svgElement('desc',{},'Selected load case: '+caseLabel+'. '+(dirty?'Parameters changed; data belong to the last created mesh.':'Current generated load distribution.')));
      const background=svgElement('rect',{width:'100%',height:'100%',fill:palette.background});svg.append(background);
      svg.append(svgElement('style',{},`text{font-family:Arial,Helvetica,sans-serif;fill:${palette.text}}.plot-tick{fill:${palette.muted};font-size:11px}.plot-grid{stroke:${palette.grid};stroke-width:1}.plot-zero{stroke:${palette.zero};stroke-width:1}`));
      let y=30;
      function paragraph(text,size=12,color=palette.muted){if(!text)return;const limit=Math.floor((width-2*pad)/(size*.6)),words=String(text).trim().split(/\s+/),lines=[];let line='';for(const word of words){if(line&&line.length+word.length+1>limit){lines.push(line);line=word;}else line+=(line?' ':'')+word;}if(line)lines.push(line);for(const value of lines){svg.append(svgElement('text',{x:pad,y,'font-size':size,fill:color,style:'fill:'+color},value));y+=size*1.5;}y+=6;}
      paragraph(spec.title+' · '+spec.symbol+' ['+spec.unit+']',20,palette.text);
      paragraph('Load case '+caseLabel+(spec.source==='resultants'?' · '+(mode==='fe'?'Exact FE point loads':'Distributed sources'):''),13);
      if(dirty)paragraph('Parameters changed — these graphs belong to the last created mesh.',12,theme==='light'?'#995000':'#ffbe71');
      const gridNote=card.querySelector('.plot-grid-warning');if(gridNote)paragraph(gridNote.textContent,12,theme==='light'?'#995000':'#ffbe71');
      const graphHeight=Number(graph.getAttribute('height'));graph.setAttribute('x',pad);graph.setAttribute('y',y);graph.setAttribute('width',width-2*pad);graph.querySelectorAll('.plot-interaction').forEach(e=>e.remove());svg.append(graph);y+=graphHeight+25;
      let lx=pad;for(const line of graph.querySelectorAll('.plot-series')){const label=line.querySelector('title')?.textContent||line.dataset.component,span=44+label.length*8;if(lx+span>width-pad){lx=pad;y+=24;}svg.append(svgElement('line',{x1:lx,y1:y-4,x2:lx+28,y2:y-4,stroke:line.getAttribute('stroke'),'stroke-width':line.getAttribute('stroke-width'),...(line.hasAttribute('stroke-dasharray')?{'stroke-dasharray':line.getAttribute('stroke-dasharray')}:{})}),svgElement('text',{x:lx+35,y,'font-size':12},label));lx+=span+22;}y+=26;
      if(spec.source==='distribution'){paragraph([...card.querySelectorAll('.plot-aero-metric')].map(e=>e.firstElementChild.textContent+' = '+e.lastElementChild.textContent).join(' · '),13,palette.text);}
      const notes=spec.source==='distribution'?[card.querySelector('.plot-aero-performance .plot-explanation')?.textContent,data.distribution?.note,data.distribution?.elliptical_note,summary?.span_efficiency_note]:[mode==='fe'?'Exact deck point loads: jumps occur at the FE application nodes.':'Distributed aerodynamic and inertia sources integrated along the span.',data.reference_note,data.sign_note,data.resultant_note];
      for(const note of new Set(notes.filter(Boolean)))paragraph(note);
      svg.setAttribute('height',Math.ceil(y+pad));svg.setAttribute('viewBox',`0 0 ${width} ${Math.ceil(y+pad)}`);
      return '<?xml version="1.0" encoding="UTF-8"?>\n'+new doc.defaultView.XMLSerializer().serializeToString(svg)+'\n';
    }
    function plot(data,spec,width,summary,{exporting=false,caseLabel=''}={}) {
      const card=element("section","span-plot");card.dataset.quantity=spec.key;
      const heading=element('div','plot-heading');heading.appendChild(element("h3","",spec.title+" · "+spec.symbol+" ["+spec.unit+"]"));card.append(heading);
      const curves=spec.source==="distribution"?[{key:"aerodynamic",label:spec.symbol,color:spec.color,points:samples(data,spec)},
        {key:"elliptical",label:"Equal-lift ellipse",color:"#ffd276",dashed:true,points:samples(data,{...spec,key:"elliptical_cl_chord_m"})}].filter(c=>c.points.length):
        COMPONENTS.filter(c=>visible.has(c.key)).map(c=>({...c,points:samples(data,spec,c.key,mode)})).filter(c=>c.points.length);
      const palette=THEMES[theme];for(const c of curves)c.color=palette.colors[c.key]||c.color;const points=curves.flatMap(c=>c.points);
      if(!points.length) {card.appendChild(element("p","pick-note",spec.source==="resultants"&&!visible.size?"Select at least one resultant curve above.":"This quantity is unavailable for this load case."));return card;}
      if(!exporting){const button=element('button','mini plot-export','Export SVG');button.type='button';button.setAttribute('aria-label','Export '+spec.title+' as SVG');button.title='Save this graph with its selected case, visible curves, units, legend and definitions. Uses the current light or dark theme.';button.onclick=()=>{const text=exportSVG(data,spec,summary,caseLabel);if(!text)return;const url=doc.defaultView.URL.createObjectURL(new Blob([text],{type:'image/svg+xml;charset=utf-8'})),link=element('a');link.href=url;link.download='load-case-'+String(active).replace(/[^a-z0-9_-]/gi,'_')+'-'+spec.key+'.svg';link.click();setTimeout(()=>doc.defaultView.URL.revokeObjectURL(url),1000);};heading.append(button);}
      const widthPx=Math.max(268,width-28),height=plotHeight(width),left=65,right=16,top=15,bottom=40;
      const b=bounds(points),sx=x=>left+(x-b.xmin)/(b.xmax-b.xmin)*(widthPx-left-right),sy=y=>height-bottom-(y-b.ymin)/(b.ymax-b.ymin)*(height-top-bottom);
      const svg=svgElement("svg",{viewBox:`0 0 ${widthPx} ${height}`,width:"100%",height,role:"img","aria-label":spec.title+" versus span y in metres"});
      svg.appendChild(svgElement("title",{},spec.title+" ["+spec.unit+"]"));
      if(verticalGrid){
        const grid=verticalGridLines(b.xmin,b.xmax,gridSpacing);
        if(grid.limited)card.appendChild(element('p','plot-grid-warning','Vertical grid hidden: this spacing exceeds the '+MAX_GRID_LINES+'-line limit. Increase spacing to at least '+format(grid.minimumSpacing)+' m or clear it for Auto.'));
        for(const x of grid.values)svg.appendChild(svgElement('line',{x1:sx(x),x2:sx(x),y1:top,y2:height-bottom,class:'plot-grid plot-grid-vertical','data-y-m':x}));
      }
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
        const line=svgElement("path",{d:path,fill:"none",stroke:curve.color,"stroke-width":curve.key==="total"?2.8:1.6,"vector-effect":"non-scaling-stroke",class:"plot-series","data-component":curve.key,...(curve.dashed?{"stroke-dasharray":"6 4"}:{})});
        line.appendChild(svgElement("title",{},curve.label));svg.appendChild(line);
      }
      const cursor=svgElement("line",{x1:0,x2:0,y1:top,y2:height-bottom,stroke:palette.cursor,"stroke-dasharray":"3 3",visibility:"hidden",class:'plot-interaction'});svg.appendChild(cursor);
      const dot=svgElement("circle",{cx:0,cy:0,r:4,fill:palette.cursor,visibility:"hidden",class:'plot-interaction'});svg.appendChild(dot);
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
      card.append(svg,readout);
      if(spec.source==="distribution"){
        const legend=element("div","plot-curve-legend");for(const curve of curves){const item=element("span"),swatch=element("span","plot-legend-line");swatch.style.borderTopColor=curve.color;if(curve.dashed)swatch.style.borderTopStyle="dashed";item.append(swatch,doc.createTextNode(curve.label));legend.appendChild(item);}card.appendChild(legend);
        card.appendChild(aerodynamicPerformance(summary,data));
      }
      return card;
    }
    function render() {
      const width=host.clientWidth || 330;lastWidth=width;host.replaceChildren();host.dataset.plotTheme=theme;host.classList.add('load-plots');
      const toolbar=element('div','plot-toolbar'),themeButton=element('button','mini',theme==='dark'?'Light mode':'Dark mode');themeButton.type='button';themeButton.id='plots-theme-toggle';themeButton.setAttribute('aria-pressed',String(theme==='light'));themeButton.title='Change the plot and exported SVG backgrounds; keeps the model viewport theme unchanged.';themeButton.onclick=()=>{theme=theme==='dark'?'light':'dark';render();onChange();};toolbar.append(themeButton);host.append(toolbar);
      const label=element("label","case-picker-label","Displayed load case");label.htmlFor="plots-case-select";
      const select=element("select");select.id="plots-case-select";select.setAttribute("aria-label","Load plots case");
      for(const c of cases){const option=element("option","",c.id+" · "+c.label);option.value=c.id;select.appendChild(option);}
      select.value=String(active);select.disabled=cases.length<2;select.onchange=()=>onCase(Number(select.value));host.append(label,select);
      const current=cases.find(c=>Number(c.id)===Number(active)),data=current?.loads?.spanwise;
      if(!data){host.appendChild(element("p","pick-note",current?.loads?.method==="imported" ? "Lifting surface spanwise load plots do not apply to imported decks. The viewport shows native equivalent nodal loads; the original load cards and subcase selections remain authoritative." : "Create the model to plot its load distributions. A supported load case with RBE3 stations is required."));return;}
      const status=element("p",dirty?"plot-status stale":"plot-status",dirty?"Parameters changed — these graphs belong to the last created mesh.":"Applied loads · "+current.label);status.setAttribute("role","status");host.appendChild(status);
      const gridTools=element('div','plot-grid-controls'),gridLabel=element('label','plot-grid-toggle'),gridCheck=element('input');gridCheck.type='checkbox';gridCheck.id='plots-vertical-grid';gridCheck.checked=verticalGrid;gridCheck.onchange=()=>{verticalGrid=gridCheck.checked;render();onChange();};gridLabel.append(gridCheck,doc.createTextNode('Vertical grid'));
      const spacingLabel=element('label','plot-grid-spacing','Spacing (m)'),spacingInput=element('input');spacingInput.type='number';spacingInput.id='plots-grid-spacing';spacingInput.step='any';spacingInput.min='0';spacingInput.placeholder='Auto';spacingInput.value=gridSpacing===null?'':String(gridSpacing);spacingInput.disabled=!verticalGrid;spacingInput.setAttribute('aria-label','Vertical grid spacing in meters');spacingInput.title='Positive spacing along global span y, in meters; grid lines are multiples of this distance from y = 0. Leave blank for automatic spacing. At most '+MAX_GRID_LINES+' lines are drawn per graph.';
      const spacingError=element('span','plot-grid-error');spacingError.setAttribute('role','status');
      spacingInput.oninput=()=>{spacingInput.setCustomValidity('');spacingError.textContent='';};
      spacingInput.onchange=()=>{const text=spacingInput.value.trim(),next=text===''?null:Number(text);if(spacingInput.validity.badInput||next!==null&&(!Number.isFinite(next)||next<=0)){const message='Enter a positive spacing in meters, or leave blank for Auto.';spacingInput.setCustomValidity(message);spacingError.textContent=message;spacingInput.reportValidity();return;}gridSpacing=next;render();onChange();};
      spacingLabel.append(spacingInput);gridTools.append(gridLabel,spacingLabel,spacingError);host.append(gridTools);
      if(data.components){
        const tools=element("fieldset","plot-controls"),legend=element("legend","","Resultant curves");tools.appendChild(legend);
        const label=element("label","plot-mode-label","Load representation"),view=element("select");view.id="plots-representation";
        for(const [value,text]of[["distributed","Distributed sources"],["fe","Exact FE point loads"]]){const option=element("option","",text);option.value=value;view.appendChild(option);}
        view.value=mode;view.onchange=()=>{mode=view.value;render();onChange();};label.appendChild(view);tools.appendChild(label);
        const toggles=element("div","plot-component-toggles");
        for(const component of COMPONENTS){const item=element("label","plot-component"),check=element("input");check.type="checkbox";check.checked=visible.has(component.key);check.dataset.component=component.key;check.setAttribute("aria-label",component.label+" curve");
          check.onchange=()=>{if(check.checked)visible.add(component.key);else visible.delete(component.key);render();onChange();};
          const swatch=element("span","plot-swatch");swatch.style.background=THEMES[theme].colors[component.key];item.append(check,swatch,doc.createTextNode(component.label));toggles.appendChild(item);}
        tools.appendChild(toggles);host.appendChild(tools);
        host.appendChild(element("p","plot-explanation",mode==="fe"?"Exact deck application: separate upward aerodynamic and downward inertia loads create real steps at their FE nodes. These steps depend on the load transfer mesh.":"Distributed sources: panel loads, filled fuel volumes and structural element masses are integrated along the span. Root forces and moments match the deck; concentrated rib loads keep their jumps."));
        if(!data.structure_inertia)host.appendChild(element("p","plot-explanation","Structural inertia is disabled for this case. Enable Include structural inertia in Cases to apply the shared acceleration to the dry structure."));
      }
      const stack=element("div","span-plot-stack");for(const spec of SPECS)stack.appendChild(plot(data,spec,width,current?.loads?.summary,{caseLabel:current.id+' · '+current.label}));host.appendChild(stack);
      const notes=element("details","plot-notes");notes.appendChild(element("summary","","Definitions, axes and signs"));
      for(const text of [data.distribution?.note,data.distribution?.elliptical_note,current?.loads?.summary?.span_efficiency_note,data.reference_note,data.sign_note,data.resultant_note,data.structure_inertia_migration_note])if(text)notes.appendChild(element("p","pick-note",text));
      host.appendChild(notes);
    }
    const Observer=doc.defaultView?.ResizeObserver;
    const observer=Observer?new Observer(()=>{if(Math.abs(host.clientWidth-lastWidth)>2)render();}):null;
    observer?.observe(host);
    return {update(next,id,stale){cases=next||[];active=id;dirty=!!stale;render();},
      capture(){return {mode,visible:COMPONENTS.filter(c=>visible.has(c.key)).map(c=>c.key),theme,verticalGrid,gridSpacing};},
      restore(value){const next=validateState(value);mode=next.mode;visible=new Set(next.visible);theme=next.theme;verticalGrid=next.verticalGrid;gridSpacing=next.gridSpacing;render();},
      dispose(){observer?.disconnect();host.replaceChildren();host.classList.remove('load-plots');delete host.dataset.plotTheme;}};
  }
  return {SPECS,COMPONENTS,THEMES,plotHeight,verticalGridLines,MAX_GRID_LINES,samples,bounds,format,create,validateState};
});
