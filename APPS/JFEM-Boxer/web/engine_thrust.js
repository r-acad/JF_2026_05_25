(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;else root.WingEngineThrust=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const KEY='loads.engine_thrust';
  const HELP='Enter signed thrust in newtons for each engine in this load case. Positive thrust acts forward along BASIC −X at the engine centre of gravity; a negative value reverses it. The case Load multiplier scales this value once. Thrust is independent of Include structural inertia and the inertia acceleration inputs. SOL101 and SOL106 apply it as a fixed-direction force; SOL105 includes it in the static preload. SOL103 normal modes ignores applied forces. Disabled engines retain their entered thrust but apply no force.';
  function normalize(value,engines){
    if(!Array.isArray(value)||value.length>100)throw Error('Engine thrust must be a list of at most 100 assignments.');
    const names=new Set(),available=engines&&new Set(engines.map(engine=>engine.name));
    return value.map(raw=>{
      if(!raw||typeof raw!=='object'||Array.isArray(raw)||Object.keys(raw).some(key=>!['engine','thrust_n'].includes(key)))throw Error('Engine thrust: each row needs an engine name and thrust in N.');
      const engine=typeof raw.engine==='string'?raw.engine.trim():'';
      if(!engine||[...engine].length>80)throw Error('Engine thrust: choose a valid engine name.');
      if(names.has(engine))throw Error('Engine thrust: duplicate assignment for '+engine+'.');
      names.add(engine);
      const thrust_n=raw.thrust_n===undefined?0:raw.thrust_n;
      if(typeof thrust_n!=='number'||!Number.isFinite(thrust_n))throw Error(engine+': thrust must be a finite number in N.');
      if(available&&!available.has(engine)&&thrust_n!==0)throw Error(engine+': this thrust assignment has no matching engine. Restore that engine, set its thrust to zero, or remove the assignment in Loads / Cases.');
      return {engine,thrust_n};
    });
  }
  function canonical(value){
    return (Array.isArray(value)?value:[]).map(row=>({engine:String(row.engine??'').trim(),thrust_n:row.thrust_n===undefined?0:row.thrust_n}))
      .filter(row=>row.thrust_n!==0).sort((a,b)=>a.engine<b.engine?-1:a.engine>b.engine?1:0);
  }
  function renamed(value,oldName,newName){
    const rows=(value||[]).map(row=>({...row}));
    if(oldName===newName)return rows;
    if(rows.some(row=>row.engine===oldName)&&rows.some(row=>row.engine===newName))throw Error('Cannot rename engine: thrust assignments already exist for both '+oldName+' and '+newName+'. Remove the unused assignment in Loads / Cases first.');
    return rows.map(row=>row.engine===oldName?{...row,engine:newName}:row);
  }
  function mount({host,engines,read,write,inherited=false,onInherit,isLocked=()=>false,notice=''}){
    const document=host.ownerDocument,values=read()||[],catalog=new Map(engines.map(engine=>[engine.name,engine]));
    if(!engines.length&&!values.length&&!notice)return null;
    const section=document.createElement('fieldset');section.id='case-engine-thrust';section.className='ui-form-group engine-thrust';
    const legend=document.createElement('legend');legend.textContent='Engine thrust';section.append(legend);
    const help=document.createElement('details'),summary=document.createElement('summary'),description=document.createElement('p');
    help.className='ui-form-help';summary.textContent='Direction, load multiplier and analysis';description.textContent=HELP;help.append(summary,description);section.append(help);
    if(notice){const message=document.createElement('p');message.className='case-setting-status';message.setAttribute('role','status');message.textContent=notice;section.append(message);}
    const inheritance=document.createElement('p');inheritance.className='case-inherited';inheritance.textContent=inherited?'From case 1; editing any engine creates a separate thrust schedule for this case.':'';inheritance.hidden=!inherited;section.append(inheritance);
    const warning=document.createElement('p');warning.className='case-setting-status case-setting-warning';warning.setAttribute('role','status');section.append(warning);
    const inputs=[];let reset=null;
    function check(){
      try{normalize(read(),engines);warning.textContent='';warning.hidden=true;}
      catch(error){warning.textContent=error.message;warning.hidden=false;}
    }
    function save(){
      write(inputs.map(item=>({engine:item.name,thrust_n:item.input.value.trim()===''?null:Number(item.input.value)})));
      inheritance.hidden=true;check();
      if(reset)reset.disabled=isLocked();
    }
    const names=[...catalog.keys(),...values.filter(row=>!catalog.has(row.engine)).map(row=>row.engine)];
    for(const [index,name]of [...new Set(names)].entries()){
      const engine=catalog.get(name),row=document.createElement('div'),caption=document.createElement('label'),input=document.createElement('input'),status=document.createElement('small');
      row.className='case-field';row.dataset.engineThrustRow=name;input.id='case-engine-thrust-'+index;input.dataset.engineThrust=name;
      caption.htmlFor=input.id;caption.textContent=name+' thrust (N)';input.type='number';input.step='100';input.value=String(values.find(item=>item.engine===name)?.thrust_n??0);input.setAttribute('aria-label',caption.textContent);input.title=HELP;input.disabled=isLocked();input.oninput=save;
      status.className='case-caption';status.textContent=!engine?'Engine missing · assignment retained for review':engine.enabled===false?'Engine disabled · this thrust is retained but not applied':'Positive = forward (−X); negative = reverse';
      row.append(caption,input,status);inputs.push({name,input});
      if(!engine){const remove=document.createElement('button');remove.type='button';remove.className='mini ghost';remove.textContent='Remove assignment';remove.disabled=isLocked();remove.onclick=()=>{write((read()||[]).filter(item=>item.engine!==name));const position=inputs.findIndex(item=>item.name===name);inputs.splice(position,1);row.remove();inheritance.hidden=true;if(reset)reset.disabled=isLocked();check();};row.append(remove);}
      section.append(row);
    }
    if(onInherit){reset=document.createElement('button');reset.type='button';reset.className='mini ghost';reset.textContent='Use case 1 thrust';reset.title='Remove this case’s thrust override and follow all engine thrust values from case 1.';reset.disabled=isLocked()||inherited;reset.onclick=onInherit;section.append(reset);}
    host.append(section);check();return section;
  }
  return {KEY,HELP,normalize,canonical,renamed,mount};
});
