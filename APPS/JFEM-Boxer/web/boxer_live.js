/* Gemini Live connection made directly by the browser.
 *
 * The page opens a WebSocket to Google itself; the Boxer program is not
 * involved and never sees the key. The endpoint and the message shapes follow
 * the connection of the OpenFLIGHT aircraft-model creator: one setup message,
 * text turns as clientContent, tool calls answered with toolResponse, replies
 * as 24 kHz PCM audio parts with a written copy, and push-to-talk audio as
 * 16 kHz PCM.
 *
 * Models, measured with a real key on 2026-11-19 (six sessions of four requests
 * each): gemini-3.1-flash-live-preview and gemini-3.8-live completed all six;
 * the model of the reference app, gemini-2.5-flash-native-audio-latest, failed
 * in two (an empty first answer followed by close 1007 "The audio content type
 * (CONTENT_TYPE_AUDIO) is not supported for this model configuration", and a
 * session that stopped answering). gemini-3.8-live can go on speaking after it
 * has reported the end of its turn, which loses a request typed at that moment,
 * so it is second. The models are tried in this order.
 */
(function(root,factory){
  const api=factory(root);
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.WingBoxerLive=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(root){
  'use strict';
  const HOST='generativelanguage.googleapis.com';
  const PATH='/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
  const MODELS=['models/gemini-3.1-flash-live-preview','models/gemini-3.8-live','models/gemini-2.5-flash-native-audio-latest'],MODEL=MODELS[0];
  // A stored name that is one of Boxer's own defaults is not a choice the user made.
  const isDefaultModel=name=>{const value=String(name||'').trim();return !value||MODELS.includes(/^models\//.test(value)?value:'models/'+value);};
  const VOICE='Kore';
  const KEY_STORE='jfem_boxer_gemini_key';
  const VOICES=['Zephyr','Puck','Charon','Kore','Fenrir','Leda','Orus','Aoede','Callirrhoe','Autonoe','Enceladus','Iapetus','Umbriel','Algieba','Despina','Erinome',
    'Algenib','Rasalgethi','Laomedeia','Achernar','Alnilam','Schedar','Gacrux','Pulcherrima','Achird','Zubenelgenubi','Vindemiatrix','Sadachbia','Sadaltager','Sulafat'];

  /* A pasted key often carries blanks, a line break, quotes or a NAME=value prefix. */
  function cleanKey(value){
    return String(value??'').trim().replace(/^["'`]+|["'`]+$/g,'').replace(/[\s ​-‍﻿]+/g,'')
      .replace(/^(?:export)?(?:GEMINI_API_KEY|GOOGLE_API_KEY|x-goog-api-key|api[_-]?key|key)[=:]/i,'').replace(/^["'`]+|["'`]+$/g,'');
  }
  /* Say what the pasted text is. `usable` is false only for things that are
   * certainly not a Gemini key; an unfamiliar shape is still tried, because
   * Google owns the key format and has already changed it once. */
  function keyShape(value){
    const key=cleanKey(value),out=(kind,usable,message)=>({key,kind,usable,message});
    if(!key)return out('empty',false,'Paste your Gemini API key into the box first. Help shows where to get one.');
    if(/^https?:\/\//i.test(key)||/^www\./i.test(key))return out('url',false,'That is a web address, not a key. On the Google AI Studio “API keys” page, press the copy icon beside the key and paste what it copies.');
    if(/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(key))return out('email',false,'That is an e-mail address. Boxer needs the API key that Google AI Studio creates, not the name of your Google account.');
    if(/\.apps\.googleusercontent\.com$/i.test(key))return out('oauth_client',false,'That is an OAuth client ID (it ends in “.apps.googleusercontent.com”). It belongs to a different Google feature. Create a Gemini API key on the Google AI Studio “API keys” page instead.');
    if(/^GOCSPX-/i.test(key))return out('oauth_secret',false,'That is an OAuth client secret (it starts with “GOCSPX-”), not a Gemini API key. Create a Gemini API key on the Google AI Studio “API keys” page instead.');
    if(/^ya29\./.test(key))return out('oauth_token',false,'That is a temporary Google sign-in token (it starts with “ya29.”), not a Gemini API key. Create a Gemini API key on the Google AI Studio “API keys” page instead.');
    if(/^\d+$/.test(key))return out('project_number',false,'That is only digits, which is a Google project number, not a key. On the Google AI Studio “API keys” page, copy the key itself: a long line of letters and digits.');
    if(/^[a-z][a-z0-9-]{4,29}$/.test(key)&&key.includes('-')&&!/[A-Z_.]/.test(key))return out('project_id',false,'That looks like a Google project name (lower-case words joined by dashes), not a key. Copy the key itself: a long line of mixed letters and digits.');
    if(/[^\x21-\x7e]/.test(key))return out('characters',false,'The pasted text contains characters that a key cannot have. Copy the key again with the copy icon on the Google AI Studio “API keys” page.');
    if(key.length<20)return out('short',false,'That is too short to be a Gemini API key ('+key.length+' characters; keys have 39 or more). Copy the whole key and paste it again.');
    if(/^AIza[0-9A-Za-z_-]{35}$/.test(key))return out('standard',true,'');
    if(/^AQ\.[0-9A-Za-z._-]{20,}$/.test(key))return out('auth',true,'');
    if(/^AIza/.test(key))return out('unusual',true,'This starts like a Gemini key but has '+key.length+' characters instead of 39; part of it may be missing or doubled. Trying it anyway.');
    return out('unusual',true,'This does not look like the Gemini keys known so far (they start with “AIza” or “AQ.”). Trying it anyway, in case Google has changed the format.');
  }
  const keyFacts=key=>!key?'no key':key.length+' characters, starts with “AIza”: '+(/^AIza/.test(key)?'yes':'no')+', starts with “AQ.”: '+(/^AQ\./.test(key)?'yes':'no');

  /* Turn the way a connection ended into a plain reason and a next step.
   * Recorded from Google on 2026-11-19: a wrong key closes with code 1007
   * “API key not valid. Please pass a valid API key.” after the setup message;
   * a missing key closes with 1008 “Permission denied on the service.” */
  function explainClose(info){
    const code=Number(info.code)||0,reason=String(info.reason||''),lower=reason.toLowerCase();
    // Each explanation says what happened and names one thing to do.
    const out=(kind,title,text)=>({kind,title,text});
    if(info.kind==='timeout')return out('timeout','Google did not answer','Google did not answer within '+Math.round((info.limit||15000)/1000)+' seconds. Check the internet connection and try again.');
    if(/api key/.test(lower)&&/(not valid|invalid|expired)/.test(lower)||code===1007&&/api key/.test(lower))
      return out('invalid_key','Google did not accept this key','Google did not accept this key. Check the key: copy it again from the Google AI Studio “API keys” page and paste it here.');
    if(/leaked/.test(lower))return out('key_blocked','Google has blocked this key','Google has blocked this key because it was reported as leaked. Create a new key on the Google AI Studio “API keys” page and paste it here.');
    if(/quota|exceeded|exhaust|billing|rate limit|too many/.test(lower))
      return out('quota','The key’s allowance is used up','Google reports that this key has used up its allowance for now. Try again later; daily limits reset at midnight Pacific time.');
    if(/location|region|country/.test(lower))return out('region','Not available in your region','Google does not offer this service to your account in your country or region. Press Copy details and send them to us.');
    /* Recorded from Google on 2026-11-19 with a working key: an accepted session can be closed in the
     * middle of a conversation with code 1007 “The audio content type (CONTENT_TYPE_AUDIO) is not
     * supported for this model configuration.” Other users have reported the same fault of the voice
     * service since August 2026. Nothing is wrong with the key or the request; a new session works. */
    if(info.stage==='ready'&&/content type|content_type|model configuration/.test(lower))
      return out('dropped','Google dropped the session','Google dropped this session because of a fault on its side. Boxer connects again by itself.');
    if(/not found|not supported|unsupported|not available|no longer|deprecated|unknown model/.test(lower))
      return out('model','Google did not accept the assistant model','Google did not accept the assistant model that Boxer uses for this key. Press Copy details and send them to us.');
    if(/permission|denied|forbidden|disabled|restricted|not allowed|unauthori|verif/.test(lower))
      return out('permission','Google refused this key','Google refused this key (permission denied). Check the key on the Google AI Studio “API keys” page: it must be a Gemini API key of an active project.');
    if(!info.opened&&(code===1006||!code))
      return out('network','The browser could not reach Google','The browser could not reach Google. '+(info.online===false?'This computer appears to be offline. ':'')+'Check the internet connection and try again; a firewall, VPN or ad blocker may be blocking “'+HOST+'”.');
    if(code===1006&&info.stage==='ready')return out('lost','The connection to Google was lost','The connection to Google was lost. Boxer connects again when you send the next message.');
    if(code===1011||/internal|unavailable|overload|high demand/.test(lower))return out('server','Google reported a problem on its side','Google reported a problem on its side. Try again in a minute.');
    if(info.stage!=='ready')return out('setup','Google refused the connection request','Google closed the connection before it was ready, for a reason other than the key. Press Copy details and send them to us.');
    if(code===1000||code===1001)return out('ended','The Gemini session ended','Google ended this session, as it does after some minutes. Boxer connects again when you send the next message.');
    return out('closed','The connection to Google closed','The connection to Google closed. Boxer connects again when you send the next message.');
  }
  /* Everything needed to diagnose a failed connection. Never contains the key. */
  function report(info){
    const explained=info.explained||explainClose(info),redact=text=>info.key?String(text).split(info.key).join('[key]'):String(text);
    return['JFEM-Boxer · Gemini connection report','Time: '+new Date(info.time||Date.now()).toISOString(),'Result: '+explained.kind+' · '+explained.title,
      'Stage reached: '+(info.stage==='ready'?'ready (setup accepted)':info.opened?'socket open, setup sent':'socket never opened'),
      'Close code: '+(info.code??'none'),'Close reason: '+(info.reason?'"'+redact(info.reason)+'"':'(empty)'),'Clean close: '+String(!!info.clean),
      'Endpoint: '+redact(String(info.url||'wss://'+HOST+PATH).split('?')[0])+' (key not shown)','Model: '+(info.model||MODEL),
      'Setup form: '+(info.transcripts?'with reply transcripts':'standard'),'Key: '+keyFacts(info.key),
      'Milliseconds to open: '+(info.openedAfter??'never opened')+' · to close: '+(info.closedAfter??'n/a'),
      'Browser online: '+String(info.online)+' · Page: '+(info.origin||'unknown'),'Browser: '+(info.agent||'unknown')].join('\n');
  }
  /* The first message. Field for field the proven form; transcripts are an optional extra. */
  function setupMessage(options={}){
    const setup={model:options.model||MODEL,
      generationConfig:{responseModalities:['AUDIO'],speechConfig:{voiceConfig:{prebuiltVoiceConfig:{voiceName:options.voice||VOICE}}}},
      systemInstruction:{parts:[{text:String(options.instructions||'')}]},
      tools:[{functionDeclarations:options.declarations||[]}]};
    if(options.transcripts){setup.outputAudioTranscription={};setup.inputAudioTranscription={};}
    return{setup};
  }
  /* ---- Looking things up on the web ------------------------------------------------
   * Measured with a real free-tier key on 2026-11-19: Google Search is refused with
   * "You exceeded your current quota" (in a quarter of a second) on every current
   * model, both on the ordinary request path and on the Live models that Boxer talks
   * to. It is included only on gemini-2.5-flash-native-audio-latest. So a lookup first
   * asks the ordinary path, which answers in text and works for keys with a paid
   * allowance, and otherwise opens a short separate Live session on that one model,
   * with Google Search as its only tool, and reads the written copy of its spoken
   * answer (13 to 27 s). That model sometimes answers with nothing; it is asked twice. */
  const SEARCH_LIVE_MODEL='models/gemini-2.5-flash-native-audio-latest',SEARCH_TEXT_MODELS=['gemini-flash-lite-latest','gemini-flash-latest'];
  const SEARCH_REST='https://'+HOST+'/v1beta/models/';
  const SEARCH_RULES='You are a lookup service inside an engineering program. Search the web for what is asked and answer with the facts only: numbers with units, at most 70 words, no greeting, no question back. If sources disagree, give the range.';
  const grounded=meta=>({queries:(meta?.webSearchQueries||[]).map(String).slice(0,4),
    sources:(meta?.groundingChunks||[]).map(chunk=>({title:String(chunk.web?.title||''),uri:String(chunk.web?.uri||'')})).filter(item=>/^https:\/\//.test(item.uri)).slice(0,6)});
  const stopped=()=>({ok:false,stopped:true,error:'Stopped.'});
  // The ordinary request path. `blocked` means the key has no allowance for searches here.
  async function searchText(o){
    const fetcher=o.fetch||root.fetch?.bind(root);if(!fetcher)return{ok:false,error:'This browser cannot send the request.'};
    let last={ok:false,error:'no model answered'};
    for(const model of o.textModels||SEARCH_TEXT_MODELS){
      if(o.signal?.aborted)return stopped();
      const limit=new AbortController(),timer=setTimeout(()=>limit.abort(),o.textTimeout||12000),halt=()=>limit.abort();o.signal?.addEventListener?.('abort',halt);
      try{
        const response=await fetcher((o.restUrl||SEARCH_REST)+model+':generateContent',{method:'POST',headers:{'Content-Type':'application/json','x-goog-api-key':o.key},signal:limit.signal,
          body:JSON.stringify({systemInstruction:{parts:[{text:SEARCH_RULES}]},contents:[{role:'user',parts:[{text:o.query}]}],tools:[{google_search:{}}]})});
        const data=await response.json().catch(()=>({}));
        if(!response.ok){
          const message=String(data?.error?.message||'HTTP '+response.status).split(o.key).join('[key]').slice(0,200);
          last={ok:false,error:message,blocked:[401,403,429].includes(response.status)};
          if(last.blocked)return last;continue;
        }
        const candidate=data.candidates?.[0],answer=(candidate?.content?.parts||[]).filter(part=>typeof part.text==='string'&&!part.thought).map(part=>part.text).join('').trim();
        if(answer)return{ok:true,answer,...grounded(candidate.groundingMetadata),via:model};
        last={ok:false,error:'empty answer'};
      }catch(error){last=o.signal?.aborted?stopped():{ok:false,error:'no answer in '+Math.round((o.textTimeout||12000)/1000)+' s'};if(last.stopped)return last;}
      finally{clearTimeout(timer);o.signal?.removeEventListener?.('abort',halt);}
    }
    return last;
  }
  // One short Live session with Google Search as its only tool.
  function searchLive(o){
    return new Promise(resolve=>{
      const WS=o.WebSocket||root.WebSocket;let socket,said='',meta=null,settled=false,timer=null;
      const halt=()=>end(stopped());
      const end=result=>{if(settled)return;settled=true;clearTimeout(timer);o.signal?.removeEventListener?.('abort',halt);
        if(socket){socket.onclose=socket.onmessage=socket.onerror=null;try{socket.close(1000,'lookup finished');}catch{}}resolve(result);};
      if(o.signal?.aborted)return end(stopped());
      try{socket=new WS((o.url||'wss://'+HOST+PATH)+'?key='+encodeURIComponent(o.key));}catch(error){return end({ok:false,error:'The browser refused to open the connection.'});}
      o.signal?.addEventListener?.('abort',halt);
      timer=setTimeout(()=>end(said.trim()?{ok:true,answer:said.trim(),...grounded(meta),via:SEARCH_LIVE_MODEL}:{ok:false,error:'no answer in '+Math.round((o.liveTimeout||45000)/1000)+' s'}),o.liveTimeout||45000);
      socket.onopen=()=>socket.send(JSON.stringify({setup:{model:o.liveModel||SEARCH_LIVE_MODEL,
        generationConfig:{responseModalities:['AUDIO'],speechConfig:{voiceConfig:{prebuiltVoiceConfig:{voiceName:VOICE}}}},
        systemInstruction:{parts:[{text:SEARCH_RULES}]},tools:[{googleSearch:{}}],outputAudioTranscription:{}}}));
      let queue=Promise.resolve();
      socket.onmessage=event=>{queue=queue.then(async()=>{
        if(settled)return;let message;try{message=JSON.parse(typeof event.data==='string'?event.data:await new Response(event.data).text());}catch{return;}
        if(message.setupComplete){socket.send(JSON.stringify({clientContent:{turns:[{role:'user',parts:[{text:o.query}]}],turnComplete:true}}));return;}
        const content=message.serverContent;if(!content)return;
        if(content.outputTranscription?.text)said+=String(content.outputTranscription.text);
        if(content.groundingMetadata)meta=content.groundingMetadata;
        if(content.turnComplete)end(said.trim()?{ok:true,answer:said.trim(),...grounded(meta),via:SEARCH_LIVE_MODEL}:{ok:false,error:'empty answer'});
      });};
      socket.onerror=()=>{};
      socket.onclose=event=>{queue=queue.then(()=>end({ok:false,error:'close code '+event.code+(event.reason?', “'+String(event.reason).split(o.key).join('[key]').slice(0,160)+'”':'')}));};
    });
  }
  /* Look something up. Resolves {ok:true,answer,queries,sources,via} or {ok:false,error}; never throws.
   * `o.state` is kept by the caller so that a refused path is not asked again for ten minutes. */
  async function lookup(o){
    const query=String(o.query||'').replace(/\s+/g,' ').trim().slice(0,500),key=cleanKey(o.key),state=o.state||{};
    if(!query)return{ok:false,error:'Nothing to look up was given.'};
    if(!key)return{ok:false,error:'There is no Gemini key.'};
    const request={...o,query,key},errors=[];
    if(!(state.textBlocked>Date.now())){
      const text=await searchText(request);
      if(text.ok||text.stopped)return text;
      errors.push(text.error);if(text.blocked)state.textBlocked=Date.now()+600000;
    }
    for(let attempt=0;attempt<2;attempt++){
      const live=await searchLive(request);
      if(live.ok||live.stopped)return live;
      errors.push(live.error);
    }
    return{ok:false,error:'The web search did not answer ('+errors.at(-1)+').',errors};
  }

  function toBase64(buffer){
    const bytes=new Uint8Array(buffer);let binary='';
    for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode.apply(null,bytes.subarray(index,index+0x8000));
    return root.btoa(binary);
  }
  function fromBase64(text){const binary=root.atob(text),bytes=new Uint8Array(binary.length);for(let index=0;index<binary.length;index++)bytes[index]=binary.charCodeAt(index);return bytes;}

  function create(options={}){
    const win=options.window||root,WS=options.WebSocket||win.WebSocket,emit=(name,...args)=>{try{options[name]?.(...args);}catch(error){win.console?.error?.('[Boxer Live]',error);}};
    let ws=null,stage='idle',generation=0,last=null,sessions=0,queue=Promise.resolve(),cancelPending=null;
    let playContext=null,playGain=null,playNext=0,playing=new Set(),speak=options.speak!==false;
    let micContext=null,micStream=null,micNode=null,micSource=null,micReady=null,talking=false,released=0,micRate=16000;

    function playback(){
      if(playContext||!speak)return;
      const Context=options.AudioContext||win.AudioContext||win.webkitAudioContext;if(!Context)return;
      try{playContext=new Context({sampleRate:24000});playGain=playContext.createGain();playGain.connect(playContext.destination);playNext=playContext.currentTime;}catch{playContext=null;}
    }
    function playChunk(data,mime){
      emit('onAudio');
      if(!speak)return;playback();if(!playContext)return;
      const rate=Number((/rate=(\d+)/.exec(String(mime||''))||[])[1])||24000,bytes=fromBase64(data),samples=new Int16Array(bytes.buffer,0,bytes.length>>1);
      if(!samples.length)return;
      const buffer=playContext.createBuffer(1,samples.length,rate),channel=buffer.getChannelData(0);
      for(let index=0;index<samples.length;index++)channel[index]=samples[index]/32768;
      const source=playContext.createBufferSource();source.buffer=buffer;source.connect(playGain);
      if(playNext<playContext.currentTime)playNext=playContext.currentTime;
      source.onended=()=>playing.delete(source);playing.add(source);source.start(playNext);playNext+=buffer.duration;
    }
    function stopAudio(){for(const source of playing){try{source.stop();}catch{}}playing.clear();if(playContext)playNext=playContext.currentTime;}
    function send(message){if(ws&&ws.readyState===1){ws.send(JSON.stringify(message));return true;}return false;}
    function handle(message){
      if(message.setupComplete){stage='ready';sessions++;emit('onState','ready');return 'ready';}
      if(message.toolCall?.functionCalls)for(const call of message.toolCall.functionCalls)emit('onToolCall',{id:call.id,name:String(call.name||''),args:call.args||{}});
      if(message.toolCallCancellation?.ids)emit('onToolCancel',message.toolCallCancellation.ids);
      const content=message.serverContent;
      if(content){
        if(content.interrupted){stopAudio();emit('onInterrupted');}
        for(const part of content.modelTurn?.parts||[]){
          if(typeof part.text==='string'&&part.text)emit('onText',part.text,{thought:part.thought===true});
          if(part.inlineData?.data)playChunk(part.inlineData.data,part.inlineData.mimeType);
        }
        if(content.outputTranscription?.text)emit('onTranscript','reply',String(content.outputTranscription.text));
        if(content.inputTranscription?.text)emit('onTranscript','heard',String(content.inputTranscription.text));
        if(content.turnComplete)emit('onTurnComplete');
      }
      if(message.goAway)emit('onGoAway',message.goAway);
      return null;
    }
    /* Open the socket, send the setup and wait for Google to accept it.
     * Resolves {ok:true} or {ok:false,failure}; it does not throw. */
    function connect(rawKey,setup={}){
      close();
      const key=cleanKey(rawKey),mine=++generation,started=Date.now(),limit=options.connectTimeout||15000;
      const base=(options.url||'wss://'+HOST+PATH),url=base+'?key='+encodeURIComponent(key);
      const info={key,url:base,model:setup.model||options.model||MODEL,transcripts:!!setup.transcripts,opened:false,stage:'connecting',time:started,
        online:win.navigator?.onLine,origin:win.location?.origin,agent:win.navigator?.userAgent};
      stage='connecting';emit('onState','connecting');
      return new Promise(resolve=>{
        let settled=false,timer=null;
        // Closing while the connection is still being made ends the wait at once.
        cancelPending=()=>{if(settled)return;settled=true;clearTimeout(timer);resolve({ok:false,failure:{cancelled:true,explained:{kind:'cancelled',title:'Stopped',text:'Stopped.'}}});};
        const fail=extra=>{
          Object.assign(info,extra,{closedAfter:Date.now()-started});info.explained=explainClose(info);info.report=report(info);last=info;
          if(mine===generation){stage='closed';ws=null;stopAudio();emit('onState','closed',info);}
          if(!settled){settled=true;clearTimeout(timer);resolve({ok:false,failure:info});}
          else if(mine===generation)emit('onClose',info);
        };
        let socket;
        try{socket=new WS(url);}catch(error){fail({code:0,reason:'The browser refused to open the connection: '+String(error?.message||error),clean:false});return;}
        ws=socket;
        // No setupComplete within the limit: stop waiting and say so.
        timer=setTimeout(()=>{if(settled||mine!==generation)return;socket.onclose=null;socket.onmessage=null;try{socket.close();}catch{}fail({kind:'timeout',limit,code:0,reason:'',clean:false});},limit);
        socket.onopen=()=>{
          if(mine!==generation)return;
          info.opened=true;info.openedAfter=Date.now()-started;info.stage='setup';stage='setup';
          socket.send(JSON.stringify(setupMessage({model:info.model,voice:setup.voice||options.voice,instructions:setup.instructions??options.instructions,declarations:setup.declarations||options.declarations,transcripts:info.transcripts})));
          playback();
        };
        socket.onmessage=event=>{
          // Google sends JSON as binary frames. Keep the order while they are decoded.
          queue=queue.then(async()=>{
            if(mine!==generation)return;
            let message;try{message=JSON.parse(typeof event.data==='string'?event.data:await new Response(event.data).text());}catch{return;}
            if(handle(message)==='ready'&&!settled){settled=true;clearTimeout(timer);info.stage='ready';resolve({ok:true,session:sessions});}
          });
        };
        socket.onerror=()=>{info.errorEvent=true;};
        socket.onclose=event=>{
          if(mine!==generation&&settled)return;
          queue=queue.then(()=>fail({code:event.code,reason:event.reason||'',clean:!!event.wasClean,stage:info.stage}));
        };
      });
    }
    function close(){
      generation++;talking=false;cancelPending?.();cancelPending=null;
      if(ws){const socket=ws;ws=null;try{socket.onclose=null;socket.onmessage=null;socket.onerror=null;socket.close(1000,'closed by Boxer');}catch{}}
      stopAudio();
      if(stage!=='idle'&&stage!=='closed'){stage='closed';emit('onState','closed',null);}
    }
    // One text turn.
    const sendText=text=>send({clientContent:{turns:[{role:'user',parts:[{text:String(text)}]}],turnComplete:true}});
    // The result of one tool call, wrapped as {result: …}.
    const respond=(call,result)=>send({toolResponse:{functionResponses:[{id:call.id,name:call.name,response:{result}}]}});

    // Microphone samples are gathered into blocks of 2048 samples at 16 kHz.
    let pending=[],pendingLength=0;
    function sendAudio(samples){
      if(!(talking||Date.now()-released<2000)||stage!=='ready'){pending=[];pendingLength=0;return;}
      pending.push(samples.slice?samples.slice(0):Float32Array.from(samples));pendingLength+=samples.length;
      if(pendingLength<2048*micRate/16000)return;
      const joined=new Float32Array(pendingLength);let offset=0;for(const part of pending){joined.set(part,offset);offset+=part.length;}
      pending=[];pendingLength=0;
      const length=micRate===16000?joined.length:Math.max(1,Math.round(joined.length*16000/micRate)),pcm=new Int16Array(length);
      for(let index=0;index<length;index++){
        const value=Math.max(-1,Math.min(1,joined[micRate===16000?index:Math.min(joined.length-1,Math.floor(index*micRate/16000))]));
        pcm[index]=value<0?value*0x8000:value*0x7fff;
      }
      // “audio” is the current form; the older “mediaChunks” closes the newer models (recorded 2026-11-19).
      send({realtimeInput:{audio:{mimeType:'audio/pcm;rate=16000',data:toBase64(pcm.buffer)}}});
    }
    async function microphone(){
      const devices=options.mediaDevices||win.navigator?.mediaDevices,Context=options.AudioContext||win.AudioContext||win.webkitAudioContext;
      if(!devices?.getUserMedia||!Context)throw Error('This browser cannot record from a microphone here. Use a current browser on the Boxer page.');
      try{micStream=await devices.getUserMedia({audio:true});}
      catch(error){throw Error(error?.name==='NotAllowedError'||error?.name==='SecurityError'?'Microphone permission was denied. Allow the microphone for this page in the browser’s address bar, then hold the button again.':
        error?.name==='NotFoundError'?'No microphone was found. Connect one and hold the button again.':'The microphone could not be started: '+String(error?.message||error));}
      micContext=new Context({sampleRate:16000});micRate=micContext.sampleRate||16000;
      micSource=micContext.createMediaStreamSource(micStream);
      const Worklet=options.AudioWorkletNode||win.AudioWorkletNode;
      if(micContext.audioWorklet?.addModule&&Worklet){
        const code='class BoxerLiveCapture extends AudioWorkletProcessor{process(inputs){const channel=inputs[0]&&inputs[0][0];if(channel)this.port.postMessage(channel.slice(0));return true;}}registerProcessor("boxer-live-capture",BoxerLiveCapture);';
        const address=(options.URL||win.URL).createObjectURL(new Blob([code],{type:'application/javascript'}));
        try{await micContext.audioWorklet.addModule(address);micNode=new Worklet(micContext,'boxer-live-capture');micNode.port.onmessage=event=>sendAudio(event.data);}
        finally{(options.URL||win.URL).revokeObjectURL(address);}
        micSource.connect(micNode);
      }else{
        micNode=micContext.createScriptProcessor(2048,1,1);micNode.onaudioprocess=event=>sendAudio(event.inputBuffer.getChannelData(0));
        micSource.connect(micNode);micNode.connect(micContext.destination);
      }
    }
    /* Push-to-talk: audio flows while the button is held and for two seconds after. */
    async function startTalk(){
      if(stage!=='ready')throw Error('Gemini is not connected yet.');
      if(!micNode){micReady=micReady||microphone();try{await micReady;}catch(error){micReady=null;releaseMicrophone();throw error;}}
      try{await micContext.resume?.();await playContext?.resume?.();}catch{}
      stopAudio();talking=true;emit('onTalk',true);
    }
    function stopTalk(){if(!talking)return;talking=false;released=Date.now();emit('onTalk',false);}
    function releaseMicrophone(){
      talking=false;try{micNode?.disconnect?.();micSource?.disconnect?.();}catch{}
      for(const track of micStream?.getTracks?.()||[])try{track.stop();}catch{}
      try{micContext?.close?.();}catch{}
      micNode=micSource=micStream=micContext=micReady=null;
    }
    function destroy(){close();releaseMicrophone();try{playContext?.close?.();}catch{}playContext=null;}
    return{connect,close,sendText,respond,startTalk,stopTalk,stopAudio,destroy,
      setSpeak(value){speak=!!value;if(!speak)stopAudio();},
      resume(){try{playContext?.resume?.();}catch{}},
      get stage(){return stage;},get ready(){return stage==='ready';},get talking(){return talking;},get last(){return last;},get sessions(){return sessions;}};
  }
  return{create,cleanKey,keyShape,explainClose,report,setupMessage,isDefaultModel,lookup,HOST,PATH,MODEL,MODELS,VOICE,VOICES,KEY_STORE,SEARCH_LIVE_MODEL,SEARCH_TEXT_MODELS};
});
