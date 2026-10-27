/* RBE3 card roles, including UM's alternate dependent set. These labels
 * describe the declared element, not a guessed global constraint ordering. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRbe3Labels=api;})(globalThis,function(){
  'use strict';
  const components=value=>Array.from(new Set(String(value??'').match(/[1-6]/g)||[])).sort().join('');
  const compact=value=>Number.isFinite(Number(value))?String(Number(Number(value).toPrecision(5))):String(value);
  function definitions(properties){
    const source=properties.source_properties||{},ref=Number(properties.reference_grid??source.REFGRID),refc=components(properties.reference_components??source.REFC);
    if(properties.interpolation_details_available===false)return[
      {grid:ref,ref:true,dependent:'',independent:'',label:'REFGRID '+refc+' · original dependent set unavailable'},
      ...(properties.connected_grids||[]).map(grid=>({grid:Number(grid),ref:false,dependent:'',independent:'',label:'Connected GRID · original DOFs / weights unavailable'}))];
    const groups=properties.weight_groups||source.WT_GROUPS||[{comps:properties.connected_components||'123',wt:properties.weight??1,grids:properties.connected_grids||[]}];
    const um=(source.UM||properties.um||[]).map(row=>({grid:Number(row.grid??row[0]),comps:components(row.comps??row[1])})).filter(row=>row.grid>0&&row.comps);
    const nodes=new Map(),entry=grid=>{if(!nodes.has(grid))nodes.set(grid,{grid,ref:false,pool:new Set(),dependent:new Set(),weights:[]});return nodes.get(grid);};
    const reference=entry(ref);reference.ref=true;for(const c of refc)reference.pool.add(c);
    for(const group of groups)for(const grid of group.grids||[]){const row=entry(Number(grid)),comps=components(group.comps);for(const c of comps)row.pool.add(c);row.weights.push('W '+compact(group.wt??1)+' / '+comps);}
    if(um.length)for(const pair of um){const row=entry(pair.grid);for(const c of pair.comps){row.dependent.add(c);row.pool.add(c);}row.um=true;}
    else for(const c of refc)reference.dependent.add(c);
    const explicit=new Set((properties.source_definition?.source_fields||[]).map(value=>String(value).trim().toUpperCase()));
    const markers=[];for(const key of ['ALPHA','TREF'])if((Number(source[key])!==0||explicit.has(key))&&Number.isFinite(Number(source[key])))markers.push(key+' '+compact(source[key]));
    return Array.from(nodes.values(),row=>{const dep=Array.from(row.dependent).sort().join(''),ind=Array.from(row.pool).filter(c=>!row.dependent.has(c)).sort().join('');
      const labels=[row.ref?'REFGRID '+refc:null,row.um?'UM':null,dep?'dep '+dep:null,ind?'ind '+ind:null,...Array.from(new Set(row.weights)),...(row.ref?markers:[])].filter(Boolean);
      return{...row,dependent:dep,independent:ind,label:labels.join(' · ')};
    });
  }
  function candidates(state,positions,enabled){
    if(!enabled||!positions)return[];
    const index=new Map(Array.from(state.nodeIds||[],(gid,i)=>[Number(gid),i])),output=[];
    for(const [id,element]of state.elements||[]){
      if(element.group.kind!=='rbe3'||state.layers.get(element.group.name)?.visible===false)continue;
      for(const row of definitions(element.group.properties||{})){
        const node=index.get(row.grid);if(node===undefined)continue;
        const point=Array.from(positions.subarray(3*node,3*node+3));if(!point.every(Number.isFinite))continue;
        output.push({kind:'rbe3_dofs',id,node,grid:row.grid,color:row.dependent?'#f4b8d6':'#c9b0f2',point,text:'RBE3 '+id+' · N '+row.grid+' · '+row.label,ownEids:[id]});
      }
    }
    return output;
  }
  return{components,definitions,candidates};
});
