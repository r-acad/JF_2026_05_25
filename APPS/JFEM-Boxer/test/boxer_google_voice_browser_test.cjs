'use strict';
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
const web=path.join(__dirname,'../web');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  try{
    const page=await browser.newPage({viewport:{width:1000,height:900}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.goto('about:blank');await page.addScriptTag({path:path.join(web,'boxer_voice.js')});
    const helper=await page.evaluate(async()=>{
      const api=WingBoxerVoice,samples=Float32Array.from({length:4800},(_,i)=>Math.sin(i/14)*.4),bytes=api.wav(samples,48000),info=api.inspectWav(bytes);
      const invalid=bytes.slice();new DataView(invalid.buffer).setUint16(34,8,true);let rejected=false;try{api.inspectWav(invalid);}catch{rejected=true;}
      let trackNumber=0;const tracks=[],contexts=[],processors=[];
      const devices={getUserMedia:async()=>{const track={id:++trackNumber,stopped:false,stop(){this.stopped=true;}};tracks.push(track);return{getTracks:()=>[track]};}};
      const edge=()=>({connect(){},disconnect(){}});
      class Context{constructor(){this.sampleRate=48000;this.closed=false;this.destination={};contexts.push(this);}resume(){}close(){this.closed=true;}createMediaStreamSource(){return edge();}createGain(){return{...edge(),gain:{value:1}};}createScriptProcessor(){const processor={...edge()};processors.push(processor);return processor;}}
      const capture=api.create({window,mediaDevices:devices,AudioContext:Context});await capture.start();processors[0].onaudioprocess({inputBuffer:{getChannelData:()=>samples}});const audio=await capture.finish();
      const captured=api.inspectWav(api.decode64(audio.data));capture.destroy();
      let grant;const lateTrack={stopped:false,stop(){this.stopped=true;}};const late=api.create({window,mediaDevices:{getUserMedia:()=>new Promise(resolve=>grant=resolve)},AudioContext:Context});
      const pending=late.start().catch(error=>error.name);late.cancel();grant({getTracks:()=>[lateTrack]});const lateResult=await pending;late.destroy();
      const worklets=[];
      class WorkletContext extends Context{constructor(){super();this.audioWorklet={addModule:async()=>{}};}}
      class Worklet{constructor(){this.port={onmessage:null,postMessage(){}};worklets.push(this);}connect(){}disconnect(){}}
      const race=api.create({window,mediaDevices:devices,AudioContext:WorkletContext,AudioWorkletNode:Worklet,URL:{createObjectURL:()=> 'blob:mock',revokeObjectURL(){}}});
      await race.start();worklets[0].port.onmessage({data:{samples:samples.buffer}});const oldFinish=race.finish().catch(error=>error.name);race.cancel();await race.start();const oldResult=await oldFinish;
      const replacementAlive=race.recording&&!tracks.at(-1).stopped&&!contexts.at(-1).closed;race.destroy();
      let closeOld;class DeferredContext extends Context{close(){this.closed=true;return contexts.indexOf(this)===closeIndex?new Promise(resolve=>closeOld=resolve):undefined;}}
      const closeIndex=contexts.length,closing=api.create({window,mediaDevices:devices,AudioContext:DeferredContext});await closing.start();processors.at(-1).onaudioprocess({inputBuffer:{getChannelData:()=>samples}});
      const delayedFinish=closing.finish();closing.cancel();await closing.start();closeOld();await delayedFinish;const replacementAfterClose=closing.recording&&!tracks.at(-1).stopped&&!contexts.at(-1).closed;closing.destroy();
      let denial='';const denied=api.create({window,mediaDevices:{getUserMedia:async()=>{throw new DOMException('denied','NotAllowedError');}},AudioContext:Context});try{await denied.start();}catch(error){denial=error.message;}denied.destroy();
      return{info,captured,rejected,tracksStopped:tracks.every(track=>track.stopped),contextsClosed:contexts.every(context=>context.closed),lateStopped:lateTrack.stopped,lateResult,oldResult,replacementAlive,replacementAfterClose,denial};
    });
    assert.equal(helper.info.sample_rate,16000);assert.equal(helper.info.bits_per_sample,16);assert.equal(helper.info.channels,1);assert.equal(helper.info.data_bytes,3200);assert.equal(helper.captured.data_bytes,3200);
    assert(helper.rejected&&helper.tracksStopped&&helper.contextsClosed&&helper.lateStopped&&helper.replacementAlive&&helper.replacementAfterClose);assert.equal(helper.lateResult,'AbortError');assert.equal(helper.oldResult,'AbortError');assert.match(helper.denial,/permission was denied/);
    console.log('1. Microphone capture produces bounded 16 kHz mono PCM16 WAV, rejects 8-bit reply audio, releases denied/late capture and preserves replacement recording ownership.');
    await page.setContent('<!doctype html><html><body><button id="boxer-chat-toggle">Chat</button><main>Wing viewport</main></body></html>');
    await page.addStyleTag({path:path.join(web,'style.css')});await page.addStyleTag({path:path.join(web,'boxer_chat.css')});await page.addScriptTag({path:path.join(web,'boxer_chat.js')});
    await page.evaluate(()=>{
      window.calls=[];window.actions=[];window.studyEpoch=1;window.studyRevision=1;window.voiceMode='normal';window.transcribeDelay=false;window.aiRound=0;window.playerCount=0;window.playBlocked=true;window.cancelCount=0;
      window.nativeState={kind:'google',model:'gemini-3.5-flash-lite',contents:[{role:'model',parts:[{text:'unchanged',thoughtSignature:'OPAQUE_SIGNATURE'}]}],message_count:2,history_sha256:'opaque-sha'};
      const wav=WingBoxerVoice.wav(new Float32Array(1600).fill(.1),16000);window.audio={mime_type:'audio/wav',data:WingBoxerVoice.encode64(wav)};
      let callback;const fakeVoice={...WingBoxerVoice,create(options){callback=options.onUpdate;return{supported:true,start:async()=>{if(voiceMode==='denied')throw Error('Microphone permission was denied.');callback({state:'recording',recording:true,playing:false,level:.5});},finish:async()=>audio,cancel(){cancelCount++;callback({state:'idle',playing:false});},stopPlayback(){callback({state:'idle',playing:false});},play:async()=>{playerCount++;if(playBlocked){playBlocked=false;throw Error('The browser blocked playback. Press Read last reply again to play the prepared audio.');}callback({playing:true});},destroy(){cancelCount++;}};}};
      const commands={connection:{connected:true},catalog:()=>({actions:[],inputs:[]}),getState:()=>({study:{epoch:studyEpoch,revision:studyRevision}}),listActions:()=>[],listInputs:()=>[],execute:async request=>{actions.push(request);if(request.command==='set_input'){studyRevision++;chat.refresh(commands.getState());}return{ok:true,status:'updated'};}};
      const response=body=>({ok:true,json:async()=>body});
      window.chat=WingBoxerChat.create({commands,voice:fakeVoice,fetch:async(url,init={})=>{
        const body=init.body?JSON.parse(init.body):null;calls.push({url,body});
        if(url==='/api/chat/config')return response({defaults:{kind:'ollama',model:'unrelated-local-model',endpoint:'http://127.0.0.1:11434'},google:{key_configured:false,voices:['Kore','Puck']}});
        if(url==='/api/control/config')return response({url:'http://localhost:8080/api/mcp',mcp_client_config:{mcpServers:{'JFEM-Boxer':{command:'julia',args:['BoxerMCP.jl']}}}});
        if(url==='/api/chat/test')return response({models:['gemini-3.8-flash-lite-tts','gemini-3.5-flash-lite'],voices:['Kore','Puck']});
        if(url==='/api/chat/transcribe'){
          if(transcribeDelay)return await new Promise(resolve=>{window.releaseTranscript=()=>resolve(response({transcript:'Set the upper skin to 2 mm'}));});
          return response({transcript:'Show Study status'});
        }
        if(url==='/api/chat/speech')return response({audio});
        if(url==='/api/chat/message'){
          if(aiRound++===0)return response({text:'I will update both inputs.',tool_calls:[{id:'g1',name:'set_input',arguments:{input_id:'a',value:2}},{id:'g2',name:'set_input',arguments:{input_id:'b',value:3}}],provider_state:nativeState});
          return response({text:'Both inputs were updated.',tool_calls:[],provider_state:{...nativeState,message_count:5}});
        }
        throw Error('Unexpected request '+url);
      }});chat.open();
    });
    await page.getByRole('button',{name:'Settings',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#boxer-chat-model').value==='unrelated-local-model');
    await page.selectOption('#boxer-chat-mode','google');assert.equal(await page.inputValue('#boxer-chat-model'),'');assert.equal(await page.locator('#boxer-chat-models option').count(),0);
    await page.fill('#boxer-chat-api-key','SESSION_ONLY_KEY');await page.getByRole('button',{name:'Test connection',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#boxer-chat-model').value==='gemini-3.5-flash-lite');
    assert.equal(await page.inputValue('#boxer-chat-speech-model'),'gemini-3.8-flash-lite-tts');assert(await page.locator('#boxer-chat-endpoint').getAttribute('readonly')!==null);
    await page.click('#boxer-chat-help');await page.setViewportSize({width:320,height:760});
    assert(await page.locator('#boxer-chat-help-panel').isVisible());assert.match(await page.locator('#boxer-chat-help-panel').innerText(),/18 or older/);assert.match(await page.locator('#boxer-chat-help-panel').innerText(),/does not guarantee/);
    assert.equal(await page.locator('#boxer-chat-help-panel a[href="https://aistudio.google.com/apikey"]').count(),1);
    const dimensions=await page.locator('#boxer-chat-help-panel').evaluate(element=>({width:element.clientWidth,scroll:element.scrollWidth}));assert(dimensions.scroll<=dimensions.width+1);
    if(process.env.BOXER_CHAT_EVIDENCE_DIR)await page.screenshot({path:path.join(process.env.BOXER_CHAT_EVIDENCE_DIR,'google_help_mobile.png')});
    await page.getByRole('button',{name:'Back to chat',exact:true}).click();await page.setViewportSize({width:1000,height:900});await page.getByRole('button',{name:'Settings',exact:true}).click();
    console.log('2. Google mode clears unrelated local model choices, selects an available non-TTS chat model, and provides actionable official setup/voice Help at 320 pixels.');
    await page.evaluate(()=>voiceMode='denied');await page.click('#boxer-chat-record');await page.waitForFunction(()=>document.querySelector('#boxer-chat-voice-status').textContent.includes('denied'));
    await page.evaluate(()=>voiceMode='normal');await page.click('#boxer-chat-record');await page.getByRole('button',{name:'Stop recording',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#boxer-chat-prompt').value==='Show Study status');
    assert.equal(await page.evaluate(()=>actions.length),0);assert.equal(await page.evaluate(()=>calls.filter(call=>call.url==='/api/chat/message').length),0);
    const recorded=await page.evaluate(()=>calls.find(call=>call.url==='/api/chat/transcribe').body);assert.equal(recorded.audio.mime_type,'audio/wav');assert.equal(recorded.provider.api_key,'SESSION_ONLY_KEY');assert(!('audio' in (recorded.context||{})));
    console.log('3. Permission failures are clear; recording sends PCM WAV for transcription and places text in the composer without automatically sending or executing it.');
    await page.fill('#boxer-chat-prompt','');await page.evaluate(()=>transcribeDelay=true);await page.click('#boxer-chat-record');await page.getByRole('button',{name:'Stop recording',exact:true}).click();await page.waitForFunction(()=>typeof releaseTranscript==='function');
    await page.fill('#boxer-chat-prompt','My typed request');await page.evaluate(()=>releaseTranscript());await page.waitForFunction(()=>document.querySelector('.boxer-chat-transcription'));
    assert.equal(await page.inputValue('#boxer-chat-prompt'),'My typed request');await page.getByRole('button',{name:'Append transcript',exact:true}).click();assert.match(await page.inputValue('#boxer-chat-prompt'),/^My typed request\nSet the upper skin/);
    await page.fill('#boxer-chat-prompt','Keep this');await page.evaluate(()=>{delete window.releaseTranscript;});await page.click('#boxer-chat-record');await page.getByRole('button',{name:'Stop recording',exact:true}).click();await page.waitForFunction(()=>typeof releaseTranscript==='function');
    await page.evaluate(()=>{studyEpoch++;chat.refresh({study:{epoch:studyEpoch,revision:studyRevision}});releaseTranscript();});await page.waitForTimeout(30);assert.equal(await page.inputValue('#boxer-chat-prompt'),'Keep this');assert.match(await page.locator('#boxer-chat-voice-status').innerText(),/Study changed/);
    console.log('4. Pending transcription preserves intervening typing and cannot overwrite a replacement Study; onState invalidation stops voice work immediately.');
    await page.evaluate(()=>{transcribeDelay=false;});await page.fill('#boxer-chat-prompt','Update both properties');await page.locator('#boxer-chat-prompt').press('Enter');await page.waitForFunction(()=>!chat.busy);
    const ai=await page.evaluate(()=>calls.filter(call=>call.url==='/api/chat/message'));assert.equal(ai.length,2);assert.deepEqual(ai[1].body.provider_state,await page.evaluate(()=>nativeState));assert.equal(ai[1].body.messages.filter(message=>message.role==='tool').length,2);assert.equal(await page.evaluate(()=>actions.length),2);
    assert(!JSON.stringify(ai[1].body.context).includes('SESSION_ONLY_KEY'));assert(!JSON.stringify(ai[1].body.context).includes('OPAQUE_SIGNATURE'));
    console.log('5. Native Gemini provider state and opaque signatures roundtrip unchanged across parallel tool results and own physical edits. Credentials/audio remain outside Study context.');
    await page.click('#boxer-chat-speak');await page.waitForFunction(()=>document.querySelector('#boxer-chat-voice-status').textContent.includes('blocked playback'));assert.equal(await page.evaluate(()=>calls.filter(call=>call.url==='/api/chat/speech').length),1);
    await page.click('#boxer-chat-speak');await page.waitForFunction(()=>!document.querySelector('#boxer-chat-audio-stop').hidden);assert.equal(await page.evaluate(()=>calls.filter(call=>call.url==='/api/chat/speech').length),1);assert.equal(await page.evaluate(()=>playerCount),2);
    await page.click('#boxer-chat-audio-stop');assert(await page.locator('#boxer-chat-audio-stop').isHidden());
    await page.getByRole('button',{name:'Settings',exact:true}).click();await page.fill('#boxer-chat-model','another-available-flash');await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.evaluate(()=>chat.send('Status after changing model'));await page.waitForFunction(()=>!chat.busy);const last=await page.evaluate(()=>calls.filter(call=>call.url==='/api/chat/message').at(-1).body);assert.equal(last.provider_state,undefined);assert.equal(last.messages.length,1);
    console.log('6. Reply speech uses explicit TTS controls and cached WAV after autoplay denial; model changes reset opaque provider state without retaining old conversation history.');
    await page.click('#boxer-chat-record');await page.getByRole('button',{name:'Close Boxer assistant',exact:true}).click();assert(await page.locator('#boxer-chat').isHidden());const count=await page.evaluate(()=>cancelCount);assert(count>0);
    await page.evaluate(()=>chat.destroy());assert.equal(await page.locator('#boxer-chat').count(),0);assert.deepEqual(errors,[]);
    console.log('7. Close/destroy cancel microphone activity, playback and pending voice state. No browser speech-recognition service or real external API is used.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
