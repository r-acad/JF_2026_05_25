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
    await page.addScriptTag({path:path.join(web,'boxer_chat_language.js')});
    await page.addScriptTag({path:path.join(web,'boxer_live.js')});
    await page.addScriptTag({path:path.join(web,'boxer_chat.js')});
    await page.evaluate(()=>{
      window.dispatched=[];window.requests=[];window.aiMode='normal';window.aiRound=0;window.aborted=0;window.testDelay=false;window.mcpMode='online';window.clipboardMode='normal';window.clipboardText='';window.googleMode='ok';
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
        if(url==='/api/chat/record'){const sent=JSON.parse(init.body);(window.recorded=window.recorded||[]).push(...sent.lines.map(line=>JSON.parse(line)));return{ok:true,json:async()=>({ok:true,path:'C:\Boxer\output\chat_conversations\boxer_conversation_'+sent.id+'.jsonl'})};}
        const body=init.body?JSON.parse(init.body):null;requests.push({url,body});
        if(url==='/api/chat/config')return response({ok:true,default_provider:'commands',server_key_configured:true,defaults:{kind:'ollama',endpoint:'http://127.0.0.1:11434',model:'test-model'}});
        if(url==='/api/control/config'){
          if(mcpMode==='offline')return{ok:false,json:async()=>({error:'Boxer is restarting'})};
          return response({ok:true,url:'http://127.0.0.1:'+(mcpMode==='newsession'?'8081':'8080')+'/api/mcp?token=BRIDGE_SECRET_TOKEN',token:'BRIDGE_SECRET_TOKEN',clients:[{client_id:'one'},{client_id:'two'}],
            mcp_client_config:{mcpServers:{'JFEM-Boxer':{command:'C:\\Julia Path\\julia.exe',args:['--project=C:\\JFEM','C:\\JFEM\\APPS\\JFEM-Boxer\\BoxerMCP.jl','--discovery','C:\\JFEM\\output\\boxer_mcp_'+(mcpMode==='newsession'?'456':'123')+'.json'],env:{TOKEN:'BRIDGE_SECRET_TOKEN'}}}}});
        }
        if(url==='/api/chat/test'){
          if(testDelay)return await new Promise((resolve,reject)=>{init.signal.addEventListener('abort',()=>{aborted++;reject(new DOMException('stopped','AbortError'));},{once:true});});
          if(body.provider.kind==='google'){
            const rows=[['gemini-2.5-flash','Gemini 2.5 Flash','chat'],['gemini-3.8-flash','Gemini 3.8 Flash','chat',1],['gemini-3.5-flash-lite','Gemini 3.5 Flash-Lite','chat',2],['gemini-4-carbon','Gemini 4 Carbon','chat'],
              ['gemini-3.8-flash-tts','Gemini 3.8 Flash TTS','speech'],['gemini-omni-1.2-flash','Gemini Omni Flash','other']].map(([id,display_name,category,recommended_rank])=>({id,display_name,category,...(recommended_rank?{recommended_rank}:{})}));
            const listed={ok:true,models:rows.map(row=>row.id),model_details:rows,recommended:['gemini-3.8-flash','gemini-3.5-flash-lite'],tts_models:['gemini-3.8-flash-tts'],voices:['Kore','Puck']};
            if(googleMode==='invalid')return{ok:false,json:async()=>({ok:false,code:'invalid_key',error:'Boxer chat. Google did not accept this API key. Open Google AI Studio (aistudio.google.com/apikey), copy the complete key with its Copy button, paste it again in Settings and press Connect. [Google: HTTP 400 INVALID_ARGUMENT · API key not valid. Please pass a valid API key.]'})};
            if(googleMode==='offline')return{ok:false,json:async()=>({ok:false,code:'offline',error:'Boxer chat. Boxer could not find Google\'s server (generativelanguage.googleapis.com). This computer seems to be offline, or its network blocks that address. Check the internet connection and press Connect again.'})};
            if(googleMode==='unverified')return response({...listed,verified:false,verify_code:'quota',selected_model:body.provider.model||'gemini-3.8-flash',message:'Google accepted the key and listed 6 model(s), but “'+(body.provider.model||'gemini-3.8-flash')+'” did not answer a short test request. Google gives this project no allowance for the model. Open Settings and choose another model.'});
            return response({...listed,verified:true,selected_model:body.provider.model||'gemini-3.8-flash',message:'Connected to Google Gemini.'});
          }
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
          if(aiMode==='quota')return{ok:false,json:async()=>({ok:false,code:'quota',error:'Boxer chat. Today\'s allowance for the model “gemini-3.8-flash” is used up on the free tier. It resets at midnight Pacific time. No retry or alternate model was used. [Google: HTTP 429 RESOURCE_EXHAUSTED]'})};
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
    const openSettings=async()=>{if(await page.locator('#boxer-chat-settings').isHidden())await page.click('#boxer-chat-key-button');};
    const closeSettings=async()=>{if(await page.locator('#boxer-chat-settings').isVisible())await page.click('#boxer-chat-settings-back');};
    // The bridge for other AI programs is in the Options view, with the steps for each program.
    await openSettings();
    assert(await page.locator('#boxer-chat-mcp-copy').isHidden(),'The Key view holds nothing about other AI programs.');
    await page.locator('#boxer-chat-advanced > summary').click();
    assert.equal(await page.locator('#boxer-chat-settings .boxer-chat-mcp').count(),0);
    assert.equal(await page.evaluate(()=>requests.length),0,'Opening the Key view and Advanced options contacts nothing.');
    await closeSettings();
    const openOptions=async()=>{if(await page.locator('#boxer-chat-options-panel').isHidden())await page.click('#boxer-chat-options');};
    const closeOptions=async()=>{if(await page.locator('#boxer-chat-options-panel').isVisible())await page.click('#boxer-chat-options-back');};
    assert.equal(await page.locator('#boxer-chat-options').innerText(),'Options');
    await openOptions();
    assert.equal(await page.locator('#boxer-chat-options').getAttribute('aria-expanded'),'true');assert(await page.locator('#boxer-chat-settings').isHidden());
    assert.equal(await page.locator('#boxer-chat-mcp-title').innerText(),'Use Codex, Claude or another AI program with Boxer');
    assert.deepEqual(await page.locator('.boxer-chat-program > summary').allInnerTexts(),['Claude Desktop','Claude Code','Codex (OpenAI)','Another program (Cursor, VS Code, Gemini CLI and others)']);
    const optionsText=await page.locator('#boxer-chat-options-panel').innerText();
    for(const phrase of ['Model Context Protocol','You set it up once.','Before you start','Good to know','Nothing is sent to the internet by this bridge'])assert(optionsText.includes(phrase),phrase);
    await page.waitForFunction(()=>!document.getElementById('boxer-chat-mcp-copy').disabled);
    assert.match(await page.locator('#boxer-chat-mcp-status').innerText(),/^Ready to connect\. \d+ Boxer tabs? (is|are) connected\.$/);
    assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'http://127.0.0.1:8080/api/mcp');
    await page.evaluate(()=>{for(const block of document.querySelectorAll('.boxer-chat-program'))block.open=true;});
    assert.match(await page.locator('#boxer-chat-mcp-claude-desktop').innerText(),/Settings, choose “Developer”, and press “Edit Config”[^]*claude_desktop_config\.json[^]*Quit Claude Desktop completely/);
    assert.match(await page.locator('#boxer-chat-mcp-codex').innerText(),/config\.toml[^]*\.codex[^]*paste the lines at the end of that file/);
    await page.click('#boxer-chat-mcp-copy');
    const copied=await page.evaluate(()=>clipboardText);
    const copiedConfig=JSON.parse(copied);assert.equal(copiedConfig.mcpServers['JFEM-Boxer'].command,'C:\\Julia Path\\julia.exe');
    assert.equal(copiedConfig.mcpServers['JFEM-Boxer'].args.at(-1),'C:\\JFEM\\output\\boxer_mcp_123.json');
    assert(!copied.includes('BRIDGE_SECRET'));assert(!copied.includes('env'));assert(!(await page.locator('#boxer-chat-options-panel').textContent()).includes('BRIDGE_SECRET'));
    // The same launch command in the form each program takes.
    await page.click('#boxer-chat-mcp-copy-desktop');assert.equal(await page.evaluate(()=>clipboardText),copied);
    assert.match(await page.locator('#boxer-chat-mcp-status').innerText(),/^Copied for Claude Desktop\. Paste it into claude_desktop_config\.json, save, and restart Claude Desktop\.$/);
    await page.click('#boxer-chat-mcp-copy-code');
    assert.equal(await page.evaluate(()=>clipboardText),'claude mcp add --scope user jfem-boxer -- "C:\\Julia Path\\julia.exe" "--project=C:\\JFEM" "C:\\JFEM\\APPS\\JFEM-Boxer\\BoxerMCP.jl" "--discovery" "C:\\JFEM\\output\\boxer_mcp_123.json"');
    await page.click('#boxer-chat-mcp-copy-codex');
    assert.equal(await page.evaluate(()=>clipboardText),"[mcp_servers.jfem-boxer]\ncommand = 'C:\\Julia Path\\julia.exe'\nargs = ['--project=C:\\JFEM', 'C:\\JFEM\\APPS\\JFEM-Boxer\\BoxerMCP.jl', '--discovery', 'C:\\JFEM\\output\\boxer_mcp_123.json']\n");
    assert.equal(await page.locator('#boxer-chat-mcp-config').inputValue(),await page.evaluate(()=>clipboardText),'The text box shows what the last button copied.');
    for(const text of [await page.evaluate(()=>clipboardText)])assert(!text.includes('BRIDGE_SECRET'));
    await page.evaluate(()=>{clipboardMode='fail';});
    await page.click('#boxer-chat-mcp-copy');
    assert(await page.locator('.boxer-chat-mcp-details').getAttribute('open')!==null);
    assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-mcp-config');
    assert.equal(await page.locator('#boxer-chat-mcp-config').evaluate(element=>element.selectionEnd-element.selectionStart),copied.length);
    const controlCount=await page.evaluate(()=>requests.filter(request=>request.url==='/api/control/config').length);
    await page.waitForTimeout(100);
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/control/config').length),controlCount);
    // Escape leaves the Options view and keeps the chat open; the Key view is one button away.
    await page.keyboard.press('Escape');assert(await page.locator('#boxer-chat-options-panel').isHidden());assert(await page.locator('#boxer-chat').isVisible());
    await openOptions();await page.getByRole('button',{name:'Open the Key view'}).click();
    assert(await page.locator('#boxer-chat-options-panel').isHidden());assert(await page.locator('#boxer-chat-settings').isVisible());await closeSettings();
    await page.evaluate(()=>{mcpMode='offline';clipboardMode='normal';});
    await openOptions();
    await page.waitForFunction(()=>document.getElementById('boxer-chat-mcp-status').textContent.includes('unavailable'));
    assert.equal(await page.locator('#boxer-chat-mcp-config').inputValue(),'');assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'');
    for(const id of ['boxer-chat-mcp-copy','boxer-chat-mcp-copy-desktop','boxer-chat-mcp-copy-code','boxer-chat-mcp-copy-codex'])assert(await page.locator('#'+id).isDisabled(),id);
    await page.evaluate(()=>{mcpMode='newsession';});
    await page.click('#boxer-chat-mcp-refresh');
    await page.waitForFunction(()=>!document.getElementById('boxer-chat-mcp-copy').disabled);
    assert((await page.locator('#boxer-chat-mcp-config').inputValue()).includes('boxer_mcp_456.json'));
    assert(!(await page.locator('#boxer-chat-mcp-config').inputValue()).includes('boxer_mcp_123.json'));
    assert.equal(await page.locator('#boxer-chat-mcp-endpoint').inputValue(),'http://127.0.0.1:8081/api/mcp');
    await closeOptions();await openSettings();   // the next group works in the Key view
    console.log('3. Options explains the MCP bridge for Claude Desktop, Claude Code, Codex and other programs; each Copy button gives that program’s form of the same launch command without any token, with a manual fallback, and the view refreshes safely after a server restart.');
    await page.check('#boxer-chat-mode-compatible');
    await page.waitForFunction(()=>/provider and server URL match/.test(document.querySelector('.boxer-chat-ai-fields').textContent));
    assert(await page.locator('#boxer-chat-endpoint').isVisible(),'A compatible server needs its address, so the field is shown directly.');
    assert(await page.locator('#boxer-chat-key-block').isHidden());assert.match(await page.locator('#boxer-chat-other-note').innerText(),/An advanced option is in use: AI server/);
    await page.fill('#boxer-chat-server-key','memory-only-secret');
    await page.click('#boxer-chat-connect');
    await page.waitForFunction(()=>document.querySelector('#boxer-chat-settings-status').textContent.includes('Connected'));
    assert(await page.locator('#boxer-chat-settings').isHidden(),'A successful connection returns to the conversation.');
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Connected to AI server · model test-model/);
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'AI server · connected · test-model');
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
    await openSettings();
    await page.fill('#boxer-chat-server-key','old-provider-key');
    await page.fill('#boxer-chat-endpoint','http://127.0.0.1:1235/v1');await page.locator('#boxer-chat-endpoint').press('Tab');
    assert.equal(await page.locator('#boxer-chat-server-key').inputValue(),'');
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/cleared because the AI server changed/);
    await page.fill('#boxer-chat-server-key','compatible-provider-key');await page.check('#boxer-chat-mode-ollama');
    assert.equal(await page.locator('#boxer-chat-server-key').inputValue(),'');
    assert(await page.locator('#boxer-chat-server-key-field').isHidden(),'Ollama needs no key, so none is asked for.');
    assert.equal(await page.locator('#boxer-chat-endpoint').inputValue(),'http://127.0.0.1:11434','The Ollama address is filled in.');
    await page.evaluate(()=>{document.getElementById('boxer-chat-server-key').value='hidden-key-must-not-be-sent';});
    await page.click('#boxer-chat-connect');
    await page.waitForFunction(()=>document.querySelector('#boxer-chat-settings-status').textContent.includes('Connected'));
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/test').at(-1).body.provider.api_key),undefined);
    await openSettings();await page.check('#boxer-chat-mode-compatible');await closeSettings();
    console.log('7. Unknown tools cannot execute code, errors are rendered as text, and autonomous tool work is bounded.');

    await page.setViewportSize({width:320,height:760});
    const layout=await page.locator('#boxer-chat').evaluate(element=>({left:element.getBoundingClientRect().left,right:element.getBoundingClientRect().right,scroll:element.scrollWidth,client:element.clientWidth}));
    assert(layout.left>=0&&layout.right<=320);assert(layout.scroll<=layout.client+1);
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'chat_mobile.png')});
    await page.locator('#boxer-chat-prompt').press('Escape');
    assert(await page.locator('#boxer-chat').isHidden());assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-toggle');
    await page.click('#boxer-chat-toggle');
    await openSettings();
    await page.evaluate(()=>{testDelay=true;});
    await page.click('#boxer-chat-connect');
    await page.waitForFunction(()=>document.querySelector('#boxer-chat-settings-status').textContent.includes('Checking'));
    assert.equal(await page.locator('#boxer-chat-settings-status').getAttribute('data-state'),'busy');
    const abortedBeforeDestroy=await page.evaluate(()=>aborted);
    await page.evaluate(()=>chat.destroy());
    await page.waitForFunction(before=>aborted>before,abortedBeforeDestroy);
    assert.equal(await page.locator('#boxer-chat').count(),0);assert.equal(await page.evaluate(()=>intervalCount()),0);
    assert.equal(await page.locator('#boxer-chat-toggle').getAttribute('aria-expanded'),'false');
    assert.deepEqual(errors,[]);
    console.log('8. The panel fits 320-pixel screens, keyboard focus is restored and destruction aborts pending connections without leaking timers.');

    // ---- First use and the Google Gemini connection --------------------------------
    await page.setViewportSize({width:1100,height:850});
    await page.evaluate(()=>{requests.length=0;dispatched.length=0;testDelay=false;aiMode='normal';aiRound=0;googleMode='ok';
      commands.catalog().inputs.push({input_id:'aspect',label:'Base aspect ratio',aliases:['aspect ratio','wing aspect ratio'],context:'Planform / planform.aspect ratio',type:'number',value:8,enabled:true},
        {input_id:'sweep',label:'Sweep',aliases:['sweep','sweep angle'],context:'Planform',type:'number',units:'deg',value:15,enabled:true},
        {input_id:'solution',label:'Solution',context:'Analysis',type:'select',value:'103',enabled:true,options:[{value:'101',label:'101 · Static'},{value:'103',label:'103 · Normal modes'},{value:'105',label:'105 · Buckling'}]},
        {input_id:'title',label:'Model title',context:'Analysis',type:'text',value:'Wing',enabled:true});
      commands.catalog().actions.push({action_id:'tab.materials',label:'Model: Materials',context:'Model',kind:'navigation',enabled:true},{action_id:'help.materials',label:'Help: Materials',context:'Materials',enabled:true},
        {action_id:'tab.ribs.geometry',label:'Geometry: Ribs',context:'Geometry',kind:'navigation',enabled:true},{action_id:'tab.ribs.model',label:'Model: Ribs',context:'Model',kind:'navigation',enabled:true});
      window.chat=install();});
    await page.click('#boxer-chat-toggle');
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'No Gemini key · simple commands only');
    assert(await page.locator('#boxer-chat-banner').isHidden());assert(await page.locator('.boxer-chat-voice-tools').isHidden());
    assert(await page.locator('#boxer-chat-first').isVisible());
    const roomy=await page.locator('#boxer-chat-transcript').evaluate(element=>element.getBoundingClientRect().height);
    await openSettings();
    assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-api-key','The first thing to do is paste the key.');
    assert.equal(await page.locator('#boxer-chat-key-connect').innerText(),'Connect');
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/No key yet\. Paste your Gemini API key above and press Connect\./);
    assert(await page.locator('#boxer-chat-endpoint').isHidden());assert(await page.locator('#boxer-chat-model').isHidden());assert(await page.locator('#boxer-chat-mode-google').isHidden());
    await page.locator('#boxer-chat-advanced > summary').click();
    assert(await page.locator('#boxer-chat-mode-live').isChecked(),'Gemini directly from the browser is the standard way.');
    await page.check('#boxer-chat-mode-google');
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/Not connected\. Paste your key above, then press Connect\./);
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · not connected');
    assert(await page.locator('#boxer-chat-endpoint').isVisible());
    assert.equal(await page.locator('#boxer-chat-endpoint').inputValue(),'https://generativelanguage.googleapis.com/v1beta');
    assert(await page.locator('#boxer-chat-model-field').isHidden(),'No model has to be chosen before connecting.');
    assert.match(await page.locator('#boxer-chat-api-key-hint').innerText(),/In this advanced mode the key and your messages pass through the Boxer program/);
    // Every visible control states what it is, whether it is needed and what to enter.
    const explained=async()=>page.evaluate(()=>{
      const shown=node=>node.checkVisibility(),missing=[];
      for(const control of document.querySelectorAll('#boxer-chat-settings input,#boxer-chat-settings select,#boxer-chat-settings textarea')){
        if(!shown(control))continue;
        const hint=document.getElementById(control.getAttribute('aria-describedby')||'');
        const caption=control.type==='radio'?control.closest('label'):document.querySelector('label[for="'+control.id+'"]')||control.closest('label');
        if(!hint||hint.textContent.trim().length<25||!caption?.querySelector('.boxer-chat-need'))missing.push(control.id||control.name);
      }
      return missing;});
    assert.deepEqual(await explained(),[],'Every advanced option is explained.');
    assert(await page.locator('#boxer-chat-endpoint').getAttribute('readonly')!==null);
    await page.check('#boxer-chat-mode-live');assert.deepEqual(await explained(),[]);await page.check('#boxer-chat-mode-google');
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'advanced_gemini_through_boxer_desktop.png')});
    // Without a key, or with something that is not a key, nothing is sent.
    await page.click('#boxer-chat-key-connect');
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/Paste your Gemini API key into the box first/);
    assert.equal(await page.locator('#boxer-chat-settings-status').getAttribute('data-state'),'error');
    for(const [typed,reason] of [['https://aistudio.google.com/apikey',/web address, not a key/],['someone@example.com',/e-mail address/],['short',/too short to be a Gemini API key/]]){
      await page.fill('#boxer-chat-api-key',typed);await page.click('#boxer-chat-key-connect');
      assert.match(await page.locator('#boxer-chat-settings-status').innerText(),reason);
    }
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/test').length),0);
    // A key pasted with quotes, blanks and a line break is cleaned before it is sent.
    await page.evaluate(()=>{googleMode='invalid';const input=document.getElementById('boxer-chat-api-key');input.value='  "AIzaSy-TEST-0123456789 abcdefghij\nklmnopqrs"  ';input.dispatchEvent(new Event('input',{bubbles:true}));});
    await page.click('#boxer-chat-key-connect');
    await page.waitForFunction(()=>document.getElementById('boxer-chat-settings-status').dataset.state==='error');
    const firstTry=await page.evaluate(()=>requests.find(request=>request.url==='/api/chat/test').body);
    assert.equal(firstTry.provider.api_key,'AIzaSy-TEST-0123456789abcdefghijklmnopqrs');assert.equal(firstTry.provider.model,'');assert.equal(firstTry.verify,true);
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/^Google did not accept this API key\./);
    assert(await page.locator('#boxer-chat-settings').isVisible(),'A failed connection stays on the settings view.');
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · not connected · see Key');
    await page.evaluate(()=>{googleMode='offline';});await page.click('#boxer-chat-key-connect');
    await page.waitForFunction(()=>document.getElementById('boxer-chat-settings-status').textContent.includes('offline'));
    // The same button then connects, selects a model and returns to the conversation.
    await page.evaluate(()=>{googleMode='ok';});await page.locator('#boxer-chat-api-key').press('Enter');
    await page.waitForFunction(()=>document.getElementById('boxer-chat-settings').hidden);
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · connected · gemini-3.8-flash');
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/Connected to Gemini · model gemini-3\.8-flash/);
    assert(await page.locator('#boxer-chat-banner').isHidden());assert(await page.locator('.boxer-chat-voice-tools').isVisible());
    assert.equal(await page.evaluate(()=>document.activeElement.id),'boxer-chat-prompt');
    const afterConnect=await page.locator('#boxer-chat-transcript').evaluate(element=>element.getBoundingClientRect().height);
    assert(afterConnect>250&&afterConnect>roomy-170,'Settings never share the panel with the conversation: '+afterConnect+' of '+roomy);
    await openSettings();
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/^Connected to Gemini 3\.8 Flash \(gemini-3\.8-flash\)\. The model answered a short test request\./);
    assert.equal(await page.locator('#boxer-chat-settings-status').getAttribute('data-state'),'ok');
    assert(await page.locator('#boxer-chat-model-field').isVisible());assert.equal(await page.locator('#boxer-chat-model-choice').inputValue(),'gemini-3.8-flash');
    assert.deepEqual(await page.locator('#boxer-chat-model-choice optgroup').evaluateAll(groups=>groups.map(group=>[group.label,[...group.children].map(option=>option.value)])),
      [['Recommended for Boxer',['gemini-3.8-flash','gemini-3.5-flash-lite']],['Other chat models',['gemini-2.5-flash','gemini-4-carbon']],['Other models listed for your key',['gemini-omni-1.2-flash']]]);
    assert.equal(await page.inputValue('#boxer-chat-speech-model'),'gemini-3.8-flash-tts');
    assert.deepEqual(await explained(),[]);
    // Choosing another model keeps the connection; Connect then tests exactly that model.
    await page.selectOption('#boxer-chat-model-choice','gemini-4-carbon');
    assert.equal(await page.inputValue('#boxer-chat-model'),'gemini-4-carbon');assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · connected · gemini-4-carbon');
    await page.evaluate(()=>{googleMode='unverified';});await page.click('#boxer-chat-key-connect');
    await page.waitForFunction(()=>document.getElementById('boxer-chat-settings-status').dataset.state==='error');
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/test').at(-1).body.provider.model),'gemini-4-carbon');
    assert.match(await page.locator('#boxer-chat-settings-status').innerText(),/“gemini-4-carbon” did not answer a short test request.*choose another model/);
    assert(await page.locator('#boxer-chat-settings').isVisible());assert.equal(await page.locator('#boxer-chat-model-choice').inputValue(),'gemini-4-carbon');
    await page.selectOption('#boxer-chat-model-choice','gemini-3.5-flash-lite');await page.evaluate(()=>{googleMode='ok';});await page.click('#boxer-chat-key-connect');
    await page.waitForFunction(()=>document.getElementById('boxer-chat-settings').hidden);
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · connected · gemini-3.5-flash-lite');
    // A typed model name is accepted with or without Google's “models/” prefix.
    await openSettings();await page.fill('#boxer-chat-model','models/gemini-3.8-flash');await closeSettings();
    await page.evaluate(()=>{aiMode='normal';aiRound=0;chat.send('Set the upper skin to 3 mm.');});await page.waitForFunction(()=>!chat.busy);
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/message')[0].body.provider.model),'gemini-3.8-flash');
    // A provider problem names what to do and offers Settings.
    await page.evaluate(()=>{aiMode='quota';chat.send('Another request.');});await page.waitForFunction(()=>!chat.busy);
    const quota=page.locator('.boxer-chat-message').last();
    assert.match(await quota.innerText(),/^ASSISTANT\s+Today's allowance for the model/i);assert(!(await quota.innerText()).includes('Boxer chat.'));
    await quota.getByRole('button',{name:'Open the Key view',exact:true}).click();assert(await page.locator('#boxer-chat-settings').isVisible());
    console.log('9. Gemini through the Boxer program is an advanced option: the key is cleaned, the model is chosen and tested, every advanced option is explained and each failure states its remedy.');

    // With the key removed the request is still served by the built-in commands.
    await page.click('#boxer-chat-clear-key');await closeSettings();
    assert(await page.locator('#boxer-chat-banner').isVisible());assert.match(await page.locator('#boxer-chat-banner').innerText(),/^Gemini is not connected: simple commands only\.\s+Details$/);
    assert(await page.locator('.boxer-chat-voice-tools').isHidden());
    const before9=await page.evaluate(()=>({messages:requests.filter(request=>request.url==='/api/chat/message').length,dispatched:dispatched.length}));
    await page.fill('#boxer-chat-prompt','make the aspect ratio = 15');await page.locator('#boxer-chat-prompt').press('Enter');await page.waitForFunction(()=>!chat.busy);
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'aspect',value:15});
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url==='/api/chat/message').length),before9.messages);
    assert.match(await page.locator('.boxer-chat-message.boxer-chat-tool').last().innerText(),/Set “Base aspect ratio” \(Planform\) to 15 \(it was 8\)\./);
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/not connected yet, so I handled this with the built-in commands/);
    await page.locator('#boxer-chat-banner-button').click();assert(await page.locator('#boxer-chat-settings').isVisible());
    await page.setViewportSize({width:320,height:700});
    const narrow=await page.locator('#boxer-chat-settings .boxer-chat-overlay-body').evaluate(element=>({scroll:element.scrollWidth,client:element.clientWidth,connect:document.getElementById('boxer-chat-key-connect').getBoundingClientRect()}));
    assert(narrow.scroll<=narrow.client+1,'The Key view does not scroll sideways at 320 pixels.');assert(narrow.connect.left>=0&&narrow.connect.right<=320);
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'advanced_gemini_through_boxer_mobile.png')});
    await page.locator('#boxer-chat-api-key').press('Escape');assert(await page.locator('#boxer-chat-settings').isHidden());assert(await page.locator('#boxer-chat').isVisible(),'Escape leaves settings before it closes the panel.');
    await page.setViewportSize({width:1100,height:850});
    // A key that Google rejects when the first message is sent: the request is served locally, once, with the reason.
    await openSettings();await page.check('#boxer-chat-mode-commands');await page.check('#boxer-chat-mode-google');await page.fill('#boxer-chat-api-key','AIzaSy-REJECTED-0123456789abcdefghijk');await closeSettings();
    await page.evaluate(()=>{googleMode='invalid';});
    const rejected=await page.evaluate(()=>({messages:requests.filter(request=>request.url==='/api/chat/message').length,tests:requests.filter(request=>request.url==='/api/chat/test').length}));
    await page.evaluate(()=>chat.send('set aspect ratio to 11'));await page.waitForFunction(()=>!chat.busy);
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'aspect',value:11});
    assert.match(await page.locator('.boxer-chat-message').last().innerText(),/handled this with the built-in commands\. The connection reported: Google did not accept this API key/);
    assert.equal(await page.locator('#boxer-chat-status').innerText(),'Gemini · not connected · see Key');
    await page.evaluate(()=>chat.send('set aspect ratio to 12'));await page.waitForFunction(()=>!chat.busy);
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'aspect',value:12});
    assert.deepEqual(await page.evaluate(()=>({messages:requests.filter(request=>request.url==='/api/chat/message').length,tests:requests.filter(request=>request.url==='/api/chat/test').length})),{messages:rejected.messages,tests:rejected.tests+1},'A rejected key is not tried again with every message.');
    console.log('10. An AI option without a usable connection still serves simple requests locally and says why; settings fit 320 pixels and close with Escape.');

    // ---- Built-in commands in ordinary words ----------------------------------------
    await openSettings();await page.check('#boxer-chat-mode-commands');await closeSettings();
    const say=async text=>{await page.evaluate(value=>chat.send(value),text);await page.waitForFunction(()=>!chat.busy);return page.locator('.boxer-chat-message').last();};
    const phrases=[['make the aspect ratio = 15','aspect',15],['Make the Aspect Ratio = 9.5','aspect',9.5],['set aspect ratio to 12','aspect',12],['change the aspect ratio to 11','aspect',11],['put the aspect ratio at 10','aspect',10],
      ['use an aspect ratio of 9','aspect',9],['use 8 for the aspect ratio','aspect',8],['aspect ratio = 7,5','aspect',7.5],['aspect ratio: 7','aspect',7],['aspect ratio 6','aspect',6],['AR = 15','aspect',15],
      ['please could you set the aspect ratio to 14?','aspect',14],['I want the aspect ratio to be 13','aspect',13],['the aspect ratio should be 12','aspect',12],['make the asect ratio = 15','aspect',15],['set aspect ratios to 14','aspect',14],
      ['set sweep to 25 deg','sweep',25],['set the sweep angle to 20°','sweep',20],['set sweep to 0.5 rad','sweep',28.6478897565],['increase the sweep by 2 degrees','sweep',30.6478897565],['reduce sweep by 50%','sweep',15.3239448783],
      ['set upper skin thickness to 2,5 mm','upper',2.5],['put 3 mm as upper skin thickness','upper',3],['set top skin gauge to 0.004 m','upper',4],['set wing area to 45 m2','area',45],
      ['set solution to buckling','solution','105'],['use solution 101','solution','101'],['set model title to Wing A and B','title','Wing A and B'],['turn wake filaments on','wake',true],['disable the wake filaments','wake',false]];
    for(const [text,input,value] of phrases){
      const count=await page.evaluate(()=>dispatched.length);await say(text);
      const sent=await page.evaluate(()=>dispatched.slice(-1)[0]);
      assert.equal(await page.evaluate(()=>dispatched.length),count+1,text+' must run exactly one command.');
      assert.equal(sent.command,'set_input',text);assert.equal(sent.arguments.input_id,input,text);
      if(typeof value==='number')assert(Math.abs(sent.arguments.value-value)<1e-6,text+' → '+sent.arguments.value);else assert.equal(sent.arguments.value,value,text);
    }
    assert.match(await (await say('make the asect ratio = 15')).innerText(),/I read “asect ratio” as “Base aspect ratio”/);
    assert.match(await (await say('what is the aspect ratio?')).innerText(),/“Base aspect ratio” \(Planform\) is currently 15\./);
    let count=await page.evaluate(()=>dispatched.length);await say('set aspect ratio to 9 and sweep to 20');
    assert.deepEqual(await page.evaluate(n=>dispatched.slice(n).map(request=>[request.arguments.input_id,request.arguments.value]),count),[['aspect',9],['sweep',20]]);
    for(const [text,action] of [['go to the materials tab','tab.materials'],['open materials','tab.materials'],['create the mesh','mesh.create'],['generate fem','mesh.create'],['run the analysis','run.analysis'],['stres report','open.stress']]){
      await say(text);assert.equal(await page.evaluate(()=>dispatched.at(-1).arguments.action_id),action,text);
    }
    console.log('11. '+(phrases.length+9)+' ordinary phrasings, including “make the aspect ratio = 15”, verbs, “=”, “of”, units, decimal commas, typos and two requests in one sentence, run the intended command.');

    // What cannot be resolved is restated, with the nearest names and working examples.
    count=await page.evaluate(()=>dispatched.length);
    for(const [text,patterns,choicesShown] of [
      ['set skin thickness to 2',[/I understood: set “skin thickness” to “2”\./,/Several inputs fit “skin thickness”\. Choose the one to change/],4],
      ['open ribs',[/I understood: run the menu action “ribs”\./,/Several menu actions fit\. Choose the one you want\./],2],
      ['set aspect ratio to 15 mm',[/I understood: set “aspect ratio” to “15 mm”\./,/shows no unit in Boxer, but the value was given in “mm”/],1],
      ['set sweep to 1,200',[/“1,200” can mean 1\.200 or 1200/],1],
      ['set solution to 999',[/Solution has no choice like “999”\. It accepts: “101 · Static”, “103 · Normal modes”, “105 · Buckling”/],1],
      ['set aspect to plenty',[/I understood: set “aspect” to “plenty”\./,/needs a number, but “plenty” is not one/],1],
      ['change the sweep',[/I understood: change “sweep” \(no new value given\)\./,/say for example “set sweep to 5”/],1],
      ['set flux capacitor to 88',[/I understood: set “flux capacitor” to “88”\./,/Boxer has no input with a name like “flux capacitor”, so nothing was done\./,/Requests that work here: “set [a-z ]+ to [-\d.]+” or “Create FEM”/,/“find flux”/,/connect Gemini with the Key button/],0],
      ['delete the wing',[/I understood: run the menu action “delete the wing”\./,/so nothing was done/,/The closest names are listed below/,/Closest inputs/,/Requests that work here/],2],
      ['email the report to my boss',[/I understood: run the menu action “email the report to my boss”\./,/Requests that work here/],null],
      ['undo',[/I understood: run the menu action “undo”\./,/Nothing with a similar name exists in the current Study\./,/Requests that work here/],0],
      ['asdfgh qwerty',[/I understood:/,/so nothing was done/,/Requests that work here/],0],
      ['set aspect ratio to 9 and flux capacitor to 3',[/I understood: set “aspect ratio to 9 and flux capacitor” to “3”\./,/so nothing was done/],null]]){
      const message=await say(text),content=await message.innerText();
      for(const pattern of patterns)assert.match(content,pattern,text);
      assert(content.replace(/^ASSISTANT\s*/,'').length>60,text+' must never end with an empty or generic reply.');
      if(choicesShown!==null)assert.equal(await message.locator('.boxer-chat-choice').count(),choicesShown,text+' choices: '+content);
    }
    assert.equal(await page.evaluate(()=>dispatched.length),count,'Unresolved, ambiguous and unreadable requests change nothing.');
    assert.equal(await page.evaluate(()=>requests.filter(request=>request.url.startsWith('/api/chat/message')).length),before9.messages,'Built-in commands never contact an AI provider.');
    await (await say('set skin thickness to 2')).getByRole('button',{name:'Set',exact:true}).nth(1).click();await page.waitForFunction(()=>!chat.busy);
    assert.deepEqual(await page.evaluate(()=>dispatched.at(-1).arguments),{input_id:'lower',value:2});
    assert.match(await (await say('help')).innerText(),/set aspect ratio to 15.*If a name fits several items I ask you to choose/s);
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'commands_desktop.png')});
    await page.evaluate(()=>chat.destroy());assert.deepEqual(errors,[]);
    console.log('12. Ambiguous names ask for a choice; unknown names, unreadable values and impossible requests are restated with the closest names and working examples, and change nothing.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
