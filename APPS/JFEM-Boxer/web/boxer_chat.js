(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.WingBoxerChat=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';

  const TOOLS=new Set(['get_state','list_actions','list_inputs','invoke_action','set_input','update_parameters','navigate']);
  const MUTATIONS=new Set(['invoke_action','set_input','update_parameters','navigate']);
  const REPLACES_STUDY=new Set(['new_study','open_study','read_nastran','read_abaqus','btn-new-study','btn-load-model','btn-load-toml','btn-read-reference','btn-read-abaqus','btn-read-results']);
  const clean=value=>String(value??'').replace(/\s+/g,' ').trim();
  const normalize=value=>clean(value).toLowerCase().replace(/[“”‘’"'!?.,]/g,'').replace(/\b(?:please|the|a|an)\b/g,' ').replace(/\s+/g,' ').trim();
  const entryId=(entry={})=>entry.action_id??entry.input_id??entry.id??entry.key;
  const entryLabel=(entry={})=>clean(entry.label??entry.name??entry.title??entryId(entry));
  const entryContext=entry=>clean(Array.isArray(entry.path)?entry.path.join(' / '):entry.context??entry.group??entry.path??'');
  const enabled=entry=>entry.enabled!==false&&entry.disabled!==true&&entry.readonly!==true&&entry.editable!==false;

  // Provider context never contains credential fields, inline images or an
  // unbounded model/result payload. Read-only tools can discover more as needed.
  function compact(value,depth=0){
    if(depth>7)return '[Details available through Boxer tools]';
    if(value===null||typeof value==='boolean'||typeof value==='number')return value;
    if(typeof value==='string')return /^(?:data:|[A-Za-z0-9+/]{500,}={0,2}$)/.test(value)?'[Inline asset omitted]':value.slice(0,4000);
    if(Array.isArray(value))return value.slice(0,60).map(item=>compact(item,depth+1));
    if(typeof value==='object'){
      const out={};
      for(const [key,item] of Object.entries(value).slice(0,100)){
        if(/(?:api[_-]?key|password|credential|authorization|bearer|^token$|^secret$|image_data|base64)/i.test(key))continue;
        out[key]=compact(item,depth+1);
      }
      return out;
    }
    return null;
  }

  function numericValue(text,entry){
    const value=clean(text),boolean=normalize(value),booleanInput=['checkbox','radio'].includes(entry?.type)||entry?.kind==='boolean'||typeof entry?.value==='boolean';
    if(booleanInput&&['true','on','yes','enabled','show'].includes(boolean))return true;
    if(booleanInput&&['false','off','no','disabled','hide'].includes(boolean))return false;
    if((value.startsWith('"')&&value.endsWith('"'))||(value.startsWith("'")&&value.endsWith("'")))return value.slice(1,-1);
    const number=value.match(/^([-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?)\s*([a-z°%/²³0-9-]*)$/i);
    if(number){
      let result=Number(number[1]);
      if(!Number.isFinite(result))throw Error('Enter a finite numeric value.');
      const unit=value=>clean(value).toLowerCase().replaceAll('²','2').replaceAll('³','3');
      const supplied=unit(number[2]);
      const target=unit(entry?.units??entry?.unit??'')||unit((entryLabel(entry).match(/\((mm|cm|m|ft|in|deg|°|kg|n|mpa|gpa|%)\)/i)||[])[1]||'');
      if(supplied&&supplied!==target){
        const length={mm:.001,cm:.01,m:1,ft:.3048,in:.0254};
        if(length[supplied]&&length[target])result*=length[supplied]/length[target];
        else if(supplied==='gpa'&&target==='mpa')result*=1000;
        else if(supplied==='mpa'&&target==='gpa')result/=1000;
        else if(!(supplied==='deg'&&target==='°'||supplied==='°'&&target==='deg'))throw Error('The requested unit “'+number[2]+'” does not match the units shown for '+entryLabel(entry)+'.');
      }
      return result;
    }
    return value;
  }

  function create(options={}){
    const doc=options.document||document,win=doc.defaultView,commands=options.commands;
    if(!commands)throw Error('Boxer chat requires the shared command controller.');
    if(doc.getElementById('boxer-chat'))throw Error('Boxer chat is already installed.');
    const fetcher=options.fetch||globalThis.fetch.bind(globalThis);
    const toggle=doc.getElementById(options.toggleId||'boxer-chat-toggle');
    const listeners=[];
    const node=(tag,className,text)=>{const element=doc.createElement(tag);if(className)element.className=className;if(text!==undefined)element.textContent=text;return element;};
    const button=(text,title,action)=>{const element=node('button','',text);element.type='button';if(title)element.title=title;if(action)listen(element,'click',action);return element;};
    const label=(text,input)=>{const element=node('label','boxer-chat-label');element.append(node('span','',text),input);return element;};
    function listen(target,type,handler,opts){target.addEventListener(type,handler,opts);listeners.push(()=>target.removeEventListener(type,handler,opts));}
    let destroyed=false,opened=false,busy=false,abort=null,timer=null,started=0,requestEpoch=0,history=[],configLoaded=false,priorFocus=null;
    let settingsBusy=false,settingsAbort=null,mcpAbort=null,mcpJSON='',mcpEpoch=0,keyOrigin='';
    let activeStudyEpoch,activeStudyRevision,historyStudyEpoch,providerState=null,serverDefaults=null,googleConfig={};
    let voice=null,voicePhase='idle',voiceEpoch=0,voiceAbort=null,voiceTimer=null,voiceStarted=0,recordingSession=null,cachedSpeech=null,lastReply=null,promptRevision=0,connectionSettingsRevision=0,observedStudyEpoch;

    const panel=node('section','boxer-chat');panel.id='boxer-chat';panel.hidden=true;panel.dataset.boxerPrivate='chat';
    panel.setAttribute('role','region');panel.setAttribute('aria-labelledby','boxer-chat-title');
    const header=node('header','boxer-chat-header'),heading=node('div','boxer-chat-heading');
    const title=node('strong','','Boxer assistant');title.id='boxer-chat-title';
    const connection=node('small','boxer-chat-connection','Menu commands · runs locally');heading.append(title,connection);
    const helpButton=button('Help','Step-by-step Google AI, voice and assistant setup',()=>showHelp(true));helpButton.id='boxer-chat-help';helpButton.className='boxer-chat-help-button';helpButton.setAttribute('aria-expanded','false');helpButton.setAttribute('aria-controls','boxer-chat-help-panel');
    const settingsButton=button('Settings','Choose command mode, connect an AI model or copy MCP connection settings',()=>{
      settings.hidden=!settings.hidden;settingsButton.setAttribute('aria-expanded',String(!settings.hidden));
      if(!settings.hidden){loadConfig();loadMCPConfig();}else{mcpEpoch++;mcpAbort?.abort();mcpAbort=null;}
    });
    settingsButton.setAttribute('aria-expanded','false');settingsButton.setAttribute('aria-controls','boxer-chat-settings');
    const expand=button('Expand','Expand the assistant panel',()=>{panel.classList.toggle('boxer-chat-expanded');expand.textContent=panel.classList.contains('boxer-chat-expanded')?'Restore':'Expand';expand.setAttribute('aria-pressed',String(panel.classList.contains('boxer-chat-expanded')));});
    expand.setAttribute('aria-pressed','false');
    const closeButton=button('×','Close assistant',close);closeButton.setAttribute('aria-label','Close Boxer assistant');
    const headerButtons=node('div','boxer-chat-header-buttons');headerButtons.append(helpButton,settingsButton,expand,closeButton);header.append(heading,headerButtons);

    const settings=node('section','boxer-chat-settings');settings.id='boxer-chat-settings';settings.hidden=true;settings.setAttribute('aria-label','Assistant connection settings');
    const mode=node('select');mode.id='boxer-chat-mode';
    for(const [value,text] of [['commands','Menu commands · no AI needed'],['google','Google AI · Gemini'],['ollama','Local AI · Ollama'],['compatible','AI · compatible API']]){const opt=node('option','',text);opt.value=value;mode.append(opt);}
    mode.title='Menu commands work locally. Choose an AI provider for conversational requests and multi-step actions.';
    const aiFields=node('div','boxer-chat-ai-fields');aiFields.hidden=true;
    const endpoint=node('input');endpoint.type='url';endpoint.id='boxer-chat-endpoint';endpoint.value='http://127.0.0.1:11434';endpoint.placeholder='http://127.0.0.1:11434';endpoint.spellcheck=false;endpoint.autocomplete='off';endpoint.title='The selected AI server. Ollama uses its server root. A compatible API uses its /v1 base URL.';
    const model=node('input');model.id='boxer-chat-model';model.type='text';model.placeholder='Choose or enter a model';model.autocomplete='off';model.spellcheck=false;model.setAttribute('list','boxer-chat-models');model.title='Model name as reported by the selected AI server.';
    const models=node('datalist');models.id='boxer-chat-models';
    const apiKey=node('input');apiKey.id='boxer-chat-api-key';apiKey.type='password';apiKey.autocomplete='off';apiKey.spellcheck=false;apiKey.dataset.secret='true';apiKey.placeholder='Optional · server environment may provide it';apiKey.title='Kept only in this page’s memory and sent to the Boxer server for this provider. It is never saved to the Study or browser storage.';
    const keyLabel=label('API key',apiKey);
    const providerNote=node('p','boxer-chat-note','The selected AI provider receives your messages and a compact Study description. Background images and result files are not attached.');
    const serverKeyNote=node('p','boxer-chat-note');serverKeyNote.hidden=true;
    const testButton=button('Test connection','List models from the selected AI provider',testConnection);
    const clearKey=button('Clear key','Remove the API key from this page',()=>{apiKey.value='';connectionChanged();settingsStatus.textContent='The key has been cleared from this page.';});
    const settingsActions=node('div','boxer-chat-settings-actions');settingsActions.append(testButton,clearKey);
    const settingsStatus=node('p','boxer-chat-settings-status');settingsStatus.setAttribute('role','status');
    aiFields.append(label('Server URL',endpoint),label('Model',model),models,keyLabel,providerNote,serverKeyNote,settingsActions,settingsStatus);
    const voiceSettings=node('fieldset','boxer-chat-voice-settings');voiceSettings.hidden=true;voiceSettings.append(node('legend','','Google voice'));
    const transcriptionModel=node('input');transcriptionModel.id='boxer-chat-transcription-model';transcriptionModel.placeholder='Use the selected chat model';transcriptionModel.setAttribute('list','boxer-chat-models');transcriptionModel.title='An available Gemini model that accepts audio. Blank uses the selected conversation model.';
    const speechModel=node('input');speechModel.id='boxer-chat-speech-model';speechModel.placeholder='Select an available TTS model';speechModel.setAttribute('list','boxer-chat-speech-models');speechModel.title='A Google speech-generation model listed for your key. Reply speech is optional and may have different pricing and quotas.';
    const speechModels=node('datalist');speechModels.id='boxer-chat-speech-models';
    const speechVoice=node('select');speechVoice.id='boxer-chat-voice';speechVoice.title='Google’s named prebuilt voice for reply audio.';const initialVoice=node('option','','Kore');initialVoice.value='Kore';speechVoice.append(initialVoice);
    voiceSettings.append(label('Transcription model',transcriptionModel),label('Reply speech model',speechModel),speechModels,label('Reply voice',speechVoice),node('p','boxer-chat-note','Voice uses your selected Google connection. Recordings are limited to 60 seconds. The transcript is placed in your message for review and is never sent as a command automatically. Reply speech is generated only when you press Read last reply.'));
    aiFields.append(voiceSettings);
    const commandsNote=node('p','boxer-chat-note','Use the same actions and inputs as the menus. Try “Create FEM”, “open Geometry”, or “set wing area to 40”. Ambiguous requests show choices. Connect an AI model for conversational requests.');
    settings.append(label('Assistant mode',mode),commandsNote,aiFields);
    const mcp=node('section','boxer-chat-mcp');mcp.setAttribute('aria-labelledby','boxer-chat-mcp-title');
    const mcpTitle=node('strong','','Connect another assistant');mcpTitle.id='boxer-chat-mcp-title';
    const mcpEndpoint=node('input');mcpEndpoint.id='boxer-chat-mcp-endpoint';mcpEndpoint.type='text';mcpEndpoint.readOnly=true;mcpEndpoint.placeholder='Open settings to read the local MCP connection';mcpEndpoint.title='The local Boxer MCP endpoint. Authentication remains in the private server discovery file.';
    const mcpStatus=node('p','boxer-chat-settings-status');mcpStatus.setAttribute('role','status');
    const mcpCopy=button('Copy MCP configuration','Copy the MCP client configuration without connection tokens',copyMCP);mcpCopy.id='boxer-chat-mcp-copy';mcpCopy.disabled=true;
    const mcpDetails=node('details','boxer-chat-mcp-details');mcpDetails.append(node('summary','','MCP configuration JSON'));
    const mcpText=node('textarea');mcpText.id='boxer-chat-mcp-config';mcpText.readOnly=true;mcpText.rows=5;mcpText.spellcheck=false;mcpText.setAttribute('aria-label','MCP client configuration JSON');mcpText.title='Select and copy this configuration if your browser cannot access the clipboard.';mcpDetails.append(mcpText);
    mcp.append(mcpTitle,node('p','boxer-chat-note','Keep Boxer and its browser tab open. If several tabs are connected, select the intended client ID in your assistant.'),
      label('Local MCP endpoint',mcpEndpoint),mcpCopy,mcpStatus,mcpDetails);settings.append(mcp);

    const transcript=node('div','boxer-chat-transcript');transcript.id='boxer-chat-transcript';transcript.setAttribute('role','log');transcript.setAttribute('aria-live','polite');transcript.setAttribute('aria-relevant','additions');transcript.setAttribute('aria-label','Conversation');transcript.tabIndex=0;
    const welcome=node('div','boxer-chat-welcome');welcome.append(node('h3','','What would you like to do?'),node('p','','Find a menu action, change an input, inspect the current Study, or connect an AI model for a longer workflow.'));
    const examples=node('div','boxer-chat-examples');
    for(const example of ['Show Study status','Create FEM','Find skin thickness inputs','Open Stress Report'])examples.append(button(example,'Send this request to the assistant',()=>send(example)));
    welcome.append(examples);transcript.append(welcome);
    const operation=node('div','boxer-chat-operation');operation.hidden=true;operation.setAttribute('role','status');operation.setAttribute('aria-live','polite');
    const spinner=node('span','boxer-chat-spinner');spinner.setAttribute('aria-hidden','true');const phase=node('span','boxer-chat-phase'),clock=node('span','boxer-chat-clock');clock.setAttribute('aria-live','off');operation.append(spinner,phase,clock);
    const form=node('form','boxer-chat-compose');const prompt=node('textarea');prompt.id='boxer-chat-prompt';prompt.rows=2;prompt.maxLength=12000;prompt.placeholder='Ask Boxer to do something…';prompt.setAttribute('aria-label','Message to Boxer');prompt.setAttribute('aria-describedby','boxer-chat-compose-note');
    const controls=node('div','boxer-chat-compose-actions');const sendButton=button('Send','Send message');sendButton.type='submit';sendButton.classList.add('boxer-chat-primary');
    const stopButton=button('Stop','Stop this chat request. Actions already sent to Boxer may continue.',stop);stopButton.hidden=true;
    const clearButton=button('Clear conversation','Clear this page’s conversation',clear);
    const footnote=node('small','boxer-chat-compose-note','Enter to send · Shift+Enter for a new line');footnote.id='boxer-chat-compose-note';controls.append(clearButton,stopButton,sendButton);form.append(prompt,controls,footnote);
    const voiceTools=node('div','boxer-chat-voice-tools');voiceTools.hidden=true;
    const recordButton=button('Record voice','Record your microphone and send the stopped recording to Google for transcription',recordVoice);recordButton.id='boxer-chat-record';
    const voiceCancel=button('Cancel voice','Discard this recording or cancel the pending voice request',()=>cancelVoice('Voice request cancelled.'));voiceCancel.id='boxer-chat-voice-cancel';voiceCancel.hidden=true;
    const speakButton=button('Read last reply','Generate and play the latest assistant reply using the selected Google speech model',()=>readReply());speakButton.id='boxer-chat-speak';
    const audioStop=button('Stop audio','Stop reply generation or audio playback',()=>cancelVoice('Reply audio stopped.'));audioStop.id='boxer-chat-audio-stop';audioStop.hidden=true;
    const voiceStatus=node('span','boxer-chat-voice-status');voiceStatus.id='boxer-chat-voice-status';voiceStatus.setAttribute('role','status');
    const voiceClock=node('span','boxer-chat-voice-clock');voiceClock.id='boxer-chat-voice-clock';voiceClock.setAttribute('aria-live','off');
    const voiceMeter=node('meter','boxer-chat-voice-meter');voiceMeter.min=0;voiceMeter.max=1;voiceMeter.value=0;voiceMeter.setAttribute('aria-label','Microphone input level');voiceMeter.hidden=true;
    const voiceButtons=node('div','boxer-chat-voice-buttons');voiceButtons.append(recordButton,voiceCancel,speakButton,audioStop);
    const voiceNotice=node('small','boxer-chat-note','Record, stop, review the transcript, then Send. Audio is sent to Google when recording stops.');
    const voiceStatusLine=node('div','boxer-chat-voice-status-line');voiceStatusLine.append(voiceStatus,voiceClock,voiceMeter);voiceTools.append(voiceButtons,voiceNotice,voiceStatusLine);form.prepend(voiceTools);
    const help=node('section','boxer-chat-help');help.id='boxer-chat-help-panel';help.hidden=true;help.setAttribute('role','dialog');help.setAttribute('aria-labelledby','boxer-chat-help-title');
    const helpHeader=node('header','boxer-chat-help-heading'),helpTitle=node('strong','','Assistant setup & voice help');helpTitle.id='boxer-chat-help-title';
    const helpBack=button('Back to chat','Close help and return to the conversation',()=>showHelp(false));helpHeader.append(helpTitle,helpBack);
    const helpBody=node('div','boxer-chat-help-body');helpBody.tabIndex=0;
    const step=(title,text,url,linkText)=>{const item=node('li');item.append(node('strong','',title),node('p','',text));if(url){const link=node('a','',linkText||'Open official instructions');link.href=url;link.target='_blank';link.rel='noopener noreferrer';item.append(link);}return item;};
    const setupSteps=node('ol');setupSteps.append(
      step('Check Google AI Studio access','Sign in with your Google account. Gemini API access requires an eligible account, age 18 or older and a supported country or region. A Google account alone does not guarantee API access, a free tier or every model.','https://ai.google.dev/gemini-api/docs/available-regions','Supported regions and eligibility'),
      step('Create an API key for a project','Open Google AI Studio → API keys. Create or select a Google Cloud project, then create a Gemini API key. Copy the key, not your Google password. Follow Google’s project and API restrictions if your organization manages the account.','https://aistudio.google.com/apikey','Open Google AI Studio API keys'),
      step('Connect Boxer','Close this help with Back to chat, open Settings, choose Google AI · Gemini and paste the key into API key. The Google server URL is filled in for you. The key stays in this page’s memory or your configured Boxer server; it is not saved in your Study.'),
      step('Test and choose an available model','Press Test connection to list the models available to this key. Choose an available text/tool-capable Gemini model, often a Flash or Flash-Lite model. Names and access change; a model visible in older tutorials may not be available to a new project. Test connection lists models and does not generate an answer.','https://ai.google.dev/gemini-api/docs/models','Current Gemini models'),
      step('Check free-tier limits before generating','Some models and eligible projects offer free developer usage within quotas. Free access, model eligibility, rate limits and data-use terms vary. Reply speech has its own availability and pricing. Do not enable billing unless you intend to use paid capacity. Review the current model’s pricing and limits.','https://ai.google.dev/gemini-api/docs/pricing','Google Gemini API pricing'),
      step('Send a small first request','Try “Show Study status” or “Open Geometry”. After that, request a specific change with its units. Boxer uses its existing menus and validation. A solver button starts an analysis; its progress and results determine completion. Study replacement or an intervening manual edit stops stale chat actions.'));
    helpBody.append(node('h3','','1 · Set up Google Gemini'),setupSteps,node('h3','','2 · Use voice'));
    const voiceSteps=node('ol');voiceSteps.append(
      step('Choose voice models','In Google voice settings, leave Transcription model blank to use the selected chat model, or select an available audio-capable model. To hear replies, select an available speech-generation/TTS model and a named voice. Speech is optional and is not assumed to be free.','https://ai.google.dev/gemini-api/docs/speech-generation','Google speech-generation guide'),
      step('Record and review','Press Record voice and allow microphone access for the Boxer page. Speak for up to 60 seconds, then press Stop recording. The recording is sent to your selected Google connection for transcription. Read the transcript in the message box and edit it if needed. Nothing is executed until you press Send.','https://ai.google.dev/gemini-api/docs/audio','Google audio-understanding guide'),
      step('Listen and stop','After a reply, press Read last reply. Boxer requests 16-bit WAV reply audio. Press Stop audio at any time. If the browser blocks playback, press Read last reply again to play the prepared audio. Long replies are limited to the first 2,000 characters.'),
      step('Keep control of the microphone','Cancel voice discards the current recording or pending transcription. Closing the chat, changing its AI connection or replacing the Study stops voice activity. Recordings and reply audio are held only in memory and are not added to the Study or browser storage.'));
    helpBody.append(voiceSteps,node('h3','','3 · Troubleshoot'));
    const troubles=node('ul');for(const text of ['No key or 401/403: use a Gemini API key from AI Studio, check project/API restrictions and account eligibility. A Google sign-in session is not an API key.','Model not found or 404: run Test connection again and select a model listed for this key. Chat, audio understanding and speech generation are separate capabilities.','Quota or 429: wait for the limit to reset or choose a model/project with available quota. Check current free-tier and rate limits; changing accounts or enabling billing is not required by Boxer.','Microphone denied or unavailable: allow it in your browser’s site permissions and use a current browser on localhost or HTTPS. Connect a microphone if no device is found.','No reply audio: select a TTS model and voice, check system sound output and press Read last reply explicitly. Browser speech recognition is never used as a hidden fallback.','Network or company restrictions: verify that your network permits the Google Generative Language API. Keep the Boxer server running while using the page.'])troubles.append(node('li','',text));
    const limits=node('a','','Google rate-limit guide');limits.href='https://ai.google.dev/gemini-api/docs/rate-limits';limits.target='_blank';limits.rel='noopener noreferrer';helpBody.append(troubles,limits);
    const helpFooter=node('footer','boxer-chat-help-footer');helpFooter.append(button('Close help','Return to the conversation',()=>showHelp(false)));help.append(helpHeader,helpBody,helpFooter);
    const resize=node('div','boxer-chat-resizer');resize.tabIndex=0;resize.setAttribute('role','separator');resize.setAttribute('aria-label','Resize assistant width');resize.setAttribute('aria-orientation','vertical');resize.title='Drag to resize. Arrow keys change the panel width.';
    panel.append(resize,header,settings,transcript,operation,form,help);doc.body.append(panel);
    const voiceAPI=options.voice||win.WingBoxerVoice;
    if(voiceAPI?.create)voice=voiceAPI.create({window:win,...options.voiceOptions,onUpdate:updateVoice,onLimit:()=>finishVoice()});
    observedStudyEpoch=studyEpoch();
    updateVoiceControls();
    if(toggle){toggle.setAttribute('aria-controls',panel.id);toggle.setAttribute('aria-expanded','false');listen(toggle,'click',()=>opened?close():open());}

    function scroll(){transcript.scrollTop=transcript.scrollHeight;}
    function formatted(container,text){
      for(const part of String(text).split(/(```[\s\S]*?```)/g)){
        if(!part)continue;
        if(part.startsWith('```')&&part.endsWith('```')){
          let code=part.slice(3,-3);if(/^[a-z0-9_-]+\r?\n/i.test(code))code=code.replace(/^[a-z0-9_-]+\r?\n/i,'');
          const pre=node('pre','boxer-chat-code');pre.append(node('code','',code.trim()));container.append(pre);
        }else{
          const paragraph=node('p');
          for(const token of part.split(/(\*\*[^*\n]+\*\*|`[^`\n]+`)/g)){
            if(token.startsWith('**')&&token.endsWith('**'))paragraph.append(node('strong','',token.slice(2,-2)));
            else if(token.startsWith('`')&&token.endsWith('`'))paragraph.append(node('code','',token.slice(1,-1)));
            else paragraph.append(doc.createTextNode(token));
          }
          container.append(paragraph);
        }
      }
    }
    function addMessage(role,text,extra){
      if(destroyed)return null;welcome.hidden=true;
      const row=node('article','boxer-chat-message boxer-chat-'+role);row.dataset.role=role;
      const name=node('strong','boxer-chat-message-label',role==='user'?'You':role==='tool'?'Boxer action':'Assistant');
      const content=node('div','boxer-chat-message-content');if(text){if(role==='assistant')formatted(content,text);else content.append(node('p','',String(text)));}if(extra)content.append(extra);row.append(name,content);transcript.append(row);
      const rows=transcript.querySelectorAll('.boxer-chat-message');if(rows.length>100)rows[0].remove();scroll();return row;
    }
    function status(text){phase.textContent=text;if(options.log&&text)options.log('Assistant · '+text);}
    function elapsed(){const total=Math.floor(Math.max(0,performance.now()-started)/1000);clock.textContent=Math.floor(total/60)+':'+String(total%60).padStart(2,'0');}
    function setBusy(value,text){
      busy=value;panel.setAttribute('aria-busy',String(value));operation.hidden=!value;sendButton.disabled=value;clearButton.disabled=value;prompt.disabled=value;stopButton.hidden=!value;
      for(const input of settings.querySelectorAll('input,select,button'))input.disabled=value||settingsBusy;
      mcpCopy.disabled=value||!mcpJSON;
      updateVoiceControls();
      if(value){started=performance.now();elapsed();if(timer!==null)clearInterval(timer);timer=setInterval(elapsed,250);status(text||'Preparing request');}
      else{if(timer!==null)clearInterval(timer);timer=null;clock.textContent='';phase.textContent='';if(opened&&!destroyed)prompt.focus();}
    }
    async function request(path,body,signal){
      const response=await fetcher(path,body===undefined?{cache:'no-store',signal}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),cache:'no-store',signal});
      let result;try{result=await response.json();}catch{throw Error('The Boxer assistant returned an unreadable response.');}
      if(!response.ok||result.ok===false)throw Error(result.error||result.message||'Assistant request failed.');return result;
    }
    function provider(){return{kind:mode.value,endpoint:endpoint.value.trim(),model:model.value.trim(),...(mode.value!=='ollama'&&apiKey.value?{api_key:apiKey.value}:{})};}
    function resetHistory(){history=[];providerState=null;}
    function connectionSignature(){return JSON.stringify([mode.value,endpoint.value.trim(),model.value.trim(),apiKey.value]);}
    function connectionChanged(){connectionSettingsRevision++;settingsAbort?.abort();resetHistory();lastReply=null;cancelVoice();updateVoiceControls();}
    function updateVoices(values){
      if(!Array.isArray(values)||!values.length)return;const selected=speechVoice.value;speechVoice.replaceChildren();
      for(const value of values){const name=typeof value==='string'?value:String(value.name||'');if(name){const item=node('option','',name);item.value=name;speechVoice.append(item);}}
      if([...speechVoice.options].some(item=>item.value===selected))speechVoice.value=selected;
    }
    function showHelp(value){
      help.hidden=!value;helpButton.setAttribute('aria-expanded',String(value));
      if(value){cancelVoice();helpBack.focus();}else helpButton.focus();
    }
    function voiceSnapshot(){return{epoch:studyEpoch(),revision:studyRevision(),connection:connectionSignature(),provider:provider(),promptRevision,promptValue:prompt.value,transcriptionModel:transcriptionModel.value.trim()||model.value.trim()};}
    function checkVoice(snapshot,token){
      if(destroyed||token!==voiceEpoch)throw new DOMException('Voice request stopped','AbortError');
      checkStudy(snapshot.epoch);
      if(snapshot.revision!==undefined&&studyRevision()!==undefined&&String(snapshot.revision)!==String(studyRevision()))throw Error('The Study definition changed. The voice request was stopped; record again for the current Study.');
      if(snapshot.connection!==connectionSignature())throw new DOMException('The AI connection changed','AbortError');
    }
    function voiceClockTick(){const seconds=Math.floor(Math.max(0,performance.now()-voiceStarted)/1000);voiceClock.textContent=Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');}
    function voiceProgress(value,text){
      voicePhase=value;voiceStatus.textContent=text||'';
      if(voiceTimer!==null)clearInterval(voiceTimer);voiceTimer=null;
      if(['requesting','recording','transcribing','generating'].includes(value)){voiceStarted=performance.now();voiceClockTick();voiceTimer=setInterval(voiceClockTick,250);}else voiceClock.textContent='';
      updateVoiceControls();
    }
    function updateVoice(info={}){
      if(destroyed)return;voiceMeter.value=Number(info.level)||0;
      if(recordingSession&&['requesting','recording'].includes(voicePhase))try{checkVoice(recordingSession,voiceEpoch);}catch(error){cancelVoice(error.message);return;}
      if(info.error)voiceStatus.textContent=info.error;
      if(voicePhase==='playing'&&!info.playing)voiceProgress('idle',info.error||'Reply playback finished.');
      updateVoiceControls();
    }
    function updateVoiceControls(){
      const google=mode.value==='google',active=voicePhase!=='idle',hasKey=!!apiKey.value||googleConfig.key_configured===true;
      voiceTools.hidden=!google;voiceSettings.hidden=!google;
      recordButton.textContent=voicePhase==='recording'?'Stop recording':'Record voice';
      recordButton.disabled=busy||!voice?.supported||!model.value.trim()||!hasKey||(active&&voicePhase!=='recording');
      recordButton.setAttribute('aria-pressed',String(voicePhase==='recording'));
      voiceCancel.hidden=!['requesting','recording','transcribing'].includes(voicePhase);
      speakButton.disabled=busy||active||!lastReply||!speechModel.value.trim()||!hasKey||!voice;
      audioStop.hidden=!['generating','playing'].includes(voicePhase);voiceMeter.hidden=voicePhase!=='recording';
      if(google&&!active&&!voiceStatus.textContent)voiceStatus.textContent=!voice?.supported?'Microphone recording is unavailable in this browser.':!hasKey?'Add a Gemini API key in Settings to use voice.':'Voice is ready. Review every transcript before Send.';
    }
    function cancelVoice(message){
      voiceEpoch++;voiceAbort?.abort();voiceAbort=null;recordingSession=null;cachedSpeech=null;
      voicePhase='idle';voice?.cancel();voice?.stopPlayback();voiceProgress('idle',message||'');voiceMeter.value=0;
    }
    async function recordVoice(){
      if(voicePhase==='recording')return finishVoice();if(busy||voicePhase!=='idle'||!voice)return;
      const snapshot=voiceSnapshot(),token=++voiceEpoch;recordingSession=snapshot;cachedSpeech=null;voiceProgress('requesting','Waiting for microphone permission…');
      try{await voice.start();checkVoice(snapshot,token);voiceProgress('recording','Recording · press Stop recording when finished.');}
      catch(error){if(token===voiceEpoch){recordingSession=null;voiceProgress('idle',error.name==='AbortError'?'Recording cancelled.':error.message);}}
    }
    async function finishVoice(){
      if(voicePhase!=='recording'||!recordingSession)return;
      const snapshot=recordingSession,token=voiceEpoch;voiceProgress('transcribing','Preparing 16-bit audio and transcribing with Google…');
      const controller=new AbortController();voiceAbort=controller;
      try{
        const audio=await voice.finish();checkVoice(snapshot,token);
        const result=await request('/api/chat/transcribe',{provider:snapshot.provider,audio:{mime_type:audio.mime_type,data:audio.data},model:snapshot.transcriptionModel},controller.signal);
        checkVoice(snapshot,token);const text=String(result.transcript??result.text??'').trim();if(!text)throw Error('No words were recognized. Please try recording again.');
        if(promptRevision===snapshot.promptRevision&&prompt.value===snapshot.promptValue){prompt.value=[snapshot.promptValue.trim(),text].filter(Boolean).join('\n').slice(0,prompt.maxLength);promptRevision++;voiceStatus.textContent='Transcript ready in your message. Review it, then press Send.';prompt.focus();}
        else{
          const card=node('div','boxer-chat-transcription');card.append(node('p','',text));
          const use=button('Append transcript','Append this transcript to your current message without sending it',()=>{try{checkVoice(snapshot,voiceEpoch);prompt.value=[prompt.value.trim(),text].filter(Boolean).join('\n').slice(0,prompt.maxLength);promptRevision++;use.disabled=true;prompt.focus();}catch(error){addMessage('assistant',error.message);}});card.append(use);
          addMessage('assistant','Your message changed while transcription was running. Review the transcript below and append it if you want.',card);voiceStatus.textContent='Transcript retained below; your typed message was kept.';
        }
      }catch(error){if(token===voiceEpoch&&!destroyed)voiceStatus.textContent=error.name==='AbortError'?'Voice request cancelled.':error.message;}
      finally{if(token===voiceEpoch){voiceAbort=null;recordingSession=null;voiceProgress('idle',voiceStatus.textContent);}}
    }
    async function readReply(){
      if(busy||voicePhase!=='idle'||!voice||!lastReply||mode.value!=='google')return;
      const snapshot=voiceSnapshot(),reply=lastReply,token=++voiceEpoch;
      const signature=JSON.stringify([reply.text,snapshot.connection,snapshot.epoch,snapshot.revision,speechModel.value,speechVoice.value]);
      const controller=new AbortController();voiceAbort=controller;
      try{
        checkStudy(reply.epoch);if(reply.revision!==undefined&&String(reply.revision)!==String(studyRevision()))throw Error('The Study changed after this reply. Ask for an updated reply before generating speech.');
        let audio=cachedSpeech?.signature===signature?cachedSpeech.audio:null;
        if(!audio){
          voiceProgress('generating','Generating 16-bit reply audio with Google…');
          const response=await request('/api/chat/speech',{provider:snapshot.provider,text:reply.text.slice(0,2000),model:speechModel.value.trim(),voice:speechVoice.value},controller.signal);
          checkVoice(snapshot,token);audio=response.audio;if(!audio?.data)throw Error('Google returned no reply audio.');
          // Validate before caching. A blocked autoplay retry reuses this WAV.
          const voiceAPI=options.voice||win.WingBoxerVoice;voiceAPI.inspectWav?.(voiceAPI.decode64(audio.data));cachedSpeech={signature,audio,snapshot};
        }
        const playback=voice.play(audio);
        voiceProgress('playing','Playing reply audio'+(reply.text.length>2000?' · first 2,000 characters.':'.'));
        await playback;checkVoice(snapshot,token);
      }catch(error){if(token===voiceEpoch&&!destroyed)voiceProgress('idle',error.name==='AbortError'?'Reply audio cancelled.':error.message);}
      finally{if(voiceAbort===controller)voiceAbort=null;}
    }
    async function loadConfig(){
      if(configLoaded||destroyed)return;configLoaded=true;
      const initialRevision=connectionSettingsRevision;
      try{const config=await request('/api/chat/config');if(destroyed)return;
        const defaults=config.defaults||{};serverDefaults=defaults;googleConfig=config.google||{};
        if(initialRevision===connectionSettingsRevision){if(defaults.endpoint)endpoint.value=String(defaults.endpoint);if(defaults.model)model.value=String(defaults.model);}
        if(googleConfig.transcription_model&&!transcriptionModel.value)transcriptionModel.value=String(googleConfig.transcription_model);
        if(googleConfig.speech_model&&!speechModel.value)speechModel.value=String(googleConfig.speech_model);
        updateVoices(googleConfig.voices);updateVoiceControls();
        if(config.configured)settingsStatus.textContent='Server defaults are available. Select an AI mode to use them.';
        if(config.server_key_configured){serverKeyNote.textContent='A server key is available for the configured AI connection. An empty API key reuses it only when the provider and server URL match that connection.';serverKeyNote.hidden=false;}
      }catch(error){if(!destroyed)settingsStatus.textContent=error.message;configLoaded=false;}
    }
    async function loadMCPConfig(){
      const epoch=++mcpEpoch;mcpAbort?.abort();const controller=new AbortController();mcpAbort=controller;
      // Refresh only when the user opens Settings. A stale configuration must
      // not remain copyable after the Boxer server restarts or goes offline.
      mcpJSON='';mcpText.value='';mcpEndpoint.value='';mcpCopy.disabled=true;mcpStatus.textContent='Reading the local MCP connection…';
      try{
        const config=await request('/api/control/config',undefined,controller.signal);
        if(destroyed||epoch!==mcpEpoch)return;
        const entry=config.mcp_client_config?.mcpServers?.['JFEM-Boxer'];
        if(!entry||typeof entry.command!=='string'||!Array.isArray(entry.args)||!entry.args.every(value=>typeof value==='string'))throw Error('The Boxer server did not provide an MCP client configuration.');
        if(entry.args.some(value=>/^--(?:token|api[_-]?key|password|secret)(?:=|$)/i.test(value)))throw Error('The MCP configuration contains an inline credential and cannot be copied.');
        const safeConfig={mcpServers:{'JFEM-Boxer':{command:entry.command,args:entry.args}}};
        // Select only the public endpoint and the command/discovery arguments.
        // The bearer token in the full response is never displayed or copied.
        let endpointValue='';
        try{const uri=new URL(config.url);if(['http:','https:'].includes(uri.protocol))endpointValue=uri.origin+uri.pathname;}catch{}
        const serialized=JSON.stringify(safeConfig,null,2);
        if(typeof config.token==='string'&&config.token.length>=8&&serialized.includes(config.token))throw Error('The MCP configuration contains an inline credential and cannot be copied.');
        mcpJSON=serialized;mcpText.value=mcpJSON;mcpEndpoint.value=endpointValue;
        mcpCopy.disabled=busy;const clients=Array.isArray(config.clients)?config.clients.length:0;
        mcpStatus.textContent='Ready to connect. '+clients+' Boxer tab'+(clients===1?' is':'s are')+' connected.';
      }catch(error){if(!destroyed&&epoch===mcpEpoch&&error.name!=='AbortError')mcpStatus.textContent='MCP connection unavailable. '+error.message;}
      finally{if(mcpAbort===controller)mcpAbort=null;}
    }
    async function copyMCP(){
      if(!mcpJSON||busy)return false;
      try{await win.navigator.clipboard.writeText(mcpJSON);if(!destroyed)mcpStatus.textContent='MCP configuration copied. Paste it into your assistant’s MCP server settings.';}
      catch{if(destroyed)return false;mcpDetails.open=true;mcpText.focus();mcpText.select();mcpStatus.textContent='Clipboard access is unavailable. The configuration is selected below; copy it manually.';}
      return true;
    }
    function changeMode(){
      models.replaceChildren();speechModels.replaceChildren();
      aiFields.hidden=mode.value==='commands';commandsNote.hidden=mode.value!=='commands';keyLabel.hidden=mode.value==='ollama';
      connection.textContent=mode.value==='commands'?'Menu commands · runs locally':mode.value==='google'?'Google AI · Gemini':mode.value==='ollama'?'AI · local Ollama':'AI · compatible API';
      endpoint.readOnly=mode.value==='google';voiceSettings.hidden=mode.value!=='google';voiceTools.hidden=mode.value!=='google';
      if(mode.value==='google')endpoint.value='https://generativelanguage.googleapis.com/v1beta';
      if(mode.value==='ollama'&&(/\/v1\/?$/.test(endpoint.value)||!endpoint.value))endpoint.value='http://127.0.0.1:11434';
      if(mode.value==='compatible'&&(!endpoint.value||endpoint.value==='http://127.0.0.1:11434'))endpoint.value='http://127.0.0.1:1234/v1';
      if(mode.value!=='google'&&endpoint.value==='https://generativelanguage.googleapis.com/v1beta')endpoint.value=mode.value==='ollama'?'http://127.0.0.1:11434':'http://127.0.0.1:1234/v1';
      const requestedKind=mode.value==='compatible'?'openai':mode.value,defaultsKind=serverDefaults?.kind==='compatible'?'openai':serverDefaults?.kind;
      model.value=requestedKind===defaultsKind?String(serverDefaults?.model||''):'';
      apiKey.placeholder=mode.value==='google'?'Paste a Gemini API key from Google AI Studio':'Optional · server environment may provide it';
      apiKey.value='';keyOrigin='';settingsStatus.textContent='';connectionChanged();
    }
    async function testConnection(){
      if(busy||settingsBusy||mode.value==='commands')return;
      settingsBusy=true;testButton.disabled=true;settingsStatus.textContent='Checking the selected provider…';const controller=new AbortController();settingsAbort=controller;
      const selectedConnection=connectionSignature();
      try{const result=await request('/api/chat/test',{provider:provider()},controller.signal);if(destroyed||selectedConnection!==connectionSignature())return;
        models.replaceChildren();for(const value of result.models||[]){const item=node('option');item.value=typeof value==='string'?value:String(value.id||value.name||'');if(item.value)models.append(item);}
        const available=[...models.children].map(item=>item.value);
        if(mode.value==='google'){
          speechModels.replaceChildren();for(const id of available.filter(id=>/tts|speech-generation/i.test(id))){const item=node('option');item.value=id;speechModels.append(item);}
          if(!speechModel.value&&speechModels.firstElementChild)speechModel.value=speechModels.firstElementChild.value;
          updateVoices(result.voices);
          if(!model.value||!available.includes(model.value))model.value=available.find(id=>/flash/i.test(id)&&!/tts|embedding|image|live|native-audio/i.test(id))||available.find(id=>!/tts|embedding|image|live|native-audio/i.test(id))||'';
        }else if(!model.value&&models.firstElementChild)model.value=models.firstElementChild.value;
        resetHistory();cancelVoice();updateVoiceControls();
        settingsStatus.textContent=result.message||'Connected. '+models.children.length+' model(s) available.';
      }catch(error){if(!destroyed&&error.name!=='AbortError')settingsStatus.textContent=error.message;}
      finally{settingsBusy=false;if(settingsAbort===controller)settingsAbort=null;if(!destroyed)testButton.disabled=busy;}
    }
    function context(){
      const catalog=commands.catalog?.()||{};return compact({state:commands.getState?.()||{},catalog_revision:catalog.revision,
        catalog_counts:{actions:catalog.actions?.length??0,inputs:catalog.inputs?.length??0},actions:(catalog.actions||[]).slice(0,60),inputs:(catalog.inputs||[]).slice(0,60)});
    }
    function studyEpoch(){
      const state=commands.getState?.()||{};
      return state.study?.epoch??state.studyEpoch??state.study_epoch;
    }
    function studyRevision(){return commands.getState?.()?.study?.revision??undefined;}
    function checkStudy(expected){
      const current=studyEpoch();
      if(expected!==undefined&&current!==undefined&&String(current)!==String(expected)){
        const error=Error('The active Study changed. This request was stopped; send a new request for the current Study.');error.name='BoxerStudyChangedError';throw error;
      }
    }
    function checkDefinition(){
      checkStudy(activeStudyEpoch);const current=studyRevision();
      if(activeStudyRevision!==undefined&&current!==undefined&&String(current)!==String(activeStudyRevision)){
        const error=Error('The Study definition changed while this request was pending. This request was stopped; send a new request using the current properties.');error.name='BoxerStudyChangedError';throw error;
      }
    }
    function boundary(message){const error=Error(message);error.name='BoxerStudyBoundary';return error;}
    async function execute(name,args,labelText,epoch){
      if(destroyed||epoch!==requestEpoch||abort?.signal.aborted)throw new DOMException('Request stopped','AbortError');
      if(!TOOLS.has(name))throw Error('The assistant requested an unsupported tool “'+name+'”.');
      if(MUTATIONS.has(name))checkDefinition();
      status(labelText||'Applying '+name.replaceAll('_',' '));
      const guards=MUTATIONS.has(name)?{
        ...(activeStudyEpoch===undefined?{}:{expected_study_epoch:activeStudyEpoch}),
        ...(activeStudyRevision===undefined?{}:{expected_study_revision:activeStudyRevision})}:{};
      let result;
      try{result=await commands.execute({command:name,arguments:args||{},source:'chat',...guards});}
      catch(error){if(MUTATIONS.has(name))checkDefinition();throw error;}
      if(result?.ok===false)throw Error(result.error||result.message||'Boxer could not apply this request.');
      // Own accepted edits may advance the physical revision. Read-only tools
      // never move this guard past changes made while an AI reply is pending.
      if(MUTATIONS.has(name)&&!(name==='invoke_action'&&REPLACES_STUDY.has(String(args?.action_id??args?.id??'')))){
        checkStudy(activeStudyEpoch);
        if(name==='set_input'||name==='update_parameters'||result?.status==='completed')activeStudyRevision=studyRevision();
        else checkDefinition();
      }
      return result??{ok:true,status:'dispatched'};
    }
    function describeResult(result,labelText){
      if(result?.status==='waiting_for_user')return result.message||'Complete the '+(labelText||'requested action')+' dialog in Boxer.';
      if(result?.message||result?.summary)return String(result.message||result.summary);
      if(result?.status==='dispatched')return 'Sent “'+labelText+'” to Boxer. Follow its progress for completion.';
      return 'Applied “'+labelText+'”.';
    }
    function details(value){const element=node('details','boxer-chat-details');element.append(node('summary','','Details'),node('pre','',JSON.stringify(compact(value),null,2).slice(0,18000)));return element;}
    async function action(name,args,labelText,epoch){
      const result=await execute(name,args,labelText,epoch);if(destroyed||epoch!==requestEpoch)return result;
      addMessage('tool',describeResult(result,labelText),details(result));
      const id=String(args?.action_id??args?.id??result.action_id??'');
      if(name==='invoke_action'&&REPLACES_STUDY.has(id))throw boundary('The Study-changing action was requested. Finish that operation in Boxer, then send a new message for the active Study. Remaining actions in this request were stopped.');
      checkStudy(activeStudyEpoch);
      if(result.status==='waiting_for_user')throw boundary('Complete or cancel the requested action in Boxer, then send a new message to continue.');
      return result;
    }
    async function list(kind,query,limit=12){
      const result=kind==='actions'?await commands.listActions?.(query,limit):await commands.listInputs?.(query,limit);
      if(Array.isArray(result))return result.slice(0,limit);return(result?.[kind]||result?.items||[]).slice(0,limit);
    }
    function choices(entries,kind,value){
      const choiceStudyEpoch=activeStudyEpoch,choiceStudyRevision=activeStudyRevision;
      const wrap=node('div','boxer-chat-choices');
      for(const entry of entries){
        const row=node('div','boxer-chat-choice'),labelText=entryLabel(entry),contextText=entryContext(entry),id=entryId(entry);
        const info=node('div','boxer-chat-choice-label');info.append(node('strong','',labelText));if(contextText)info.append(node('small','',contextText));
        row.append(info);
        if(kind==='actions'){
          const apply=button('Run',entry.reason||entry.description||'Use this menu action',()=>runChoice('invoke_action',{action_id:id},labelText,choiceStudyEpoch,choiceStudyRevision));apply.disabled=!enabled(entry);row.append(apply);
        }else{
          const input=node('input');input.type='text';input.value=value===undefined?String(entry.value??''):String(value);input.setAttribute('aria-label',labelText);input.title='Enter the value in the units shown in Boxer';
          const apply=button('Set',entry.reason||'Update this input using its normal Boxer control',()=>{let selected;try{selected=numericValue(input.value,entry);}catch(error){addMessage('assistant',error.message);return;}runChoice('set_input',{input_id:id,value:selected},labelText,choiceStudyEpoch,choiceStudyRevision);});
          input.disabled=!enabled(entry);apply.disabled=!enabled(entry);row.append(input,apply);
        }
        if(!enabled(entry))row.append(node('small','boxer-chat-unavailable',entry.reason||entry.description||'Currently unavailable in Boxer'));
        wrap.append(row);
      }
      return wrap;
    }
    async function runChoice(name,args,labelText,choiceStudyEpoch,choiceStudyRevision){
      if(busy||destroyed)return;const epoch=++requestEpoch;abort=new AbortController();setBusy(true,'Applying '+labelText);
      activeStudyEpoch=choiceStudyEpoch;activeStudyRevision=choiceStudyRevision;
      try{await action(name,args,labelText,epoch);}catch(error){if(String(error.name||'').startsWith('BoxerStudy'))resetHistory();if(!destroyed&&epoch===requestEpoch)addMessage('assistant',error.name==='AbortError'?'Stopped this request.':error.message);}
      finally{if(epoch===requestEpoch){abort=null;setBusy(false);}}
    }
    function unique(entries,query){
      const exact=entries.filter(entry=>[entryLabel(entry),...(Array.isArray(entry.aliases)?entry.aliases:[])].some(value=>normalize(value)===normalize(query)));
      const curated=exact.filter(entry=>entry.curated===true&&enabled(entry));
      const available=exact.filter(enabled);
      if(curated.length===1)return curated[0];if(available.length===1)return available[0];if(exact.length===1)return exact[0];return entries.length===1?entries[0]:null;
    }
    async function local(message,epoch){
      const text=clean(message),normalized=normalize(text);
      if(/^(?:show |what is (?:the )?|get )?(?:study |model |boxer )?status$/.test(normalized)){
        const result=await execute('get_state',{},'Reading current Study status',epoch);addMessage('assistant','Current Study status',details(result));return;
      }
      if(/^(?:help|what can you do|examples)$/.test(normalized)){
        addMessage('assistant','I can use Boxer’s menu actions and inputs. Try “Create FEM”, “open Stress Report”, “find skin thickness inputs”, or “set wing area to 40”. Choose Settings to connect a conversational AI model.');return;
      }
      const set=text.match(/^(?:please\s+)?(?:set|change|update)\s+(.+?)\s+(?:to|=)\s+(.+)$/i);
      if(set){
        const found=await list('inputs',set[1]),chosen=unique(found,set[1]);
        if(chosen&&enabled(chosen)){await action('set_input',{input_id:entryId(chosen),value:numericValue(set[2],chosen)},entryLabel(chosen),epoch);return;}
        if(found.length){addMessage('assistant','Choose the input to update.',choices(found,'inputs',set[2]));return;}
        addMessage('assistant','I could not find an input matching “'+set[1]+'”. Use the input’s label as it appears in Boxer, or open its form first.');return;
      }
      const toggleMatch=text.match(/^(?:please\s+)?(show|hide|enable|disable|turn on|turn off)\s+(.+)$/i);
      if(toggleMatch){
        const found=(await list('inputs',toggleMatch[2])).filter(entry=>['checkbox','radio'].includes(entry.type)||entry.kind==='boolean'||typeof entry.value==='boolean');
        if(found.length){const value=/^(show|enable|turn on)$/i.test(toggleMatch[1]),chosen=unique(found,toggleMatch[2]);
          if(chosen&&enabled(chosen)){await action('set_input',{input_id:entryId(chosen),value},entryLabel(chosen),epoch);return;}
          addMessage('assistant','Choose the display option to change.',choices(found,'inputs',value));return;
        }
      }
      const inputSearch=text.match(/^(?:find|list|search|show)\s+(.+?)\s+(?:inputs|settings|parameters)$/i)||text.match(/^(?:find|list|search)\s+(?:inputs|settings|parameters)\s*(.*)$/i);
      if(inputSearch){const found=await list('inputs',inputSearch[1]);addMessage('assistant',found.length?'Matching inputs':'No matching inputs were found.',found.length?choices(found,'inputs'):null);return;}
      const query=text.replace(/^(?:please\s+)?(?:open|go to|click|press|run|show)\s+/i,'');
      let found=await list('actions',text);if(!found.length&&query!==text)found=await list('actions',query);
      const chosen=unique(found,text)||unique(found,query);
      if(chosen&&enabled(chosen)){await action('invoke_action',{action_id:entryId(chosen)},entryLabel(chosen),epoch);return;}
      if(found.length){addMessage('assistant','Choose the action you want.',choices(found,'actions'));return;}
      const inputs=await list('inputs',query);if(inputs.length){addMessage('assistant','Matching inputs',choices(inputs,'inputs'));return;}
      addMessage('assistant','I could not match that request to a menu action or input. Try a menu label, or connect an AI model in Settings for conversational requests.');
    }
    async function ai(message,epoch){
      if(!model.value.trim())throw Error('Choose Settings, test the connection and select a model before sending an AI request.');
      const selectedConnection=connectionSignature(),selectedProvider=provider();
      history.push({role:'user',content:message});
      // Keep complete tool-call/result groups. A fresh history begins after a mode
      // change or Clear rather than dropping unmatched tool messages mid-workflow.
      if(history.length>100){resetHistory();history=[{role:'user',content:message}];}
      let calls=0;
      for(let round=0;round<8;round++){
        status(round?'Waiting for the AI response':'Contacting the selected AI provider');
        const response=await request('/api/chat/message',{provider:selectedProvider,messages:history,context:context(),...(selectedProvider.kind==='google'&&providerState?{provider_state:providerState}:{})},abort.signal);
        if(destroyed||epoch!==requestEpoch)throw new DOMException('Request stopped','AbortError');
        if(selectedConnection!==connectionSignature())throw new DOMException('The AI connection changed','AbortError');
        checkDefinition();
        providerState=selectedProvider.kind==='google'?(response.provider_state||null):null;
        if(Array.isArray(response.messages))history=response.messages;
        else history.push({role:'assistant',content:String(response.text||''),...(response.tool_calls?.length?{tool_calls:response.tool_calls.map(call=>({id:call.id,type:'function',function:{name:call.name,arguments:JSON.stringify(call.arguments||{})}}))}:{})});
        if(response.text){addMessage('assistant',response.text);lastReply={text:String(response.text),epoch:studyEpoch(),revision:studyRevision()};cachedSpeech=null;updateVoiceControls();}
        const requested=response.tool_calls||[];
        if(!requested.length){if(!response.text)addMessage('assistant','The provider returned no message or action.');return;}
        for(const call of requested){
          if(++calls>24)throw Error('This request reached the 24-action limit. Review the completed actions before continuing.');
          let args=call.arguments||{};if(typeof args==='string'){try{args=JSON.parse(args);}catch{args={};}}
          let result;
          try{result=await action(call.name,args,call.name.replaceAll('_',' '),epoch);}
          catch(error){if(error.name==='AbortError'||String(error.name||'').startsWith('BoxerStudy'))throw error;result={ok:false,error:error.message};addMessage('tool',error.message);}
          history.push({role:'tool',tool_call_id:String(call.id||''),content:JSON.stringify(compact(result))});
          if(destroyed||epoch!==requestEpoch||abort.signal.aborted)throw new DOMException('Request stopped','AbortError');
        }
      }
      resetHistory();addMessage('assistant','This request reached the eight-step conversation limit. Review the actions above, then ask me to continue if needed.');
    }
    async function send(message){
      if(busy||destroyed)return false;const text=String(message===undefined?prompt.value:message).trim().slice(0,12000);if(!text)return false;
      cancelVoice();prompt.value='';promptRevision++;lastReply=null;addMessage('user',text);const epoch=++requestEpoch;abort=new AbortController();setBusy(true,'Finding the requested Boxer action');
      activeStudyEpoch=studyEpoch();activeStudyRevision=studyRevision();
      if(historyStudyEpoch!==undefined&&activeStudyEpoch!==undefined&&String(historyStudyEpoch)!==String(activeStudyEpoch))resetHistory();
      historyStudyEpoch=activeStudyEpoch;
      try{if(mode.value==='commands')await local(text,epoch);else await ai(text,epoch);return true;}
      catch(error){if(mode.value!=='commands'||String(error.name||'').startsWith('BoxerStudy'))resetHistory();if(!destroyed&&epoch===requestEpoch)addMessage('assistant',error.name==='AbortError'?'Stopped this request. Actions already sent to Boxer may still be running.':error.message);return error.name==='BoxerStudyBoundary';}
      finally{if(epoch===requestEpoch){abort=null;setBusy(false);}}
    }
    function stop(){
      cancelVoice();if(!busy)return;abort?.abort();requestEpoch++;abort=null;resetHistory();setBusy(false);addMessage('assistant','Stopped this request. Actions already sent to Boxer may still be running.');
    }
    function clear(){if(busy)return;resetHistory();cancelVoice();lastReply=null;transcript.querySelectorAll('.boxer-chat-message').forEach(element=>element.remove());welcome.hidden=false;prompt.value='';promptRevision++;prompt.focus();}
    function open(){if(destroyed)return;priorFocus=doc.activeElement;opened=true;panel.hidden=false;toggle?.setAttribute('aria-expanded','true');prompt.focus();options.onOpen?.();}
    function close(){if(destroyed)return;cancelVoice();opened=false;panel.hidden=true;toggle?.setAttribute('aria-expanded','false');(toggle||priorFocus)?.focus?.();options.onClose?.();}
    function width(value){panel.style.width=Math.max(300,Math.min(win.innerWidth-16,value))+'px';}
    let resizeStart=null;
    listen(resize,'pointerdown',event=>{if(event.button!==0)return;event.preventDefault();resizeStart={x:event.clientX,width:panel.getBoundingClientRect().width,id:event.pointerId};resize.setPointerCapture(event.pointerId);});
    listen(resize,'pointermove',event=>{if(resizeStart)width(resizeStart.width+resizeStart.x-event.clientX);});
    const endResize=()=>{resizeStart=null;};listen(resize,'pointerup',endResize);listen(resize,'pointercancel',endResize);
    listen(resize,'keydown',event=>{if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();width(panel.getBoundingClientRect().width+(event.key==='ArrowLeft'?24:-24));}});
    listen(form,'submit',event=>{event.preventDefault();send();});
    listen(prompt,'keydown',event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing){event.preventDefault();send();}});
    listen(panel,'keydown',event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();if(!help.hidden)showHelp(false);else close();}});
    listen(mode,'change',changeMode);
    listen(prompt,'input',()=>promptRevision++);
    listen(apiKey,'input',()=>{try{keyOrigin=new URL(endpoint.value).origin;}catch{keyOrigin='';}connectionChanged();});
    listen(model,'input',connectionChanged);listen(model,'change',connectionChanged);
    for(const control of [transcriptionModel,speechModel,speechVoice])listen(control,'change',()=>cancelVoice());
    listen(endpoint,'change',()=>{let origin='';try{origin=new URL(endpoint.value).origin;}catch{}
      if(apiKey.value&&keyOrigin&&origin!==keyOrigin){apiKey.value='';settingsStatus.textContent='The API key was cleared because the AI server changed.';}
      keyOrigin=origin;connectionChanged();
    });
    listen(win,'resize',()=>{if(panel.style.width)width(panel.getBoundingClientRect().width);});
    return{open,close,toggle(){opened?close():open();},send,stop,clear,refresh(snapshot){
      if(destroyed)return;const state=commands.connection;panel.dataset.connected=String(state?.connected??false);
      const current=snapshot?.study?.epoch??studyEpoch();
      if(observedStudyEpoch!==undefined&&current!==undefined&&String(current)!==String(observedStudyEpoch)){resetHistory();lastReply=null;cancelVoice('The active Study changed. Voice activity was stopped.');}
      else if(recordingSession||cachedSpeech||lastReply){const saved=recordingSession||cachedSpeech?.snapshot||lastReply;if(saved?.revision!==undefined&&String(saved.revision)!==String(snapshot?.study?.revision??studyRevision())){lastReply=null;cancelVoice('The Study definition changed. Voice activity was stopped.');}}
      observedStudyEpoch=current;
    },get busy(){return busy;},get opened(){return opened;},destroy(){
      if(destroyed)return;cancelVoice();voice?.destroy();destroyed=true;requestEpoch++;mcpEpoch++;abort?.abort();settingsAbort?.abort();mcpAbort?.abort();abort=null;settingsAbort=null;mcpAbort=null;mcpJSON='';mcpText.value='';if(timer!==null)clearInterval(timer);timer=null;apiKey.value='';resetHistory();lastReply=null;
      for(const remove of listeners)remove();toggle?.setAttribute('aria-expanded','false');panel.remove();
    }};
  }
  return{create,compact,numericValue};
});
