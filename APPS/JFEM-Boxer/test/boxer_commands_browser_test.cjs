'use strict';
const assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
const source=path.join(__dirname,'../web/boxer_commands.js');

(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  const page=await browser.newPage();const errors=[];page.on('pageerror',error=>errors.push(error.message));const checks=[];
  try{
    await page.setContent(`<!doctype html><title>Boxer command acceptance</title><body>
      <button id="create">Create FEM</button><button id="blocked" disabled>Run in JFEM</button>
      <div role="menuitem" id="semantic-menu">Show engines</div><input type="button" id="native-action" value="Save viewport">
      <button id="open-dialog" aria-haspopup="dialog">New Study</button><span id="clock">0</span>
      <fieldset id="group-structure" hidden><legend>Properties / Skin</legend>
        <label for="p-properties.t_skin_upper">Minimum upper skin thickness</label>
        <input id="p-properties.t_skin_upper" type="number" min="1.5" max="50" value="1.5" data-parameter-unit-key="properties.t_skin_upper" data-parameter-display-unit="mm">
        <label>Show forces<input id="forces" type="checkbox"></label>
        <label>Palette<select id="palette"><option value="signed">Red below / blue above</option><option value="spectrum">Blue Green Red</option></select></label>
        <input id="protected" readonly value="read only" aria-label="Study path">
        <input id="background" type="color" value="#123456" aria-label="Background color"><input id="date" type="date" value="2026-01-01" aria-label="Date">
        <input id="file" type="file" aria-label="Read Nastran file">
        <input id="api-key" value="secret-key" aria-label="API key"><input type="password" id="pwd" value="password">
        <button data-workspace-target="ribs">Ribs</button>
      </fieldset>
      <div id="dynamic"><fieldset><legend>Stringer 1</legend><label>Height<input type="number" data-field="height" value="32" min="1"></label><button>Delete stringer</button></fieldset></div>
      <fieldset id="group-loft"><legend>Loft</legend><button>Help: Thickness</button><button>Help: Twist</button><button>Help: Shift</button><button>Help: Stations</button><button>Add thickness station</button><button>Add twist station</button><button>Add shift station</button><button>Clear thickness schedule</button><button>Clear twist schedule</button><button>Clear shift schedule</button><button>Help: Interpolation</button><button>Help: Profile</button><button>Help: Advanced loft</button></fieldset><button id="tab-loft" role="menuitemradio">Loft</button>
      <aside id="boxer-chat" data-boxer-private="chat"><button id="chat-send">Send</button><input id="chat-model" value="private-model"></aside><button id="boxer-chat-toggle">Chat</button>
      <dialog id="confirmation"><h2>Unsaved changes</h2><button id="cancel">Cancel</button></dialog>
    </body>`);
    await page.addScriptTag({path:source});
    await page.evaluate(()=>{
      window.actions=0;window.edits=[];window.revision='study-1';window.navigation='';window.parameters={};
      document.getElementById('create').onclick=()=>{window.actions++;};
      document.getElementById('semantic-menu').onclick=document.getElementById('native-action').onclick=()=>{window.semanticCalls=(window.semanticCalls||0)+1;};
      document.getElementById('p-properties.t_skin_upper').addEventListener('change',event=>window.edits.push(event.target.value));
      document.getElementById('open-dialog').onclick=()=>document.getElementById('confirmation').showModal();
      document.getElementById('cancel').onclick=()=>document.getElementById('confirmation').close();
      document.getElementById('forces').onclick=()=>window.forceClicks=(window.forceClicks||0)+1;
      window.commands=WingBoxerCommands.create({connect:false,scanDelay:10,getState:()=>({revision:window.revision,title:'Unsaved Study',api_key:'should not leak',image:'data:image/png;base64,private'}),
        getSchema:()=>[{key:'supports.definitions',label:'Custom constraints',kind:'table',unit:''}],
        getParameters:()=>({a:1,secret:'excluded',image:'data:image/png;base64,private'}),
        actions:{'camera.fit':{label:'Fit view',context:'Camera',run:()=>{window.fit=true;}},'analysis.run':{label:'Run analysis',run:()=>new Promise(resolve=>setTimeout(()=>{window.backgroundFinished=true;resolve();},1000))}},
        navigate:target=>{window.navigation=target;},updateParameters:values=>{window.parameters=structuredClone(values);return{atomic:true};}});
    });
    const initial=await page.evaluate(()=>commands.catalog());
    assert(initial.actions.some(item=>item.id==='create'&&item.enabled));
    assert(initial.actions.some(item=>item.id==='semantic-menu'));assert(initial.actions.some(item=>item.id==='native-action'&&item.label==='Save viewport'));
    assert.equal((await page.evaluate(()=>commands.listActions('Loft',12)))[0].id,'tab-loft');
    await page.evaluate(async()=>{await commands.execute({command:'invoke_action',arguments:{id:'semantic-menu'}});await commands.execute({command:'invoke_action',arguments:{id:'native-action'}});});
    assert.equal(await page.evaluate(()=>semanticCalls),2);
    assert(initial.inputs.some(item=>item.id==='p-properties.t_skin_upper'&&!item.visible&&item.unit==='mm'));
    assert(initial.inputs.some(item=>item.parameter_key==='supports.definitions'&&item.via_update_parameters));
    assert(!JSON.stringify(initial).includes('secret-key'));assert(!initial.inputs.some(item=>['pwd','api-key','chat-model'].includes(item.id)));
    assert(!initial.actions.some(item=>['chat-send','boxer-chat-toggle'].includes(item.id)));
    const state=await page.evaluate(()=>commands.getState());assert(!('api_key'in state));assert.equal(state.image,'[embedded data]');
    const file=initial.inputs.find(item=>item.id==='file');assert.equal(file.requires_user_selection,true);assert.equal(file.editable,false);assert(!('value'in file));
    checks.push('Catalog covers hidden forms and dedicated parameter editors, records displayed units, and excludes credentials, embedded images and chat controls.');

    await page.evaluate(()=>commands.execute({command:'set_input',arguments:{input_id:'p-properties.t_skin_upper',value:2.5}}));
    assert.deepEqual(await page.evaluate(()=>edits),['2.5']);
    for(const value of [0.1,NaN,Infinity,99]){
      const message=await page.evaluate(async value=>{try{await commands.execute({command:'set_input',arguments:{input_id:'p-properties.t_skin_upper',value}});return '';}catch(error){return error.message;}},value);
      assert(message);
    }
    assert.deepEqual(await page.evaluate(()=>edits),['2.5']);
    await page.evaluate(()=>commands.execute({command:'set_input',arguments:{id:'forces',value:true}}));
    await page.evaluate(()=>commands.execute({command:'set_input',arguments:{id:'forces',value:true}}));
    assert.equal(await page.evaluate(()=>window.forceClicks),1);
    await page.evaluate(()=>commands.execute({command:'set_input',arguments:{id:'palette',value:'Blue Green Red'}}));
    assert.equal(await page.locator('#palette').inputValue(),'spectrum');
    await page.evaluate(()=>commands.execute({command:'set_input',arguments:{id:'background',value:'#FFFFFF'}}));
    assert.equal(await page.locator('#background').inputValue(),'#ffffff');
    assert.match(await page.evaluate(async()=>{try{await commands.execute({command:'set_input',arguments:{id:'date',value:'not-a-date'}});return '';}catch(error){return error.message;}}),/cannot accept/);
    assert.equal(await page.locator('#date').inputValue(),'2026-01-01');
    for(const id of ['protected','file'])assert.match(await page.evaluate(async id=>{try{await commands.execute({command:'set_input',arguments:{id,value:'bad'}});return '';}catch(error){return error.message;}},id),/read-only|file/i);
    const params=await page.evaluate(()=>commands.execute({command:'update_parameters',arguments:{values:{'properties.t_skin_upper':.003,'supports.definitions':[{grid:3,dofs:'123'}]}}}));
    assert.equal(params.atomic,true);assert.equal(await page.evaluate(()=>parameters['properties.t_skin_upper']),.003);
    checks.push('Input edits use real handlers and displayed units, validate before mutation, respect locks/file selection, and route canonical structured updates through the app hook.');

    const dynamic=initial.inputs.find(item=>item.label==='Height').id;
    await page.evaluate(()=>{document.getElementById('dynamic').innerHTML='<fieldset><legend>Stringer 1</legend><label>Height<input type="number" data-field="height" value="32" min="1"></label><button>Delete stringer</button></fieldset>';});
    await page.waitForTimeout(30);
    assert.equal((await page.evaluate(()=>commands.listInputs('Height')))[0].id,dynamic);
    await page.evaluate(id=>commands.execute({command:'set_input',arguments:{id,value:44}}),dynamic);
    assert.equal(await page.locator('#dynamic input').inputValue(),'44');
    const stale=await page.evaluate(async()=>{try{await commands.execute({command:'invoke_action',arguments:{id:'create'},expected_revision:'old-study'});return '';}catch(error){return error.message;}});
    assert.match(stale,/Study changed/);assert.equal(await page.evaluate(()=>actions),0);
    await page.evaluate(()=>commands.execute({id:'once',command:'invoke_action',arguments:{id:'create'}}));
    await page.evaluate(()=>commands.execute({id:'once',command:'invoke_action',arguments:{id:'create'}}));
    assert.equal(await page.evaluate(()=>actions),1);
    assert.match(await page.evaluate(async()=>{try{await commands.execute({id:'once',command:'invoke_action',arguments:{id:'camera.fit'}});return '';}catch(error){return error.message;}}),/different request/);
    assert.match(await page.evaluate(async()=>{try{await commands.execute({command:'invoke_action',arguments:{id:'blocked'}});return '';}catch(error){return error.message;}}),/disabled/);
    assert.match(await page.evaluate(async()=>{try{await commands.execute({command:'eval',arguments:{code:'alert(1)'}});return '';}catch(error){return error.message;}}),/Unsupported/);
    checks.push('Dynamic control IDs survive editor reconstruction; stale Study revisions, repeated mutations, disabled actions and arbitrary code are handled explicitly.');

    const waiting=await page.evaluate(()=>commands.execute({command:'invoke_action',arguments:{id:'open-dialog'}}));assert.equal(waiting.status,'waiting_for_user');
    assert.match(await page.evaluate(async()=>{try{await commands.execute({command:'invoke_action',arguments:{id:'create'}});return '';}catch(error){return error.message;}}),/open dialog/);
    await page.evaluate(()=>commands.execute({command:'invoke_action',arguments:{id:'cancel'}}));
    assert.equal(await page.locator('#confirmation').evaluate(node=>node.open),false);
    await page.evaluate(()=>commands.execute({command:'navigate',arguments:{tab:'ribs'}}));assert.equal(await page.evaluate(()=>navigation),'ribs');
    const start=Date.now(),background=await page.evaluate(()=>commands.execute({command:'invoke_action',arguments:{id:'analysis.run'}}));
    assert.equal(background.status,'dispatched');assert.equal(background.background,true);assert(Date.now()-start<700);assert.equal(await page.evaluate(()=>!!window.backgroundFinished),false);
    checks.push('Existing confirmation dialogs remain in control; navigation aliases work and asynchronous analysis dispatch never falsely claims completion or blocks Stop commands.');

    const revision=await page.evaluate(()=>commands.revision);
    await page.evaluate(()=>{for(let i=0;i<100;i++)document.getElementById('clock').textContent=String(i);});await page.waitForTimeout(30);
    assert.equal(await page.evaluate(()=>commands.revision),revision);
    const batch=await page.evaluate(async()=>{
      const small=WingBoxerCommands.create({connect:false});
      try{await small.execute({command:'update_parameters',arguments:{values:{'properties.t_skin_upper':4,'unknown.parameter':2}}});return '';}catch(error){return error.message;}finally{small.destroy();}
    });
    assert.match(batch,/dedicated Boxer editor/);assert.equal(await page.locator('[id="p-properties.t_skin_upper"]').inputValue(),'2.5');
    checks.push('Clock text changes do not rescan the command catalog; invalid multi-input requests are rejected before their first field changes.');

    await page.evaluate(()=>{
      window.requests=[];window.pollCount=0;window.bridgeMutations=0;window.bridgeStudy={epoch:1,revision:1};window.bridgeView=1;window.stateNotices=[];
      window.bridge=WingBoxerCommands.create({pollMs:20,scanDelay:10,getState:()=>({revision:'bridge-study-view-'+bridgeView,study:{...bridgeStudy}}),onState:(snapshot,previous)=>stateNotices.push({study:snapshot.study,previous}),actions:{'fixture.action':{label:'Fixture action',run:()=>{window.bridgeMutations++;}}},fetch:async(url,init)=>{
        const body=JSON.parse(init.body);requests.push({url,body});
        if(url.endsWith('/connect'))return{ok:true,json:async()=>({ok:true,client_id:'browser-1',token:'private-token'})};
        if(url.endsWith('/poll')){pollCount++;return{ok:true,json:async()=>({ok:true,commands:pollCount<3?[{id:'server-once',command:'invoke_action',arguments:{action_id:'fixture.action'}}]:[]})};}
        return{ok:true,json:async()=>({ok:true})};
      }});
    });
    await page.waitForFunction(()=>window.pollCount>=3);
    assert.equal(await page.evaluate(()=>stateNotices.length),1);
    await page.evaluate(()=>{bridgeStudy.revision++;});await page.waitForFunction(()=>stateNotices.length===2);
    assert.deepEqual(await page.evaluate(()=>stateNotices[1].previous),{epoch:1,revision:1});
    const physicalPolls=await page.evaluate(()=>pollCount);await page.evaluate(()=>{bridgeView++;});await page.waitForFunction(before=>pollCount>before+1,physicalPolls);
    assert.equal(await page.evaluate(()=>stateNotices.length),2);
    await page.evaluate(()=>{bridgeStudy.epoch++;});await page.waitForFunction(()=>stateNotices.length===3);
    await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
    const suspendedCount=await page.evaluate(()=>requests.length);await page.waitForTimeout(180);
    assert.equal(await page.evaluate(()=>requests.length),suspendedCount);
    assert.equal(await page.evaluate(()=>bridge.connection.connected),false);
    assert(await page.evaluate(()=>requests.some(item=>item.url.endsWith('/disconnect')&&item.body.token==='private-token')));
    await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
    await page.waitForFunction(()=>requests.filter(item=>item.url.endsWith('/connect')).length>=2);
    await page.evaluate(()=>bridge.destroy());
    const bridgeData=await page.evaluate(()=>({count:bridgeMutations,requests,connection:bridge.connection}));
    assert.equal(bridgeData.count,1);assert(bridgeData.requests.some(item=>item.url.endsWith('/result')&&item.body.result.status==='dispatched'));
    assert(bridgeData.requests.filter(item=>!item.url.endsWith('/connect')).every(item=>item.body.token==='private-token'));
    assert(!JSON.stringify(bridgeData.connection).includes('private-token'));
    const count=bridgeData.requests.length;await page.waitForTimeout(180);assert.equal(await page.evaluate(()=>requests.length),count);
    checks.push('Authenticated polling deduplicates redelivery, hides connection tokens, disconnects promptly, resumes after back/forward cache restoration and cleans up timers.');
    checks.push('Existing heartbeat snapshots notify the chat once per Study epoch or physical revision change; camera-only changes add no callback or independent polling.');

    await page.evaluate(()=>{
      commands.destroy();
      const host=document.createElement('section');host.id='group-large-design-variables';
      host.innerHTML=Array.from({length:17000},(_,index)=>'<label>'+('Independent property dimension '+index+' with current structural sizing definition ').repeat(2)+'<input id="large-'+index+'" type="number" value="1.5" aria-label="Large independent property '+index+'" title="A physical property in the large model. Edit in displayed millimetres; rerun the structural analysis to include redistribution."></label>').join('');
      document.body.append(host);window.large=WingBoxerCommands.create({connect:false});
    });
    const large=await page.evaluate(async()=>({catalog:large.catalog(),last:await large.execute({command:'list_inputs',arguments:{query:'Large independent property 16999',limit:5}})}));
    assert.equal(large.catalog.truncated,true);assert(large.catalog.input_count>=17000);assert(JSON.stringify(large.catalog).length<3*1024*1024);
    assert.equal(large.last.items[0].id,'large-16999');
    await page.evaluate(()=>large.execute({command:'set_input',arguments:{id:'large-16999',value:2.1}}));
    assert.equal(await page.locator('#large-16999').inputValue(),'2.1');
    await page.evaluate(()=>large.destroy());
    checks.push('A 17,000-input model retains every local control and paginated search while the broker catalog stays bounded; controls outside the published catalog remain editable.');

    await page.evaluate(()=>{
      document.getElementById('group-large-design-variables').remove();
      window.guardStudy={epoch:1,revision:3};window.guardView=1;
      window.held=WingBoxerCommands.create({connect:false,getState:()=>({revision:'view-'+guardView,study:{...guardStudy}}),updateParameters:()=>new Promise(resolve=>{window.releaseUpdate=resolve;})});
      window.edit=held.execute({command:'update_parameters',arguments:{values:{size:.002}}});
    });
    await page.waitForFunction(()=>typeof window.releaseUpdate==='function');
    const readStart=Date.now();await page.evaluate(()=>held.execute({command:'get_state'}));assert(Date.now()-readStart<500);
    await page.evaluate(()=>{window.queueCount=actions;window.queued=held.execute({command:'invoke_action',arguments:{id:'create'},expected_study_epoch:1,expected_study_revision:3}).then(()=>'',error=>error.message);guardStudy.epoch=2;releaseUpdate({atomic:true});});
    assert.match(await page.evaluate(()=>queued),/Study changed while this request was waiting/);assert.equal(await page.evaluate(()=>actions),await page.evaluate(()=>queueCount));
    assert.match(await page.evaluate(async()=>{try{await held.execute({command:'invoke_action',arguments:{id:'create'},expected_study_epoch:2,expected_study_revision:2});return '';}catch(error){return error.message;}}),/Study changed while/);
    await page.evaluate(async()=>{guardView++;await held.execute({id:'guarded-once',command:'invoke_action',arguments:{id:'create'},expected_study_epoch:2,expected_study_revision:3});});
    assert.equal(await page.evaluate(()=>actions),await page.evaluate(()=>queueCount+1));
    assert.match(await page.evaluate(async()=>{try{await held.execute({id:'guarded-once',command:'invoke_action',arguments:{id:'create'},expected_study_epoch:2,expected_study_revision:4});return '';}catch(error){return error.message;}}),/different request/);
    await page.evaluate(async()=>{await edit;held.destroy();});
    checks.push('Read-only status queries remain responsive during an awaited parameter-validation transaction.');
    checks.push('Queued assistant mutations recheck Study epoch and physical revision at dispatch; camera-only changes remain allowed and exact-once IDs include these guards.');
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({passed:true,checks,errors},null,2));
  }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
