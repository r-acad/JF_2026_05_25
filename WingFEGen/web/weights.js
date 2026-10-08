/* Display the generator's FE mass accounting; no geometry is recomputed here. */
(function(root,factory){const api=factory(root,typeof module==="object"&&module.exports?require("./numbers.js"):null);if(typeof module==="object"&&module.exports)module.exports=api;else root.WingWeights=api;})(typeof globalThis!=="undefined"?globalThis:this,function(root,numbers){
  "use strict";
  const format=value=>(numbers||root.WingNumbers)?.format(value,6)??root.eng(value,6);
  function totalRows(data){
    if(!data?.totals)return [];
    const t=data.totals,rows=[{id:"structure",label:"Dry structure",mass:t.structure_mass_kg,weight:t.structure_weight_N},
      {id:"fuel",label:"Fuel at selected fill",mass:t.fuel_mass_kg,weight:t.fuel_weight_N},
      {id:"loaded",label:"Structure + fuel",mass:t.loaded_mass_kg,weight:t.loaded_weight_N}];
    if(data.components?.some(row=>row.id==="exported_aero_shells"))rows.push({id:"deck",label:"Exported FE deck",mass:t.deck_mass_kg,weight:t.deck_weight_N});
    return rows;
  }
  function create(host,onCase){
    const doc=host.ownerDocument;
    const el=(tag,cls,text)=>{const node=doc.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;};
    function massTable(rows,className){
      const table=el("table",className),head=el("thead"),heading=el("tr");
      for(const label of ["Component","Mass (kg)","Weight (N)"]){const cell=el("th","",label);cell.scope="col";heading.append(cell);}head.append(heading);table.append(head);
      const body=el("tbody");
      for(const row of rows){
        const tr=el("tr");tr.dataset.component=row.id;const name=el("th","",row.label);name.scope="row";
        if(row.note)name.title=row.note;
        const mass=el("td","weights-mass",format(row.mass)),weight=el("td","weights-force",format(row.weight));
        mass.dataset.value=String(row.mass);weight.dataset.value=String(row.weight);tr.append(name,mass,weight);body.append(tr);
      }
      table.append(body);return table;
    }
    function update(data,dirty=false,cases=[],activeCase=1){
      host.replaceChildren();
      if(cases.length){
        const label=el("label","display-control","Load case"),select=el("select");select.id="weights-case-select";
        for(const item of cases){const option=el("option","",item.id+" · "+item.label);option.value=String(item.id);select.append(option);}
        select.value=String(activeCase);select.disabled=cases.length<2;select.onchange=()=>onCase?.(Number(select.value));label.append(select);host.append(label);
      }
      const status=el("p",dirty?"weights-stale":"pick-note");status.id="weights-report-status";status.setAttribute("role","status");status.setAttribute("aria-live","polite");
      status.textContent=!data?"Create FEM to calculate component masses.":dirty?"Inputs changed. These are the last-created model's masses; regenerate to update them.":data.scope+". Fuel uses the selected load case.";
      host.append(status);if(!data)return;
      host.append(massTable(totalRows(data),"weights-table weights-totals"));
      const fuel=data.fuel;
      if(fuel){
        const note=el("p","weights-fuel");note.id="weights-fuel-summary";
        note.textContent=fuel.enabled?"Fuel: "+format(fuel.fill_fraction*100)+"% of "+format(fuel.volume_m3*1000)+" L at "+format(fuel.density_kg_m3)+" kg/m³. Full-capacity mass: "+format(fuel.capacity_mass_kg)+" kg. Ribs "+fuel.start_rib+"–"+fuel.end_rib+".":"Fuel tank is disabled: reported fuel mass is zero. Enable the tank and choose its bounding ribs in Fuel tank.";
        host.append(note);
        if(fuel.enabled&&fuel.bays?.length){
          host.append(el("h3","","Fuel by physical rib bay"));
          const table=el("table","weights-table weights-fuel-bays"),head=el("thead"),heading=el("tr");
          for(const title of ["Ribs","Gross (L)","Filled (L)","Fuel (kg)","Weight (N)"]){const cell=el("th","",title);cell.scope="col";heading.append(cell);}head.append(heading);table.append(head);
          const body=el("tbody");
          for(const bay of fuel.bays){
            const row=el("tr");row.dataset.bay=String(bay.index);
            const label=el("th","",bay.start_rib+"–"+bay.end_rib);label.scope="row";row.append(label);
            for(const value of [bay.volume_litres??bay.volume_m3*1000,(bay.filled_volume_m3??bay.volume_m3*fuel.fill_fraction)*1000,bay.mass_kg,bay.weight_N]){const cell=el("td","",format(value));cell.dataset.value=String(value);row.append(cell);}body.append(row);
          }
          table.append(body);host.append(table,el("p","pick-note",fuel.bay_note));
        }
      }
      host.append(el("h3","","Component breakdown"));
      host.append(massTable(data.components.map(row=>({id:row.id,label:row.label,mass:row.mass_kg,weight:row.weight_N,note:row.note})),"weights-table weights-components"));
      const details=el("details","weights-details");details.append(el("summary","","Calculation basis and element counts"));
      for(const row of data.components){
        const dimension=row.kind==="bar"?format(row.length_m)+" m × "+format(row.section_area_m2)+" m²":format(row.area_m2)+" m² × "+format(row.thickness_m)+" m";
        details.append(el("p","",row.label+": "+row.count+" elements; "+dimension+"; "+format(row.mass_kg)+" kg using each assigned material"+(row.kind==="bar"?".":" and laminate ply density.")));
        if(row.property_count>1)details.append(el("p","pick-note",row.kind==="bar"?"Multiple sections: area "+format(row.section_area_m2_min*1e6)+"–"+format(row.section_area_m2_max*1e6)+" mm². The value above is weighted by element length.":"Multiple thicknesses: "+format(row.thickness_m_min*1000)+"–"+format(row.thickness_m_max*1000)+" mm. The value above is weighted by element area."));
      }
      details.append(el("p","",data.method));host.append(details);
      host.append(el("p","pick-note","Weight is mass × "+format(data.gravity_m_s2)+" m/s² (standard gravity). Cases controls the applied fuel acceleration, scaled by its load multiplier; structural self-weight is not applied automatically."));
      host.append(el("p","pick-note",data.note));
      if(data.components.some(row=>row.id==="exported_aero_shells"))host.append(el("p","weights-stale","Exported aero shells are unconnected FE elements. Their mass is included in Exported FE deck, separately from dry structure; it is excluded from Structure + fuel."));
    }
    return {update};
  }
  return {create,format,totalRows};
});
