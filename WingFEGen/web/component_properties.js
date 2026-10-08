/* Sparse physical-rib and rib-bay overrides. Empty cells inherit the defaults;
 * displayed lengths are millimetres, while the canonical values remain SI. */
(function(root){
  "use strict";
  const T_FIELDS=["flange_width","height","flange_thickness","web_thickness"];
  function install(host,{kind,onEdit,readRibs=()=>[]}={}) {
    const rib=kind==="ribs",key="properties."+(rib?"ribs":"spar_bays"),idKey=rib?"rib":"bay";
    const canonical=host.querySelector('[id="p-'+key+'"]');if(!canonical)return null;
    const doc=host.ownerDocument,wrap=doc.createElement("section");wrap.className="component-properties";
    const title=doc.createElement("h3");title.textContent=rib?"Individual ribs":"Individual spar bays";wrap.append(title);
    const note=doc.createElement("p");note.className="group-note";note.textContent=rib?
      "Blank cells inherit the defaults above. Thicknesses and T dimensions below are in mm. Physical rib numbers do not change when the shell mesh is refined.":
      "Optional overrides in mm. Blank cells use the default 3 mm (or your edited default). Bay b is between ribs b and b+1. Spar caps use the square section above.";wrap.append(note);
    const info=doc.createElement("p");info.className="group-note";wrap.append(info);
    const scroll=doc.createElement("div");scroll.className="component-table-scroll";
    const table=doc.createElement("table");table.className="component-table";const head=table.createTHead().insertRow();
    for(const text of rib?["Rib","Web (mm)","Stiffeners","b (mm)","h (mm)","tf (mm)","tw (mm)",""]:["Bay","Front (mm)","Rear (mm)",""]){const th=doc.createElement("th");th.textContent=text;head.append(th);}
    const body=table.createTBody();scroll.append(table);wrap.append(scroll);
    const add=doc.createElement("button");add.type="button";add.textContent=rib?"+ Rib override":"+ Bay override";add.className="small";wrap.append(add);
    const status=doc.createElement("p");status.className="component-property-error";status.setAttribute("role","status");wrap.append(status);
    let preview,viewport,previewStatus,selected=null;
    if(rib&&root.WingSectionEditor){
      const previewHost=doc.createElement("div");previewHost.className="section-preview-canvas";
      preview=doc.createElementNS("http://www.w3.org/2000/svg","svg");preview.setAttribute("viewBox","0 0 360 282");preview.classList.add("section-preview");preview.dataset.viewKey="rib-override-section";previewHost.append(preview);wrap.append(previewHost);
      viewport=root.WingSVGViewport?.install(preview,{host:previewHost,snapSelector:".section-polygon,.section-centroid",title:"Selected rib stiffener",exportName:"rib-stiffener.svg"});
      previewStatus=doc.createElement("p");previewStatus.className="section-properties";wrap.append(previewStatus);
    }
    host.append(wrap);
    const fields=rib?["thickness",...T_FIELDS]:["front_thickness","rear_thickness"];
    const defaultKey=field=>rib?(field==="thickness"?"properties.t_rib_web":"properties.rib_stiffener_"+field):"properties.t_spar_web";
    const value=key=>Number(doc.getElementById("p-"+key)?.value);
    function read() {return Array.from(body.rows).map(tr=>{
      const row={[idKey]:tr.querySelector('[data-field="'+idKey+'"]').value.trim()===""?NaN:Number(tr.querySelector('[data-field="'+idKey+'"]').value)};
      for(const field of fields){const text=tr.querySelector('[data-field="'+field+'"]').value.trim();if(text!=="")row[field]=Number(text)/1000;}
      if(rib){const enabled=tr.querySelector('[data-field="stiffener_enabled"]').value;if(enabled!=="")row.stiffener_enabled=enabled==="true";}
      return row;
    });}
    function validate(rows){
      const used=new Set(),count=readRibs().length,limit=count-(rib?0:1);
      for(const row of rows){const id=row[idKey];
        if(!Number.isInteger(id)||id<1)throw Error("Enter a positive whole "+idKey+" number.");
        if(used.has(id))throw Error("Duplicate "+idKey+" "+id+". Combine its settings in one row.");used.add(id);
        if(count&&id>limit)throw Error((rib?"Rib ":"Bay ")+id+" is outside the current "+limit+" "+(rib?"ribs":"bays")+".");
        for(const field of fields)if(row[field]!==undefined&&(!Number.isFinite(row[field])||row[field]<=0))throw Error((rib?"Rib ":"Bay ")+id+": dimensions must be positive.");
        if(rib){const shape=root.WingSectionEditor.section("T",T_FIELDS.map(field=>row[field]??value(defaultKey(field))));if(!shape.valid)throw Error("Rib "+id+": "+shape.error);}
      }
      return rows.filter(row=>Object.keys(row).length>1).sort((a,b)=>a[idKey]-b[idKey]);
    }
    function drawPreview(){if(!preview)return;
      const rows=read(),row=rows.find(row=>row.rib===selected)||rows[0]||{};
      const shape=root.WingSectionEditor.section("T",T_FIELDS.map(field=>row[field]??value(defaultKey(field))));
      preview.innerHTML=root.WingSectionEditor.drawing(shape,"rib-override-drawing").replace(/>skin</g,">rib web<");if(shape.valid)viewport?.setMetric?.(root.WingSectionEditor.metric(shape));viewport?.refresh();
      previewStatus.textContent=(row.rib?"R "+row.rib:"Default")+": "+(shape.valid?"T section · area "+root.WingNumbers.format(shape.area*1e6,5)+" mm². Flange lies in the rib plane; web projects into the adjacent bay.":shape.error);
    }
    function update(notify=false){
      for(const input of body.querySelectorAll("input[data-field]")){const field=input.dataset.field;if(fields.includes(field))input.placeholder=String(Number((1000*value(defaultKey(field))).toPrecision(8)));}
      try{canonical.value=JSON.stringify(validate(read()));status.textContent="";status.hidden=true;}catch(e){status.textContent=e.message;status.hidden=false;}
      drawPreview();refresh();if(notify)onEdit?.(key);
    }
    function addRow(row={}){
      const tr=body.insertRow();
      function input(field,unit=1){const cell=tr.insertCell(),el=doc.createElement("input");el.type="number";el.step=field===idKey?"1":"any";el.min=field===idKey?"1":"0";el.dataset.field=field;el.setAttribute("aria-label",(rib?"Rib ":"Bay ")+(row[idKey]||"")+" "+field.replaceAll("_"," ")+(unit===1000?" (mm)":""));el.value=row[field]===undefined?"":String(row[field]*unit);cell.append(el);el.addEventListener("input",()=>update(true));el.addEventListener("focus",()=>{selected=Number(tr.querySelector('[data-field="'+idKey+'"]').value);drawPreview();});return el;}
      input(idKey);input(rib?"thickness":"front_thickness",1000);
      if(rib){const cell=tr.insertCell(),el=doc.createElement("select");el.dataset.field="stiffener_enabled";el.setAttribute("aria-label","Rib stiffeners");for(const [val,label]of [["","Default"],["true","On"],["false","Off"]]){const option=doc.createElement("option");option.value=val;option.textContent=label;el.append(option);}el.value=row.stiffener_enabled===undefined?"":String(row.stiffener_enabled);cell.append(el);el.addEventListener("change",()=>update(true));T_FIELDS.forEach(field=>input(field,1000));}
      else input("rear_thickness",1000);
      const remove=doc.createElement("button");remove.type="button";remove.textContent="×";remove.title="Remove override; use defaults";remove.addEventListener("click",()=>{tr.remove();update(true);});tr.insertCell().append(remove);
      return tr;
    }
    function refresh(){const count=readRibs().length;info.textContent=count?count+" physical ribs · "+(count-1)+" bays":"Create FEM to confirm physical rib numbers. Overrides are validated against the layout when generating.";}
    add.addEventListener("click",()=>{const used=new Set(read().map(row=>row[idKey]));let id=1;while(used.has(id))id++;const tr=addRow({[idKey]:id});update(true);tr.querySelector('[data-field="'+(rib?"thickness":"front_thickness")+'"]').focus();});
    for(const row of JSON.parse(canonical.value||"[]"))addRow(row);
    const globalChange=event=>{if(event.target.id?.startsWith("p-properties."))update();};host.addEventListener("input",globalChange);
    update();
    return {readDrafts:()=>({[key]:read().filter(row=>Object.keys(row).length>1||!Number.isInteger(row[idKey]))}),assertValidDraft(){canonical.value=JSON.stringify(validate(read()));},refresh, destroy(){host.removeEventListener("input",globalChange);viewport?.destroy();}};
  }
  root.WingComponentProperties={install};
})(globalThis);
