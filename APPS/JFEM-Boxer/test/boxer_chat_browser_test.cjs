'use strict';
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
const web=path.join(__dirname,'../web');

(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  try{
    const page=await browser.newPage({viewport:{width:1100,height:850}}),errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto('about:blank');
    await page.setContent('<!doctype html><html><body><button id="boxer-chat-toggle">Chat</button><div id="app"><main>Wing viewport</main></div></body></html>');
    await page.addStyleTag({path:path.join(web,'style.css')});
    await page.addStyleTag({path:path.join(web,'form_help.css')});
    await page.addStyleTag({path:path.join(web,'boxer_chat.css')});
    await page.addScriptTag({path:path.join(web,'form_help.js')});
    await page.addScriptTag({path:path.join(web,'boxer_chat.js')});
    await page.evaluate(()=>{
      window.dispatched=[];window.requests=[];window.aiMode='normal';window.aiRound=0;window.aborted=0;window.testDelay=false;window.mcpMode='online';window.clipboardMode='normal';window.clipboardText='';
      window.studyEpoch=1;window.studyRevision=1;window.cameraRevision=1;window.newStudyRequested=0;window.changeStudyOnNew=false;
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{if(clipboardMode==='fail')throw Error('Clipboard blocked');clipboardText=value;}}});
      const liveIntervals=new Set(),originalSet=window.setInterval.bind(window),originalClear=window.clearInterval.bind(window);
      window.setInterval=(fn,ms,...args)=>{const id=originalSet(fn,ms,...args);liveIntervals.add(id);return id;};
      window.clearInterval=id=>{liveIntervals.delete(id);return originalClear(id);};window.intervalCount=()=>liveIntervals.size;
      const actions=[{action_id:'mesh.create',label:'Create FEM',context:'Mesh',enabled:true,curated:true},{action_id:'button.create',label:'Create FEM',context:'Original menu alias',enabled:true},{action_id:'open.geometry',label:'Geometry',context:'Model',enabled:true},
        {action_id:'open.stress',label:'Stress Report',context:'Results',enabled:true},{action_id:'run.solver',label:'Run in JFEM',enabled:false,reason:'Create the FEM first'}];
      const inputs=[{input_id:'upper',label:'Upper skin thickness',aliases:['minimum upper skin thickness','upper skin thickness'],context:'Properties / Skin',type:'number',units:'mm',value:1.5,enabled:true},
        {input_id:'lower',label:'Lower skin thickness',context:'Properties / Skin',type:'number',units:'mm',value:1.5,enabled:true},
        {input_id:'area',label:'Base lifting surface area',aliases:['wing area'],units:'m²',type:'number',value:40,enabled:true},
        {input_id:'wake',label:'Wake filaments',type:'checkbox',value:true,enabled:true}];
      const find=(list,query,limit)=>{const words=String(query).toLowerCase().split(/\s+/).filter(Boolean);return list.filter(entry=>words.every(word=>(entry.label+' '+(entry.context||'')+' '+(entry.aliases||[]).join(' ')).toLowerCase().includes(word))).slice(0,limit);};
      window.commands={connection:{connected:true,client_id:'test-browser'},catalog:()=>({revision:1,actions,inputs}),
        listActions:(query='',limit=40)=>find(actions,query,limit),listInputs:(query='',limit=40)=>find(inputs,query,limit),
        getState:()=>({title:'Test Wing',study:{epoch:studyEpoch,revision:studyRevision},camera:{revision:cameraRevision},fem:'current',api_key:'DO_NOT_SEND',password:'PRIVATE',image:'data:image/png;base64,'+'A'.repeat(800),
          results:{status:'available',cases:2}}),
        execute:async request=>{dispatched.push(request);
          if(request.command==='get_state')return{ok:true,state:commands.getState()};
          if(request.command==='set_input'){const entry=inputs.find(entry=>entry.input_id===request.arguments.input_id);if(!entry)throw Error('Unknown input');entry.value=request.arguments.value;studyRevision++;return{ok:true,status:'updated',message:'Updated '+entry.label};}
          if(request.command==='invoke_action'){
            if(request.arguments.action_id==='new_study'){newStudyRequested++;if(changeStudyOnNew)studyEpoch++;return{ok:true,status:'dispatched',message:'New Study was requested.'};}
            if(request.arguments.action_id==='delayed_action')return await new Promise(resolve=>{window.releaseAction=()=>resolve({ok:true,status:'dispatched',message:'The delayed menu action returned.'});});
            const entry=actions.find(entry=>entry.action_id===request.arguments.action_id);if(entry?.enabled===false)throw Error(entry.reason);
            return{ok:true,status:request.arguments.action_id==='open.geometry'?'waiting_for_user':'dispatched',message:request.arguments.action_id==='open.geometry'?'Use the Geometry form in Boxer.':undefined};
          }
          return{ok:true};
        }};
      const response=body=>({ok:true,json:async()=>body});
      const fetcher=async(url,init={})=>{
        const body=init.body?JSON.parse(init.body):null;requests.push({url,body});
        if(url==='/api/chat/config')return response({ok:true,default_provider:'commands',server_key_configured:true,defaults:{kind:'ollama',endpoint:'http://127.0.0.1:11434',model:'test-model'}});
        if(url==='/api/control/config'){
          if(mcpMode==='offline')return{ok:false,json:async()=>({error:'Boxer is restarting'})};
          return response({ok:true,url:'http://127.0.0.1:'+(mcpMode==='newsession'?'8081':'8080')+'/api/mcp?token=BRIDGE_SECRET_TOKEN',token:'BRIDGE_SECRET_TOKEN',clients:[{client_id:'one'},{client_id:'two'}],
            mcp_client_config:{mcpServers:{'JFEM-Boxer':{command:'C:\\Julia Path\\julia.exe',args:['--project=C:\\JFEM','C:\\JFEM\\APPS\\JFEM-Boxer\\BoxerMCP.jl','--discovery','C:\\JFEM\\output\\boxer_mcp_'+(mcpMode==='newsession'?'456':'123')+'.json'],env:{TOKEN:'BRIDGE_SECRET_TOKEN'}}}}});
        }
        if(url==='/api/chat/test'){
          if(testDelay)return await new Promise((resolve,reject)=>{init.signal.addEventListener('abort',()=>{aborted++;reject(new DOMException('stopped','AbortError'));},{once:true});});
          return response({ok:true,models:['test-model','other-model'],message:'Connected to the selected AI server.'});
        }
        if(url==='/api/chat/message'){
          if(aiMode==='study-delay')return await new Promise((resolve,reject)=>{
            window.releaseStudyResponse=()=>resolve(response({text:'A prepared change.',tool_calls:[{id:'stale-call',name:'set_input',arguments:{input_id:'upper',value:9}}]}));
            init.signal.addEventListener('abort',()=>reject(new DOMException('stopped','AbortError')),{once:true});
          });
          if(aiMode==='new-study-chain')return response({text:'Starting a new Study.',tool_calls:[{id:'new-call',name:'invoke_action',arguments:{action_id:'new_study'}},{id:'old-input',name:'set_input',arguments:{input_id:'upper',value:99}}]});
          if(aiMode==='awaited-tool')return response({text:'A two-action request.',tool_calls:[{id:'await-call',name:'invoke_action',arguments:{action_id:'delayed_action'}},{id:'late-input',name:'set_input',arguments:{input_id:'upper',value:99}}]});
          if(aiMode==='two-own-edits'){
            if(aiRound++===0)return response({text:'Updating two existing inputs.',tool_calls:[{id:'one-edit',name:'set_input',arguments:{input_id:'upper',value:4}},{id:'two-edit',name:'set_input',arguments:{input_id:'lower',value:5}}]});
            return response({text:'Both inputs are updated.',tool_calls:[]});
          }
          if(aiMode==='delay')return await new Promise((resolve,reject)=>{init.signal.addEventListener('abort',()=>{aborted++;reject(new DOMException('stopped','AbortError'));},{once:true});});
          if(aiMode==='error')return{ok:false,json:async()=>({error:'<img src=x onerror=alert(1)> provider unavailable'})};
          if(aiMode==='unsafe'){
            if(aiRound++===0)return response({text:'I will inspect this request.',tool_calls:[{id:'bad-tool',name:'eval',arguments:{code:'window.pwned=true'}}]});
            return response({text:'The unsupported request was rejected.',tool_calls:[]});
          }
          if(aiMode==='limit')return response({text:'',tool_calls:[{id:'call-'+aiRound++,name:'get_state',arguments:{}}]});
          if(aiRound++===0)return response({text:'I will change the upper skin using the existing input.',tool_calls:[{id:'call-1',name:'set_input',arguments:{input_id:'upper',value:3}}]});
          return response({text:'The upper skin input is updated. Run the FE analysis to assess redistributed loads.',tool_calls:[]});
        }
        throw Error('Unexpected URL '+url);
      };
      WingFormHelp.install(document);window.install=()=>WingBoxerChat.create({commands,fetch:fetcher});window.chat=install();
    });

    assert(await page.locator('#boxer-chat').isHidden());
    await page.click('#boxer-chat-toggle');
    assert.equal(await page.locator('#boxer-chat-toggle').getAttribute('aria-expanded'),'true');
    assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-prompt');
    await page.fill('#boxer-chat-prompt','Create FEM');await page.locator('#boxer-chat-prompt').press('Enter');await page.waitForFunction(()=>!chat.busy);
    assert(await page.locator('.boxer-form-help-tooltip').isHidden(),'Keyboard send must not leave a help popover over Send and Stop.');
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1)),{command:'invoke_action',arguments:{action_id:'mesh.create'},source:'chat',expected_study_epoch:1,expected_study_revision:1});
    assert.match(await page.locator('#boxer-chat-transcript').innerText(),/Follow its progress for completion/);
    assert.equal(await page.evaluate(()=>requests.length),0);
    assert.equal(await page.evaluate(()=>intervalCount()),0);
    const composeBottom=await page.locator('.boxer-chat-compose').evaluate(element=>element.getBoundingClientRect().bottom);
    const panelBottom=await page.locator('#boxer-chat').evaluate(element=>element.getBoundingClientRect().bottom);
    assert(Math.abs(composeBottom-panelBottom)<3,'The composer stays at the bottom when optional grid rows are hidden.');
    if(process.env.BOXER_CHAT_EVIDENCE_DIR){fs.mkdirSync(process.env.BOXER_CHAT_EVIDENCE_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'chat_desktop.png')});}
    console.log('1. The accessible chat opens from the header and dispatches existing menu commands without an AI connection.');

    const before=await page.evaluate(()=>dispatched.length);
    await page.evaluate(()=>chat.send('set skin thickness to 2'));
    assert.equal(await page.evaluate(()=>dispatched.length),before);
    assert.equal(await page.locator('.boxer-chat-message').last().locator('.boxer-chat-choice').count(),2);
    await page.locator('.boxer-chat-message').last().getByRole('button',{name:'Set',exact:true}).first().click();
    await page.waitForFunction(()=>!chat.busy);
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'upper',value:2});
    await page.evaluate(()=>chat.send('set upper skin thickness to 0.003 m'));
    assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.value),3);
    await page.evaluate(()=>chat.send('hide wake filaments'));
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'wake',value:false});
    await page.evaluate(()=>chat.send('open Geometry'));
    assert.match(await page.locator('#boxer-chat-transcript').innerText(),/Use the Geometry form/);
    await page.evaluate(()=>chat.send('Run in JFEM'));
    assert(await page.locator('.boxer-chat-message').last().getByRole('button',{name:'Run',exact:true}).isDisabled());
    await page.evaluate(()=>{
      commands.catalog().inputs.push({input_id:'upper-face',label:'Minimum upper skin face thickness',units:'mm',type:'number',value:1.5,enabled:true},
        {input_id:'upper-core',label:'Minimum upper skin core thickness',units:'mm',type:'number',value:1.5,enabled:true});
      commands.catalog().actions.push({action_id:'run.analysis',label:'Run in JFEM',aliases:['run analysis'],enabled:true,curated:true},
        {action_id:'tab.analysis',label:'Analysis',context:'Run analysis menu',enabled:true});
    });
    await page.evaluate(()=>chat.send('set minimum upper skin thickness to 2 mm'));
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'upper',value:2});
    await page.evaluate(()=>chat.send('set wing area to 40'));
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'area',value:40});
    await page.evaluate(()=>chat.send('run analysis'));
    assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.action_id),'run.analysis');
    await page.evaluate(()=>chat.send('set skin thickness to 6'));
    const oldChoice=page.locator('.boxer-chat-message').last().getByRole('button',{name:'Set',exact:true}).first();
    const beforeStaleChoice=await page.evaluate(()=>dispatched.length);await page.evaluate(()=>studyEpoch++);await oldChoice.click();await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),beforeStaleChoice);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/active Study changed/);
    await page.evaluate(()=>chat.send('set minimum upper skin thickness to 2'));
    assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.value),2);
    await page.evaluate(()=>chat.send('set skin thickness to 6'));
    const staleRevisionChoice=page.locator('.boxer-chat-message').last().getByRole('button',{name:'Set',exact:true}).first();
    const beforeRevisionChoice=await page.evaluate(()=>dispatched.length);await page.evaluate(()=>studyRevision++);await staleRevisionChoice.click();await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),beforeRevisionChoice);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Study definition changed/);
    console.log('2. Ambiguous edits show choices, units convert explicitly, checkbox requests work and disabled controls remain disabled.');

    await page.evaluate(()=>chat.send('Show Study status'));
    const status=await page.locator('.boxer-chat-message').last().textContent();
    assert(status.includes('Test Wing'));assert(!status.includes('DO_NOT_SEND'));assert(!status.includes('PRIVATE'));assert(status.includes('Inline asset omitted'));
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.waitForFunction(()=>requests.some(request=>request.url==='/api/chat/config'));
    await page.waitForFunction(()=>!document.getElementById('boxer-chat-mcp-copy').disabled);
    assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'http://127.0.0.1:8080/api/mcp');
    await page.click('#boxer-chat-mcp-copy');
    const copied=await page.evaluate(()=>clipboardText);
    const copiedConfig=JSON.parse(copied);assert.equal(copiedConfig.mcpServers['JFEM-Boxer'].command,'C:\\Julia Path\\julia.exe');
    assert.equal(copiedConfig.mcpServers['JFEM-Boxer'].args.at(-1),'C:\\JFEM\\output\\boxer_mcp_123.json');
    assert(!copied.includes('BRIDGE_SECRET'));assert(!copied.includes('env'));assert(!(await page.locator('#boxer-chat-settings').textContent()).includes('BRIDGE_SECRET'));
    await page.evaluate(()=>{clipboardMode='fail';});
    await page.click('#boxer-chat-mcp-copy');
    assert(await page.locator('.boxer-chat-mcp-details').getAttribute('open')!==null);
    assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-mcp-config');
    assert.equal(await page.locator('#boxer-chat-mcp-config').evaluate(element=>element.selectionEnd-element.selectionStart),copied.length);
    const controlCount=await page.evaluate(()=>requests.filter(request=>request.url==='/api/control/config').length);
    await page.waitForTimeout(100);
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/control/config').length),controlCount);
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.evaluate(()=>{mcpMode='offline';clipboardMode='normal';});
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('.boxer-chat-mcp .boxer-chat-settings-status').textContent.includes('unavailable'));
    assert.equal(await page.locator('#boxer-chat-mcp-config').inputValue(),'');assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'');assert(await page.locator('#boxer-chat-mcp-copy').isDisabled());
    await page.getByRole('button',{name:'Settings',exact:true}).click();await page.evaluate(()=>{mcpMode='newsession';});
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.waitForFunction(()=>!document.getElementById('boxer-chat-mcp-copy').disabled);
    assert((await page.locator('#boxer-chat-mcp-config').inputValue()).includes('boxer_mcp_456.json'));
    assert(!(await page.locator('#boxer-chat-mcp-config').inputValue()).includes('boxer_mcp_123.json'));
    assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'http://127.0.0.1:8081/api/mcp');
    console.log('3. MCP configuration copies only public launch/discovery settings, provides manual clipboard fallback and refreshes safely after a server restart.');
    await page.selectOption('#boxer-chat-mode','compatible');
    assert.match(await page.locator('.boxer-chat-ai-fields').innerText(),/provider and server URL match/);
    await page.fill('#boxer-chat-api-key','memory-only-secret');
    await page.getByRole('button',{name:'Test connection',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('.boxer-chat-settings-status').textContent.includes('Connected'));
    assert.equal(await page.locator('#boxer-chat-models option').count(),2);
    assert.equal(await page.evaluate(()=>requests.find(request=>request.url==='/api/chat/test').body.provider.kind),'compatible');
    await page.evaluate(()=>{aiRound=0;chat.send('Increase the upper skin thickness to three millimetres and explain.');});
    await page.waitForFunction(()=>!chat.busy);
    const aiRequests=await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/message'));
    assert.equal(aiRequests.length,2);assert.equal(aiRequests[0].body.provider.api_key,'memory-only-secret');
    assert(!JSON.stringify(aiRequests[0].body.context).includes('DO_NOT_SEND'));
    assert(!JSON.stringify(aiRequests[0].body.context).includes('data:image'));
    assert(aiRequests[1].body.messages.some(message=>message.role==='tool'&&message.tool_call_id==='call-1'));
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Run the FE analysis/);
    assert.equal(await page.evaluate(()=>intervalCount()),0);
    console.log('4. Optional AI uses the shared tools, sends compact redacted context and returns tool results in the next conversational turn.');

    let mutationsBefore=await page.evaluate(()=>dispatched.length);
    await page.evaluate(()=>{aiMode='study-delay';window.releaseStudyResponse=null;chat.send('A delayed change for this Study.');});
    await page.waitForFunction(()=>typeof releaseStudyResponse==='function');await page.evaluate(()=>{studyEpoch++;releaseStudyResponse();});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/active Study changed/);
    await page.evaluate(()=>{aiMode='study-delay';window.releaseStudyResponse=null;chat.send('A change while the user edits a property.');});
    await page.waitForFunction(()=>typeof releaseStudyResponse==='function');await page.evaluate(()=>{studyRevision++;releaseStudyResponse();});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Study definition changed/);
    await page.evaluate(()=>{aiMode='study-delay';window.releaseStudyResponse=null;chat.send('A change while the user rotates the camera.');});
    await page.waitForFunction(()=>typeof releaseStudyResponse==='function');await page.evaluate(()=>{cameraRevision++;aiMode='normal';aiRound=1;releaseStudyResponse();});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore+1);assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.value),9);
    mutationsBefore=await page.evaluate(()=>dispatched.length);
    await page.evaluate(()=>{aiMode='two-own-edits';aiRound=0;chat.send('Update both skins in this turn.');});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore+2);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Both inputs are updated/);
    mutationsBefore=await page.evaluate(()=>dispatched.length);
    await page.evaluate(()=>{aiMode='awaited-tool';window.releaseAction=null;chat.send('Test a menu action that awaits completion.');});
    await page.waitForFunction(()=>typeof releaseAction==='function');await page.evaluate(()=>{studyEpoch++;releaseAction();});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore+1);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/active Study changed/);
    mutationsBefore=await page.evaluate(()=>dispatched.length);
    await page.evaluate(()=>{aiMode='awaited-tool';window.releaseAction=null;chat.send('Test a manual resize while a menu request is pending.');});
    await page.waitForFunction(()=>typeof releaseAction==='function');await page.evaluate(()=>{studyRevision++;releaseAction();});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore+1);assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Study definition changed/);
    for(const immediate of [false,true]){
      mutationsBefore=await page.evaluate(()=>dispatched.length);
      await page.evaluate(value=>{aiMode='new-study-chain';changeStudyOnNew=value;chat.send('Create a new Study, then stop this turn.');},immediate);await page.waitForFunction(()=>!chat.busy);
      assert.equal(await page.evaluate(()=>dispatched.length),mutationsBefore+1);assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.action_id),'new_study');
      assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Remaining actions.*stopped/);
    }
    await page.evaluate(()=>{aiMode='normal';aiRound=0;chat.send('Continue with an explicit new instruction.');});await page.waitForFunction(()=>!chat.busy);
    const newHistory=await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/message').at(-2).body.messages);
    assert.equal(newHistory.length,1);assert.equal(newHistory[0].role,'user');assert.equal(await page.evaluate(()=>intervalCount()),0);
    console.log('5. Pending AI replies, awaited tools and old choices cannot mutate a replacement Study; manual edits are protected while camera changes and own edits remain valid.');

    await page.evaluate(()=>{aiMode='delay';chat.send('Wait while I test cancellation.');});
    await page.waitForFunction(()=>chat.busy&&document.querySelector('.boxer-chat-operation').hidden===false);
    await page.waitForTimeout(1100);
    assert.match(await page.locator('.boxer-chat-clock').innerText(),/0:01/);
    const dispatchedBeforeStop=await page.evaluate(()=>dispatched.length);
    await page.getByRole('button',{name:'Stop',exact:true}).click();
    await page.waitForFunction(()=>!chat.busy&&aborted>0);
    assert.equal(await page.evaluate(()=>intervalCount()),0);
    assert.equal(await page.evaluate(()=>dispatched.length),dispatchedBeforeStop);
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Actions already sent/);
    await page.evaluate(()=>{aiMode='normal';aiRound=0;chat.send('Try after the cancelled turn.');});
    await page.waitForFunction(()=>!chat.busy);
    const afterCancel=await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/message').at(-2).body.messages);
    assert.equal(afterCancel.length,1);assert.equal(afterCancel[0].role,'user');
    console.log('6. A moving elapsed clock is shown during AI work. Stop aborts the request and cleans timers and incomplete tool history.');

    await page.evaluate(()=>{aiMode='unsafe';aiRound=0;chat.clear();chat.send('Test unsupported tool output.');});
    await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>window.pwned),undefined);
    assert.match(await page.locator('#boxer-chat-transcript').innerText(),/unsupported tool/);
    await page.evaluate(()=>{aiMode='error';chat.send('Test provider error.');});
    await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.locator('#boxer-chat img').count(),0);
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/<img src=x/);
    assert.equal(await page.evaluate(()=>intervalCount()),0);
    await page.evaluate(()=>{aiMode='limit';aiRound=0;chat.send('Test bounded autonomous work.');});
    await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>aiRound),8);
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/eight-step conversation limit/);
    await page.fill('#boxer-chat-api-key','old-provider-key');
    await page.fill('#boxer-chat-endpoint','http://127.0.0.1:1235/v1');await page.locator('#boxer-chat-endpoint').press('Tab');
    assert.equal(await page.locator('#boxer-chat-api-key').inputValue(),'');
    await page.fill('#boxer-chat-api-key','compatible-provider-key');await page.selectOption('#boxer-chat-mode','ollama');
    assert.equal(await page.locator('#boxer-chat-api-key').inputValue(),'');
    await page.evaluate(()=>{document.getElementById('boxer-chat-api-key').value='hidden-key-must-not-be-sent';});
    await page.getByRole('button',{name:'Test connection',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('.boxer-chat-settings-status').textContent.includes('Connected'));
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/test').at(-1).body.provider.api_key),undefined);
    await page.selectOption('#boxer-chat-mode','compatible');
    console.log('7. Unknown tools cannot execute code, errors are rendered as text, and autonomous tool work is bounded.');

    await page.setViewportSize({width:320,height:760});
    const layout=await page.locator('#boxer-chat').evaluate(element=>({left:element.getBoundingClientRect().left,right:element.getBoundingClientRect().right,scroll:element.scrollWidth,client:element.clientWidth}));
    assert(layout.left>=0&&layout.right<=320);assert(layout.scroll<=layout.client+1);
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'chat_mobile.png')});
    await page.locator('#boxer-chat-prompt').press('Escape');
    assert(await page.locator('#boxer-chat').isHidden());assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-toggle');
    await page.click('#boxer-chat-toggle');
    await page.getByRole('button',{name:'Clear key',exact:true}).click();assert.equal(await page.locator('#boxer-chat-api-key').inputValue(),'');
    await page.evaluate(()=>{testDelay=true;});
    await page.getByRole('button',{name:'Test connection',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('.boxer-chat-settings-status').textContent.includes('Checking'));
    const abortedBeforeDestroy=await page.evaluate(()=>aborted);
    await page.evaluate(()=>chat.destroy());
    await page.waitForFunction(before=>aborted>before,abortedBeforeDestroy);
    assert.equal(await page.locator('#boxer-chat').count(),0);assert.equal(await page.evaluate(()=>intervalCount()),0);
    assert.equal(await page.locator('#boxer-chat-toggle').getAttribute('aria-expanded'),'false');
    assert.deepEqual(errors,[]);
    console.log('8. The panel fits 320-pixel screens, keyboard focus is restored and destruction aborts pending connections without leaking timers.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
