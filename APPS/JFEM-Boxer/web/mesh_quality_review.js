/* Review valid but poorly shaped elements without hiding the generated FEM. */
(function(root){
  "use strict";
  const finite=value=>value!==null&&value!==undefined&&value!==""&&Number.isFinite(Number(value))?Number(value):null;
  const fmt=(value,digits=3)=>finite(value)===null?"—":Number(value).toFixed(digits);
  function actionsFor(quality){
    const unique=new Map();
    for(const issue of quality?.issues||[])for(const point of issue.nearby_controls||[]){
      if(!point.key||!Number.isInteger(point.row)||finite(point.rib_eta)===null)continue;
      const key=point.key+":"+point.row+":"+point.nearest_rib;
      if(!unique.has(key))unique.set(key,{...point,regions:[]});
      const action=unique.get(key),region=issue.component+" · R"+issue.rib_start+"–R"+issue.rib_end;
      if(!action.regions.includes(region))action.regions.push(region);
    }
    return [...unique.values()].sort((a,b)=>a.distance_mm-b.distance_mm).concat(
      (quality?.actions||[]).filter(action=>action.kind!=="review_geometry_control"));
  }
  function counts(quality){
    const issues=quality?.issues||[];
    return {elements:quality?.warning_element_count??issues.reduce((n,i)=>n+(i.count||i.element_ids?.length||0),0),regions:issues.length};
  }
  function connect({document:doc,onLocate,isStale=()=>false}){
    let quality=null,dialog=null,lastFocus=null;
    const button=doc.createElement("button");button.id="btn-mesh-quality";button.type="button";button.hidden=true;
    button.className="mesh-quality-button";button.setAttribute("aria-haspopup","dialog");
    button.title="Review element shape warnings, their physical locations and suggested geometry or mesh edits. The generated FEM remains available.";
    doc.querySelector(".workspace-live")?.append(button);
    const node=(tag,text,className)=>{const el=doc.createElement(tag);if(text!==undefined)el.textContent=text;if(className)el.className=className;return el;};
    function close(){dialog?.close();lastFocus?.focus?.();}
    function locate(point){
      close();onLocate?.(point);
    }
    function render(){
      if(!dialog)return;
      dialog.replaceChildren();
      const header=node("header",undefined,"mesh-quality-heading"),title=node("h2","Mesh quality review");title.id="mesh-quality-heading";
      const dismiss=node("button","Close");dismiss.type="button";dismiss.onclick=close;header.append(title,dismiss);dialog.append(header);
      const {elements,regions}=counts(quality);
      dialog.append(node("p",elements+" elements need review in "+regions+" physical regions. The FEM has been generated and can be inspected or analyzed."));
      const note=node("p",isStale()?"These warnings describe the displayed mesh. Your inputs have changed; create the FEM to reassess them.":"No ribs or geometry points were moved. Improve these regions before relying on the analysis results.","mesh-quality-note");dialog.append(note);
      const actions=actionsFor(quality);
      dialog.append(node("h3","Suggested actions"));
      const list=node("ol",undefined,"mesh-quality-actions");
      for(const point of actions){
        const row=node("li");row.dataset.action=point.kind||"review_geometry_control";
        if(point.kind && point.kind!=="review_geometry_control"){
          row.append(node("strong",point.kind==="review_movable_rib_bay" ? point.surface+" · local ribs" : point.label));
          row.append(node("p",point.message));
          const edit=node("button","Open "+point.menu);edit.type="button";edit.onclick=()=>locate(point);
          edit.title="Open this form to review geometry or mesh settings. No values are changed.";row.append(edit);
          list.append(row);continue;
        }
        row.append(node("strong",point.label+" near R"+point.nearest_rib));
        row.append(node("p",fmt(point.distance_mm)+" mm separates this point from the rib. If they should coincide, set its η to "+String(point.rib_eta)+". Otherwise move either feature farther apart or refine the long element direction."));
        row.append(node("p","Location: "+point.menu+(point.master_rib_row?" · Ribs / master-rib row "+point.master_rib_row:"")+" · "+point.regions.join("; "),"mesh-quality-location"));
        const eta=node("code",String(point.rib_eta));eta.title="Exact rib eta; retain all digits when aligning this geometry point.";
        const edit=node("button","Open "+point.menu);edit.type="button";edit.onclick=()=>locate(point);edit.title="Open the relevant editor and focus the nearby geometry point. This does not change any values.";
        row.append(edit,node("span"," Target η: "),eta);list.append(row);
      }
      if(!actions.length)list.append(node("li","Review the rib positions and boundary directions in the regions below. Separate near-coincident features, reduce boundary obliquity or subdivide the long element direction."));
      if(!(quality?.actions||[]).some(a=>a.kind==="review_refinement"))list.append(node("li","For thin spanwise cells, increase spar-height subdivisions on webs or chordwise subdivisions on skins. Refinement must improve corner angles; adding more parallel narrow strips does not help."));
      dialog.append(list);
      const details=node("details");details.append(node("summary","Affected regions and element IDs ("+regions+")"));
      const wrap=node("div",undefined,"mesh-quality-table-wrap"),table=node("table"),head=node("thead"),tr=node("tr");
      for(const label of ["Region","Elements","Min / max angle","Edge ratio","Element IDs"])tr.append(node("th",label));
      head.append(tr);table.append(head);const body=node("tbody");
      for(const issue of quality?.issues||[]){
        const row=node("tr");
        for(const text of [issue.component+" · "+(issue.rib_reference==="movable"?"local ":"")+"R"+issue.rib_start+"–R"+issue.rib_end,String(issue.count||issue.element_ids?.length||0),fmt(issue.minimum_corner_deg,2)+"° / "+fmt(issue.maximum_corner_deg,2)+"°",fmt(issue.maximum_edge_ratio,2),(issue.element_ids||[]).join(", ")])row.append(node("td",text));
        body.append(row);
      }
      table.append(body);wrap.append(table);details.append(wrap);dialog.append(details);
      dialog.append(node("p","Shape guidance: corner angles 10–170° and edge ratio ≤15. These are mesh-quality indicators, not an estimate of solution error. Collapsed or inverted faces remain invalid.","mesh-quality-location"));
    }
    function open(){
      if(!counts(quality).elements)return;
      if(!dialog){dialog=node("dialog",undefined,"mesh-quality-dialog");dialog.id="mesh-quality-dialog";dialog.setAttribute("aria-labelledby","mesh-quality-heading");doc.body.append(dialog);}
      lastFocus=doc.activeElement;render();dialog.showModal();
    }
    button.onclick=open;
    return {open,update(data){
      quality=data?.mesh_quality||null;const {elements}=counts(quality);
      button.hidden=!elements;button.textContent="Review mesh · "+elements;
      button.setAttribute("aria-label","Review "+elements+" mesh-quality warnings");
      if(dialog?.open){if(elements)render();else close();}
    },clear(){quality=null;button.hidden=true;if(dialog?.open)close();}};
  }
  const api={connect,actionsFor,counts};
  if(typeof module==="object"&&module.exports)module.exports=api;
  root.WingMeshQualityReview=api;
})(typeof globalThis!=="undefined"?globalThis:this);
