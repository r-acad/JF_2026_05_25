/* Dimension editors use the canonical form inputs; there is no second set of
 * parameter values. SVG coordinates share one scale in both directions.
 */
(function(root,factory){const api=factory(root,typeof module==="object"&&module.exports?require("./numbers.js"):null);if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSectionEditor=api;})(typeof globalThis!=="undefined"?globalThis:this,function(root,numbers){
  "use strict";
  const PREFIX="properties.", T_KEYS=["stringer_flange_width","stringer_height","stringer_flange_thickness","stringer_web_thickness"], CAP_KEYS=["spar_cap_side"];
  const NAMES={b:"flange width",h:"overall height",tf:"flange thickness",tw:"web thickness",s:"square side"};
  function section(kind,values){
    const names=kind==="T"?["b","h","tf","tw"]:["s"], errors=[],invalid=[];
    names.forEach((name,i)=>{if(!Number.isFinite(values[i])||values[i]<=0){errors.push("Enter a positive "+NAMES[name]+".");invalid.push(i);}});
    if(!errors.length&&kind==="T"){
      if(values[2]>=values[1]){errors.push("Flange thickness must be smaller than overall height.");invalid.push(1,2);}
      if(values[3]>=values[0]){errors.push("Web thickness must be smaller than flange width.");invalid.push(0,3);}
    }
    if(errors.length)return {valid:false,error:errors.join(" "),invalid};
    if(kind==="T"){
      const [b,h,tf,tw]=values,af=b*tf,aw=(h-tf)*tw,area=af+aw;
      const centroidDepth=(af*tf/2+aw*(tf+(h-tf)/2))/area;
      if(!Number.isFinite(area)||area<=0||!Number.isFinite(centroidDepth))return {valid:false,error:"Dimensions are too large or too small to calculate a finite section.",invalid:[0,1,2,3]};
      return {valid:true,kind,b,h,tf,tw,area,centroidDepth,polygon:[[-b/2,0],[b/2,0],[b/2,tf],[tw/2,tf],[tw/2,h],[-tw/2,h],[-tw/2,tf],[-b/2,tf]]};
    }
    const s=values[0];if(!Number.isFinite(s*s)||s*s<=0)return {valid:false,error:"Side length is too large or too small to calculate a finite area.",invalid:[0]};
    return {valid:true,kind:"BAR",b:s,h:s,area:s*s,centroidDepth:s/2,polygon:[[-s/2,0],[s/2,0],[s/2,s],[-s/2,s]]};
  }
  const number=value=>(numbers||root.WingNumbers)?.format(value,5)??root.eng(value,5);
  function drawing(s,id){
    if(!s.valid)return "";
    const scale=Math.min(180/s.b,156/s.h),cx=156,top=64,left=cx-s.b*scale/2,right=cx+s.b*scale/2,bottom=top+s.h*scale;
    const text=(x,y,value,extra="")=>`<text x="${x}" y="${y}" ${extra}>${value}</text>`;
    const line=(x1,y1,x2,y2,cls="")=>`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="${cls}"/>`;
    const arrow=(x1,y1,x2,y2)=>`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="section-dimension" marker-start="url(#${id}-dim)" marker-end="url(#${id}-dim)"/>`;
    const dim=length=>number(length*1000)+" mm";
    let svg=`<defs><marker id="${id}-dim" markerWidth="5" markerHeight="5" refX="2.5" refY="2.5" orient="auto-start-reverse"><path d="M5 0 L0 2.5 L5 5" fill="none" stroke="currentColor" stroke-width="1"/></marker><marker id="${id}-axis" markerWidth="5" markerHeight="5" refX="4" refY="2.5" orient="auto"><path d="M0 0 L5 2.5 L0 5 Z" fill="context-stroke"/></marker></defs>`;
    svg+=`<polygon data-section-polygon="true" points="${s.polygon.map(([z,d])=>`${cx+z*scale},${top+d*scale}`).join(" ")}" class="section-polygon ${s.kind==="T"?"section-stringer":"section-cap"}"/>`;
    svg+=line(left-10,top,right+13,top,"section-skin")+text(right+15,top+4,"skin","class=\"section-note-label\"");
    svg+=line(left,top-5,left,34,"section-extension")+line(right,top-5,right,34,"section-extension")+arrow(left,40,right,40);
    svg+=text(cx,29,(s.kind==="T"?"b":"s")+" = "+dim(s.b),"text-anchor=\"middle\"");
    svg+=line(left-5,top,left-31,top,"section-extension")+line(left-5,bottom,left-31,bottom,"section-extension")+arrow(left-26,top,left-26,bottom);
    svg+=text(left-37,(top+bottom)/2,(s.kind==="T"?"h":"s")+" = "+dim(s.h),`text-anchor="middle" transform="rotate(-90 ${left-37} ${(top+bottom)/2})"`);
    if(s.kind==="T"){
      const flangeBottom=top+s.tf*scale,wl=cx-s.tw*scale/2,wr=cx+s.tw*scale/2;
      svg+=line(right+3,flangeBottom,right+29,flangeBottom,"section-extension")+arrow(right+24,top,right+24,flangeBottom);
      svg+=text(right+31,top+21,"tf = "+dim(s.tf),"class=\"section-small-label\"");
      svg+=line(wl,bottom+3,wl,bottom+23,"section-extension")+line(wr,bottom+3,wr,bottom+23,"section-extension")+arrow(wl,bottom+17,wr,bottom+17);
      svg+=text(cx,bottom+33,"tw = "+dim(s.tw),"text-anchor=\"middle\"");
    }
    const cy=top+s.centroidDepth*scale;
    svg+=`<circle cx="${cx}" cy="${cy}" r="3.5" class="section-centroid"/>`+text(cx+10,cy+4,"C","class=\"section-centroid-label\"");
    // Right handed local view: +y up, +z right, +x into the page.
    svg+=`<g class="section-triad"><line x1="288" y1="246" x2="288" y2="212" stroke="#4cc38a" marker-end="url(#${id}-axis)"/><line x1="288" y1="246" x2="322" y2="246" stroke="#56a8f5" marker-end="url(#${id}-axis)"/><circle cx="288" cy="246" r="5" fill="none" stroke="#ef5f6b"/><path d="M285 243 L291 249 M285 249 L291 243" stroke="#ef5f6b"/>${text(291,207,"+y")}${text(324,250,"+z")}${text(280,267,"+x into page","text-anchor=\"middle\"")}</g>`;
    return svg;
  }
  function metric(s){const scale=Math.min(180/s.b,156/s.h)/1000;return{origin:{x:156,y:64},x:{x:scale,y:0},y:{x:0,y:scale},unit:"mm",gridSpacing:5};}
  function install(host,options={}){
    if(host.querySelector(".section-editor"))return;
    const doc=host.ownerDocument,viewports={};
    for(const [kind,title,keys,id,viewKey,rib] of (options.definitions || [["T","T stringer",T_KEYS,"stringer-section-editor","stringer-section"],["BAR","Square spar cap",CAP_KEYS,"cap-section-editor","spar-cap-section"]])){
      const rows=keys.map(key=>host.querySelector('[id="row-'+PREFIX+key+'"]'));
      if(rows.some(row=>!row))continue;
      const inputs=rows.map(row=>row.querySelector("input"));
      const card=doc.createElement("section");card.className="section-editor";card.id=id;
      const heading=doc.createElement("h3");heading.textContent=title;
      const type=doc.createElement("span");type.className="section-card-type";type.textContent="PBARL / "+kind;heading.append(type);card.append(heading);
      const canvas=doc.createElement("div");canvas.className="section-preview-canvas";card.append(canvas);
      const svg=doc.createElementNS("http://www.w3.org/2000/svg","svg");svg.setAttribute("viewBox","0 0 360 282");svg.setAttribute("role","img");svg.setAttribute("aria-label",title+" cross section with dimensions, centroid and local axes");svg.classList.add("section-preview");svg.dataset.viewKey=viewKey;canvas.append(svg);
      const viewport=globalThis.WingSVGViewport?.install(svg,{host:canvas,snapSelector:".section-polygon,.section-centroid",title,exportName:svg.dataset.viewKey+".svg",onChange:options.onViewChange});viewports[svg.dataset.viewKey]=viewport;
      const status=doc.createElement("p");status.className="section-editor-status";status.setAttribute("role","status");status.setAttribute("aria-live","polite");card.append(status);
      const fields=doc.createElement("div");fields.className="section-dimensions";for(const row of rows)fields.append(row);card.append(fields);
      const stats=doc.createElement("p");stats.className="section-properties";card.append(stats);
      const note=doc.createElement("p");note.className="section-orientation-note";note.textContent=kind==="T"?"Flange outer face at the skin; web inward. Local +y points outward on either skin. +x follows the bar. Preview is proportional; input dimensions are in metres.":"Outer face at the skin; square inward. Local +y points outward and +x follows the spar cap. Preview is proportional; input dimension is in metres.";card.append(note);
      if(rib)note.textContent="Default vertical rib stiffener. The flange lies in the rib plane; the web projects outboard, or inboard at the final rib. Local +x follows the bar from lower to upper skin. Dimensions are in metres; individual rib overrides below use mm.";
      host.append(card);
      const update=()=>{
        const values=inputs.map(input=>input.value.trim()===""?NaN:Number(input.value)),value=section(kind,values);
        card.classList.toggle("section-editor-invalid",!value.valid);
        inputs.forEach((input,i)=>{const invalid=!value.valid&&value.invalid.includes(i);input.setAttribute("aria-invalid",String(invalid));rows[i].classList.toggle("section-dimension-invalid",invalid);});
        status.textContent=value.valid?"":value.error;status.hidden=value.valid;
        svg.innerHTML=rib?drawing(value,id).replace(/>skin</g,">rib web<"):drawing(value,id);svg.toggleAttribute("hidden",!value.valid);
        if(value.valid)viewport?.setMetric?.(metric(value));viewport?.refresh();
        if(value.valid){card.dataset.areaM2=String(value.area);card.dataset.centroidDepthM=String(value.centroidDepth);stats.textContent="Area: "+number(value.area*1e6)+" mm² ("+number(value.area)+" m²) · C: "+number(value.centroidDepth*1000)+" mm inward from the skin.";}
        else {delete card.dataset.areaM2;delete card.dataset.centroidDepthM;stats.textContent="Correct the dimensions to update this section and the FE model.";}
        if(rib)stats.textContent=stats.textContent.replace("inward from the skin","from the rib web");
      };
      for(const input of inputs){input.addEventListener("input",update);input.addEventListener("change",update);}update();
    }
    return{viewports,captureView:()=>Object.fromEntries(Object.entries(viewports).map(([key,view])=>[key,view?.capture()])),restoreView:values=>Object.entries(values||{}).forEach(([key,value])=>viewports[key]?.restore(value)),destroy:()=>Object.values(viewports).forEach(view=>view?.destroy())};
  }
  return {section,drawing,metric,install};
});
