/* The browser owns the displayed, possibly unsaved Study. MCP and chat use the
 * same controls and listeners as the menus; no evaluated code crosses the bridge.
 */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.WingBoxerCommands=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const ACTIONS='button,input[type="button"],input[type="submit"],input[type="reset"],[role="button"],[role="tab"],[role="menuitem"],[role="menuitemradio"],[role="menuitemcheckbox"],summary,a[data-workspace-target],a[download]';
  const INPUTS='input,select,textarea';
  const PRIVATE='[data-boxer-private],.boxer-chat,#boxer-chat,#boxer-chat-toggle';
  const SECRET=/password|secret|credential|api[_-]?key|authorization|access[_-]?token|^token$/i;
  const clean=(value,max=240)=>String(value??'').replace(/\s+/g,' ').trim().slice(0,max);
  const plain=value=>value&&typeof value==='object'&&!Array.isArray(value);
  function hash(text){let value=2166136261;for(const char of text){value^=char.charCodeAt(0);value=Math.imul(value,16777619);}return(value>>>0).toString(36);}
  function safe(value,depth=0){
    if(value==null||typeof value==='boolean')return value;
    if(typeof value==='number')return Number.isFinite(value)?value:null;
    if(typeof value==='string')return /^(data:|blob:)/i.test(value)?'[embedded data]':value.length>2048?value.slice(0,2048)+'… [truncated]':value;
    if(depth>5)return '[nested data]';
    if(Array.isArray(value))return value.slice(0,1000).map(item=>safe(item,depth+1));
    if(plain(value))return Object.fromEntries(Object.entries(value).filter(([key])=>!SECRET.test(key)&&!/^(__proto__|prototype|constructor)$/.test(key)).slice(0,500).map(([key,item])=>[key,safe(item,depth+1)]));
    return undefined;
  }
  function create(options={}){
    const doc=options.document||globalThis.document;
    if(!doc)return null;
    const win=doc.defaultView||globalThis;
    const fetcher=options.fetch||globalThis.fetch?.bind(globalThis);
    const pageId=options.pageId||win.crypto?.randomUUID?.()||'boxer-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);
    const custom=new Map(Object.entries(options.actions||{}).map(([id,value])=>[id,typeof value==='function'?{run:value,label:id}:value]));
    let nodes=new Map(),actions=[],inputs=[],catalogRevision=0,catalogSignature='',dirty=true,destroyed=false;
    let scanTimer=null,pollTimer=null,requestController=null,connected=false,clientId='',token='',backoff=0,publishedRevision=-1;
    let polling=false,suspended=false,activeCommands=0,serial=Promise.resolve();
    const encoder=typeof win.TextEncoder==='function'?new win.TextEncoder():null;
    const jsonSize=value=>{const json=JSON.stringify(value);return encoder?encoder.encode(json).length:json.length*3;};
    const remembered=new Map();
    const publicConnection=()=>({connected,client_id:clientId||null,page_id:pageId,error:connectionError||null});
    let connectionError='',connectionNotification='',observedStudy=null;

    function excluded(node){return !node||!!node.closest(PRIVATE)||node.matches('input[type="password"],input[type="hidden"],script,style');}
    function visible(node){return !!node?.isConnected&&!node.closest('[hidden],[inert],[aria-hidden="true"]')&&!!node.getClientRects().length;}
    function disabled(node){return !node?.isConnected||node.matches(':disabled,[aria-disabled="true"]')||!!node.closest('[inert]');}
    function text(node){
      if(!node)return '';
      const copy=node.cloneNode(true);
      // A unit badge inside a label is reported separately as the input's unit. The
      // help text that form_help.js places beside a control is its description, not its name.
      for(const item of copy.querySelectorAll('input,select,textarea,button,script,style,.help-icon,.help-button,.field-tooltip,[role="tooltip"],.unit,.boxer-form-help-description'))item.remove();
      return clean(copy.textContent,180);
    }
    function label(node){
      const aria=node.getAttribute('aria-label');if(aria)return clean(aria,180);
      if(node.matches('input[type="button"],input[type="submit"],input[type="reset"]'))return clean(node.value||node.title||node.id,180);
      if(node.labels?.length){const value=Array.from(node.labels).map(text).filter(Boolean).join(' / ');if(value)return clean(value,180);}
      const row=node.closest('.row,.case-field,.display-control,tr');
      const field=row?.querySelector('.field-label,label,th');if(field&&field!==node){const value=text(field);if(value)return value;}
      return clean(node.matches(INPUTS)?node.title||node.placeholder||node.name||node.id:node.textContent||node.title||node.id,180);
    }
    function context(node){
      const parts=[];let parent=node.parentElement;
      while(parent&&parent!==doc.body&&parts.length<5){
        const heading=parent.matches('fieldset')?parent.querySelector(':scope > legend'):parent.matches('section,.parameter-group,.ui-form-section,[role="tabpanel"]')?parent.querySelector(':scope > h2,:scope > h3,:scope > .parameter-heading h2,:scope > legend'):null;
        if(heading){const value=text(heading);if(value&&!parts.includes(value))parts.unshift(value);}
        else if(parent.id&&(/^(panel-|group-|case-|row-|load-cases|support-|rf-|engine|movable)/.test(parent.id))){const value=parent.id.replace(/^(panel-|group-|row-)/,'').replace(/[-_]/g,' ');if(!parts.includes(value))parts.unshift(clean(value,80));}
        parent=parent.parentElement;
      }
      return clean(parts.join(' / '),220);
    }
    function elementKey(node,kind,counts){
      if(node.id)return node.id;
      const attributes=['action','workspaceTarget','aeroField','field','key','row','engineField','movableField','movableStructureField','reference','side','choice','masterSegment','pointIndex'];
      const data=attributes.filter(key=>node.dataset[key]!==undefined).map(key=>key+'='+node.dataset[key]).join('|');
      const signature=[kind,context(node),label(node),data,node.name||'',node.type||''].join('|');
      const count=(counts.get(signature)||0)+1;counts.set(signature,count);
      return kind+':'+hash(signature)+(count>1?':'+count:'');
    }
    function descriptor(node,id,kind){
      const result={id,label:label(node)||id,context:context(node),enabled:!disabled(node),visible:visible(node)};
      const aliases=options.inputAliases?.[id];
      if(kind==='input'&&Array.isArray(aliases))result.aliases=aliases.map(alias=>clean(alias,100));
      const description=clean(node.title,220);if(description)result.description=description;
      if(kind==='action'){
        result.kind=node.matches('[role="tab"],[data-workspace-target]')?'navigation':node.tagName==='SUMMARY'?'disclosure':'action';
        const target=node.dataset.workspaceTarget;if(target)result.target=target;
        const pressed=node.getAttribute('aria-pressed')??node.getAttribute('aria-selected');if(pressed!==null)result.selected=pressed==='true';
        if(node.getAttribute('aria-haspopup')==='dialog'||/^(btn-(load|read|save)|export-)/.test(node.id))result.may_request_user_input=true;
      }else{
        result.type=node.tagName==='SELECT'?'select':node.tagName==='TEXTAREA'?'text':node.type||'text';
        result.editable=result.enabled&&!node.readOnly&&result.type!=='file';
        if(node.readOnly)result.readonly=true;
        if(result.type==='file')result.requires_user_selection=true;
        else result.value=['checkbox','radio'].includes(result.type)?node.checked:safe(node.value);
        for(const key of ['min','max','step'])if(node[key]&&node[key]!=='any')result[key]=node[key];
        if(node.required)result.required=true;
        const unit=node.dataset.parameterDisplayUnit||node.closest('.row,.case-field')?.querySelector('.unit')?.textContent;
        if(unit)result.unit=clean(unit,40);
        const parameter=node.dataset.parameterUnitKey||(node.id.startsWith('p-')?node.id.slice(2):null);
        if(parameter)result.parameter_key=parameter;
        if(node.tagName==='SELECT'){
          result.options=Array.from(node.options).slice(0,200).map(option=>({value:option.value,label:clean(option.label,120),disabled:option.disabled}));
          if(node.options.length>200){result.option_count=node.options.length;result.options_truncated=true;}
        }
      }
      return result;
    }
    function scan(){
      if(destroyed)return;
      if(scanTimer!==null){clearTimeout(scanTimer);scanTimer=null;}
      const nextNodes=new Map(),nextActions=[],nextInputs=[],counts=new Map();
      for(const [id,item]of custom){
        const enabled=typeof item.enabled==='function'?!!item.enabled():item.enabled!==false;
        nextActions.push({id,label:clean(item.label||id,180),description:clean(item.description||'',220),context:clean(item.context||'Boxer',220),enabled,visible:true,curated:true,kind:item.kind||'action',
          ...(item.requires_user_input?{may_request_user_input:true}:{}),
          ...(Array.isArray(item.aliases)?{aliases:item.aliases.map(alias=>clean(alias,100))}:{}),
          ...(item.inputSchema?{inputSchema:safe(item.inputSchema)}:{}),...(item.parameters?{parameters:safe(item.parameters)}:{})});
      }
      for(const node of doc.querySelectorAll(ACTIONS)){
        if(excluded(node))continue;
        const id=elementKey(node,'action',counts);
        if(custom.has(id)||nextNodes.has('action:'+id))continue;
        nextNodes.set('action:'+id,node);nextActions.push(descriptor(node,id,'action'));
      }
      for(const node of doc.querySelectorAll(INPUTS)){
        if(excluded(node)||SECRET.test(node.name||'')||SECRET.test(node.id||'')||node.matches('input[type="button"],input[type="submit"],input[type="reset"],input[type="image"]'))continue;
        const id=elementKey(node,'input',counts);if(nextNodes.has('input:'+id))continue;
        nextNodes.set('input:'+id,node);nextInputs.push(descriptor(node,id,'input'));
      }
      const schema=typeof options.getSchema==='function'?options.getSchema():options.schema;
      if(Array.isArray(schema))for(const spec of schema){
        if(!spec?.key||SECRET.test(spec.key)||nextInputs.some(input=>input.parameter_key===spec.key))continue;
        nextInputs.push({id:'parameter:'+spec.key,label:clean(spec.label||spec.key,180),context:clean(spec.group||'Study parameters',220),
          parameter_key:spec.key,type:spec.kind||'structured',enabled:!!options.updateParameters,editable:false,visible:false,
          via_update_parameters:true,unit:clean(spec.unit||'',40),description:clean(spec.description||spec.help||'Use update_parameters with canonical Study units for this structured value.',220)});
      }
      const signature=hash(JSON.stringify([nextActions,nextInputs]));
      nodes=nextNodes;actions=nextActions;inputs=nextInputs;
      if(signature!==catalogSignature){catalogSignature=signature;catalogRevision++;}
      dirty=false;
    }
    function scheduleScan(){
      if(destroyed)return;dirty=true;
      if(scanTimer!==null)clearTimeout(scanTimer);
      scanTimer=setTimeout(scan,options.scanDelay??350);
    }
    function current(){if(dirty)scan();}
    function search(items,query='',limit=40,offset=0){
      const needle=clean(query,300).toLocaleLowerCase(),terms=needle.split(/\s+/).filter(Boolean);
      let filtered=terms.length?items.filter(item=>{const value=[item.id,item.label,item.context,item.description,item.parameter_key,...item.aliases||[]].join(' ').toLocaleLowerCase();return terms.every(term=>value.includes(term));}):items;
      if(terms.length){
        const rank=item=>{
          const label=clean(item.label,180).toLocaleLowerCase(),id=String(item.id).toLocaleLowerCase(),aliases=(item.aliases||[]).map(value=>clean(value,100).toLocaleLowerCase());
          if(id===needle||label===needle||aliases.includes(needle))return 0;
          if(label.startsWith(needle)||aliases.some(value=>value.startsWith(needle)))return 1;
          if(label.includes(needle)||aliases.some(value=>value.includes(needle)))return 2;
          if(id.includes(needle))return 3;
          return 4;
        };
        // Rank before paginating, so a genuine tab/action is not hidden by a
        // page of help buttons whose context merely mentions that tab.
        filtered=filtered.map((item,index)=>({item,index,rank:rank(item)})).sort((a,b)=>a.rank-b.rank||Number(!!b.item.curated)-Number(!!a.item.curated)||a.index-b.index).map(value=>value.item);
      }
      offset=Math.max(0,Math.trunc(Number(offset)||0));limit=Math.min(200,Math.max(1,Math.trunc(Number(limit)||40)));
      return{items:filtered.slice(offset,offset+limit),total:filtered.length,offset,limit,revision:catalogRevision};
    }
    function listActions(query='',limit=40,offset=0){current();return search(actions,query,limit,offset).items;}
    function listInputs(query='',limit=40,offset=0){current();return search(inputs,query,limit,offset).items;}
    function catalog(){
      current();
      let result={revision:catalogRevision,actions,inputs,action_count:actions.length,input_count:inputs.length,truncated:false};
      if(jsonSize(result)>3*1024*1024){
        // Full local search remains available through queued list_* commands.
        const lean=item=>{const value={id:item.id,label:item.label,context:item.context,enabled:item.enabled,visible:item.visible};for(const key of ['type','editable','parameter_key','unit','curated','inputSchema','aliases'])if(item[key]!==undefined)value[key]=item[key];return value;};
        let bytes=0;const take=list=>{const selected=[];for(const item of list){const value=lean(item),size=jsonSize(value);if(bytes+size>2.8*1024*1024)break;bytes+=size;selected.push(value);}return selected;};
        result={...result,actions:take(actions),inputs:take(inputs),truncated:true};
      }
      return result;
    }
    function getState(){
      let state={};
      try{state=safe(options.getState?.()||{});}catch(error){state={state_error:clean(error.message,500)};}
      return{...state,revision:state.revision??catalogRevision,catalog_revision:catalogRevision,client_id:clientId||null,
        page_title:clean(doc.title,180),connection:connected?'connected':'local',automation_busy:activeCommands>0};
    }
    function observeState(){
      const snapshot=getState(),study=snapshot.study;
      if(study&&study.epoch!==undefined&&study.revision!==undefined&&(!observedStudy||String(study.epoch)!==String(observedStudy.epoch)||String(study.revision)!==String(observedStudy.revision))){
        const previous=observedStudy;observedStudy={epoch:study.epoch,revision:study.revision};
        try{options.onState?.(snapshot,previous);}catch(error){options.log?.('Assistant state update: '+clean(error.message,500),'warn');}
      }
      return snapshot;
    }
    function modal(){return Array.from(doc.querySelectorAll('dialog[open],[role="dialog"][aria-modal="true"],.startup-study-dialog')).find(node=>!node.closest(PRIVATE)&&visible(node));}
    function assertModal(node){const active=modal();if(active&&(!node||!active.contains(node)))throw Error('Finish or cancel the open dialog before changing another part of Boxer. Dialog controls are available in list_actions and list_inputs.');}
    function existing(id,kind){current();const node=nodes.get(kind+':'+id);if(!node?.isConnected)throw Error('This '+kind+' is no longer available. Search the current '+kind+' catalog again.');return node;}
    function prepareInput(id,value){
      const node=existing(id,'input');
      if(disabled(node)||node.readOnly)throw Error(label(node)+' is disabled or read-only in the current model.');
      if(node.type==='file')throw Error('Choose files in Boxer’s file-selection dialog. File inputs cannot be populated by chat or MCP.');
      assertModal(node);
      if(['checkbox','radio'].includes(node.type)){
        if(typeof value!=='boolean')throw Error(label(node)+' requires true or false.');
        if(node.type==='radio'&&!value)throw Error('Select another radio option instead of clearing this one.');
        return{node,id,value};
      }
      if(node.tagName==='SELECT'){
        let match=Array.from(node.options).find(option=>option.value===String(value));
        if(!match){const matches=Array.from(node.options).filter(option=>option.label.toLocaleLowerCase()===String(value).toLocaleLowerCase());if(matches.length===1)match=matches[0];}
        if(!match||match.disabled)throw Error(label(node)+' requires one of its enabled options. Read list_inputs for the available values.');
        return{node,id,value:match.value};
      }
      if(value!==null&&!['string','number'].includes(typeof value))throw Error(label(node)+' requires a string or number in the units shown by Boxer.');
      const string=value===null?'':String(value);
      if(node.required&&!string.trim())throw Error(label(node)+' requires a value.');
      if(node.type==='number'||node.type==='range'){
        if(string.trim()){
          const number=Number(string);
          if(!Number.isFinite(number))throw Error(label(node)+' requires a finite number.');
          if(node.min!==''&&number<Number(node.min))throw Error(label(node)+' must be at least '+node.min+'.');
          if(node.max!==''&&number>Number(node.max))throw Error(label(node)+' must be at most '+node.max+'.');
        }
      }
      if(node.type==='color'&&!/^#[0-9a-f]{6}$/i.test(string))throw Error(label(node)+' requires a six-digit hexadecimal color such as #2468ab.');
      if(node.maxLength>0&&string.length>node.maxLength)throw Error(label(node)+' exceeds its maximum length of '+node.maxLength+'.');
      const probe=node.cloneNode(false);probe.value=string;
      const equivalent=probe.value===string||node.type==='color'&&probe.value.toLowerCase()===string.toLowerCase()||
        ['number','range'].includes(node.type)&&string.trim()!==''&&probe.value!==''&&Number(probe.value)===Number(string);
      if(!equivalent)throw Error(label(node)+' cannot accept that value.');
      if(probe.validity?.badInput||probe.validity?.typeMismatch||probe.validity?.patternMismatch||probe.validity?.rangeUnderflow||probe.validity?.rangeOverflow)
        throw Error(label(node)+' does not match its input constraints.');
      return{node,id,value:probe.value};
    }
    function applyInput(prepared){
      const {node,value}=prepared;
      if(['checkbox','radio'].includes(node.type)){
        if(node.checked!==value)node.click();
      }else{
        node.value=value;
        node.dispatchEvent(new win.Event('input',{bubbles:true}));
        node.dispatchEvent(new win.Event('change',{bubbles:true}));
      }
      dirty=true;
      return{input_id:prepared.id,value:['checkbox','radio'].includes(node.type)?node.checked:node.value};
    }
    async function invoke(id,args){
      const item=custom.get(id);let node=null;
      if(item){
        if(typeof item.enabled==='function'?!item.enabled():item.enabled===false)throw Error((item.label||id)+' is currently disabled.');
        assertModal(null);
      }else{
        node=existing(id,'action');if(disabled(node))throw Error(label(node)+' is currently disabled.');
        assertModal(node);
      }
      const before=modal();let result;
      if(item){
        result=item.run(args,controller);
        if(result&&typeof result.then==='function'){
          if(item.await_completion)result=await result;
          else{Promise.resolve(result).catch(error=>options.log?.('Command '+id+' failed: '+error.message,'err'));result={background:true};}
        }
      }else{
        node.click();
      }
      await new Promise(resolve=>setTimeout(resolve,0));scheduleScan();
      const after=modal(),waiting=!!after&&after!==before||!!item?.requires_user_input||node?.getAttribute('aria-haspopup')==='dialog'||!!node&&/^(btn-(load|read|save)|export-)/.test(node.id);
      return{ok:true,status:waiting?'waiting_for_user':'dispatched',action_id:id,
        message:waiting?'The action may request file selection or confirmation. Complete or cancel it in Boxer.':'The action was dispatched through Boxer. Read its current state and progress before requesting dependent actions.',
        ...(plain(result)?safe(result):{})};
    }
    async function perform(request){
      if(destroyed)throw Error('The Boxer command connection has closed.');
      const command=request.command||request.kind||request.type;
      const args=plain(request.arguments)?request.arguments:request;
      current();
      if(command==='get_state')return{ok:true,state:getState()};
      if(command==='list_actions'||command==='list_inputs')return{ok:true,...search(command==='list_actions'?actions:inputs,args.query,args.limit,args.offset)};
      if(command==='get_parameters'){
        if(!options.getParameters)throw Error('The current Study parameters are unavailable.');
        // “keys” narrows the answer: full keys, or groups such as "loads" for every key that starts with loads.
        const all=options.getParameters(),wanted=(Array.isArray(args.keys)?args.keys:typeof args.keys==='string'?args.keys.split(/[\s,;]+/):[]).map(key=>String(key).replace(/[*.]+$/,'')).filter(Boolean).slice(0,100);
        const chosen=wanted.length?Object.fromEntries(Object.entries(all).filter(([key])=>wanted.some(item=>key===item||key.startsWith(item+'.')))):all;
        return{ok:true,parameters:safe(chosen),...(wanted.length?{requested_keys:wanted}:{})};
      }
      const expectedEpoch=request.expected_study_epoch??args.expected_study_epoch,expectedStudyRevision=request.expected_study_revision??args.expected_study_revision;
      if(expectedEpoch!==undefined||expectedStudyRevision!==undefined){
        const study=getState().study||{};
        if(expectedEpoch!==undefined&&String(expectedEpoch)!==String(study.epoch)||expectedStudyRevision!==undefined&&String(expectedStudyRevision)!==String(study.revision))
          throw Error('The Study changed while this request was waiting. No queued assistant mutation was applied. Read the current Study and request the edit again.');
      }
      const expected=request.expected_revision??args.expected_revision;
      if(expected!==undefined&&String(expected)!==String(getState().revision))throw Error('The Study changed after this request was prepared. Read get_state and the current catalog before retrying.');
      if(command==='invoke_action'||command==='execute_action')return invoke(String(args.action_id||args.id||''),plain(args.arguments)?args.arguments:args);
      if(command==='set_input'){
        options.guardInput?.(String(args.input_id||args.id||''),args.value);     // the application may refuse a value before it reaches the form
        const result=applyInput(prepareInput(String(args.input_id||args.id||''),args.value));
        scheduleScan();return{ok:true,status:'updated',...result,message:'Updated using Boxer’s input handlers and displayed units. Analysis results may now need recalculation.'};
      }
      if(command==='update_parameters'){
        if(!plain(args.values)||!Object.keys(args.values).length)throw Error('Provide a nonempty values object keyed by Study parameter name.');
        if(Object.keys(args.values).some(key=>/^(__proto__|prototype|constructor)$/.test(key)||SECRET.test(key)))throw Error('This parameter key cannot be changed through the command bridge.');
        assertModal(null);
        if(options.updateParameters){const result=await options.updateParameters(args.values);scheduleScan();return{ok:true,status:'updated',...safe(result||{}),message:'Updated the current Study through Boxer’s parameter editor using canonical Study units.'};}
        const prepared=Object.entries(args.values).map(([key,value])=>{
          const matches=inputs.filter(input=>input.parameter_key===key||input.id==='p-'+key);
          if(matches.length!==1)throw Error('Parameter '+key+' requires its dedicated Boxer editor. Open that form, then use its listed inputs.');
          return prepareInput(matches[0].id,value);
        });
        const applied=[];
        for(const item of prepared){
          try{if(!item.node.isConnected)throw Error('The form changed during this update. Search the current inputs before continuing.');applied.push(applyInput(item));}
          catch(error){scheduleScan();throw Error(error.message+(applied.length?' Already updated: '+applied.map(value=>value.input_id).join(', ')+'.':''));}
        }
        scheduleScan();return{ok:true,status:'updated',atomic:false,applied,message:'Updated the exposed parameter controls in displayed units. Existing handlers determine model and result invalidation.'};
      }
      if(command==='navigate'){
        const target=String(args.target||args.tab||'');
        if(options.navigate){assertModal(null);const actual=await options.navigate(target);scheduleScan();return{ok:true,status:'dispatched',target:typeof actual==='string'?actual:actual?.target||target,requested_target:target};}
        const found=actions.filter(item=>item.target===target&&item.enabled);
        if(!found.length)throw Error('No current navigation action matches '+target+'. Search list_actions.');
        return invoke(found[0].id,args);
      }
      if(command==='inspect'&&options.inspect){assertModal(null);const result=await options.inspect(args);scheduleScan();return{ok:true,...safe(result||{}),status:'dispatched'};}
      throw Error('Unsupported command '+clean(command,100)+'. Use the catalog to choose an available action or input.');
    }
    function execute(request={}){
      const id=request.id?String(request.id):null;
      const signature=JSON.stringify([request.command||request.kind||request.type,request.arguments||request,request.expected_revision,request.expected_study_epoch,request.expected_study_revision]);
      if(id&&remembered.has(id)){
        const previous=remembered.get(id);
        return previous.signature===signature?previous.promise:Promise.reject(Error('This command ID was already used for a different request.'));
      }
      const readonly=['get_state','get_parameters','list_actions','list_inputs'].includes(request.command||request.kind||request.type);
      const result=readonly?Promise.resolve().then(()=>perform(request)):serial.catch(()=>{}).then(async()=>{activeCommands++;try{return await perform(request);}finally{activeCommands--;}});
      if(!readonly)serial=result;
      if(id){remembered.set(id,{signature,promise:result});if(remembered.size>256)remembered.delete(remembered.keys().next().value);}
      return result;
    }
    function connectionChanged(error=''){
      const previous=connectionError;connectionError=clean(error,500);
      const notification=JSON.stringify(publicConnection());
      if(notification!==connectionNotification){connectionNotification=notification;options.onConnection?.(publicConnection());}
      if(connectionError&&connectionError!==previous)options.log?.('Boxer MCP connection: '+connectionError,'warn');
    }
    async function api(action,body){
      requestController=new AbortController();const timeout=setTimeout(()=>requestController?.abort(),10000);
      try{
        const response=await fetcher('/api/control/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),signal:requestController.signal,cache:'no-store'});
        const result=await response.json();if(!response.ok||result.ok===false)throw Error(result.error||result.message||'Control bridge request failed.');return result;
      }finally{clearTimeout(timeout);requestController=null;}
    }
    async function poll(){
      if(destroyed||suspended||!fetcher||polling)return;
      polling=true;
      try{
        if(!connected){
          const result=await api('connect',{page_id:pageId,client_id:clientId||undefined,token:token||undefined,label:clean(options.label||doc.title||'JFEM-Boxer',180),state:observeState(),catalog:catalog()});
          clientId=result.client_id;token=result.token;
          if(!clientId||!token)throw Error('The control bridge did not return a browser identity.');
          connected=true;publishedRevision=catalogRevision;connectionChanged();
        }
        current();const payload={client_id:clientId,token,state:observeState()};
        if(publishedRevision!==catalogRevision){payload.catalog=catalog();publishedRevision=catalogRevision;}
        const response=await api('poll',payload);
        for(const command of response.commands||[]){
          if(destroyed)break;
          let result;
          try{result={result:await execute(command)};}catch(error){result={error:clean(error.message,2000)};}
          await api('result',{client_id:clientId,token,id:command.id,...result,state:observeState()});
        }
        backoff=0;connectionChanged();
      }catch(error){
        if(!destroyed&&!suspended){connected=false;publishedRevision=-1;backoff=Math.min(15000,backoff?backoff*2:1000);connectionChanged(error.message);}
      }finally{
        polling=false;
        if(!destroyed&&!suspended)pollTimer=setTimeout(poll,backoff||Math.max(100,options.pollMs??(doc.hidden?2000:500)));
      }
    }
    function retire(){
      if(!clientId||!token||!fetcher)return;
      try{Promise.resolve(fetcher('/api/control/disconnect',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({client_id:clientId,token}),keepalive:true})).catch(()=>{});}catch{}
    }
    function pagehide(event){
      if(!event.persisted){stop();return;}
      suspended=true;connected=false;retire();
      if(pollTimer!==null)clearTimeout(pollTimer);requestController?.abort();connectionChanged();
    }
    function pageshow(event){
      if(event.persisted&&!destroyed){suspended=false;connected=false;publishedRevision=-1;backoff=0;if(options.connect!==false&&fetcher)pollTimer=setTimeout(poll,0);}
    }
    function stop(){
      if(destroyed)return;destroyed=true;connected=false;
      retire();
      if(scanTimer!==null)clearTimeout(scanTimer);if(pollTimer!==null)clearTimeout(pollTimer);
      requestController?.abort();observer?.disconnect();
      doc.removeEventListener('input',onInput,true);doc.removeEventListener('change',onInput,true);
      win.removeEventListener('pagehide',pagehide);win.removeEventListener('pageshow',pageshow);
      nodes.clear();remembered.clear();connectionChanged();
    }
    const onInput=event=>{if(!excluded(event.target))scheduleScan();};
    const observer=win.MutationObserver?new win.MutationObserver(records=>{
      if(records.some(record=>{
        if(record.target.nodeType!==1||record.target.closest(PRIVATE))return false;
        if(record.type==='attributes')return record.target.matches(ACTIONS+','+INPUTS)||record.attributeName==='hidden';
        return [...record.addedNodes,...record.removedNodes].some(node=>node.nodeType===1&&(node.matches(ACTIONS+','+INPUTS)||node.querySelector(ACTIONS+','+INPUTS)));
      }))scheduleScan();
    }):null;
    const controller={execute,listActions,listInputs,catalog,getState,refresh:scheduleScan,destroy:stop,
      get connection(){return publicConnection();},get clientId(){return clientId||null;},get revision(){current();return catalogRevision;}};
    doc.addEventListener('input',onInput,true);doc.addEventListener('change',onInput,true);
    win.addEventListener('pagehide',pagehide);win.addEventListener('pageshow',pageshow);
    observer?.observe(doc.body||doc.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['disabled','readonly','hidden','aria-label','title','aria-selected','aria-pressed']});
    scan();if(options.connect!==false&&fetcher)pollTimer=setTimeout(poll,options.connectDelay??50);
    return controller;
  }
  return{create,sanitize:safe};
});
