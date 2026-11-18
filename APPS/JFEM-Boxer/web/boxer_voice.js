(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingBoxerVoice=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const TARGET_RATE=16000,MAX_SECONDS=60;
  function encode64(bytes){let text='';for(let i=0;i<bytes.length;i+=32768)text+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(text);}
  function decode64(value){const text=atob(value),bytes=new Uint8Array(text.length);for(let i=0;i<text.length;i++)bytes[i]=text.charCodeAt(i);return bytes;}
  function wav(samples,sourceRate,targetRate=TARGET_RATE){
    if(!(sourceRate>=8000&&sourceRate<=192000)||!(targetRate>0))throw Error('Unsupported microphone sample rate.');
    const count=Math.min(Math.floor(samples.length*targetRate/sourceRate),targetRate*MAX_SECONDS),ratio=sourceRate/targetRate;
    const bytes=new Uint8Array(44+count*2),view=new DataView(bytes.buffer);
    const text=(offset,value)=>{for(let i=0;i<value.length;i++)bytes[offset+i]=value.charCodeAt(i);};
    text(0,'RIFF');view.setUint32(4,36+count*2,true);text(8,'WAVE');text(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);
    view.setUint32(24,targetRate,true);view.setUint32(28,targetRate*2,true);view.setUint16(32,2,true);view.setUint16(34,16,true);text(36,'data');view.setUint32(40,count*2,true);
    for(let i=0;i<count;i++){
      const start=i*ratio,end=Math.min(samples.length,(i+1)*ratio);let value=0;
      if(ratio>=1){for(let index=Math.floor(start);index<Math.ceil(end);index++)value+=(Number.isFinite(samples[index])?samples[index]:0)*Math.max(0,Math.min(end,index+1)-Math.max(start,index));value/=Math.max(1e-12,end-start);}
      else{const a=Math.floor(start),f=start-a;value=(1-f)*(samples[a]||0)+f*(samples[Math.min(a+1,samples.length-1)]||0);}
      value=Math.max(-1,Math.min(1,value));view.setInt16(44+2*i,Math.round(value*(value<0?32768:32767)),true);
    }
    return bytes;
  }
  function inspectWav(bytes){
    if(bytes.length<44||bytes.length>20_000_000)throw Error('The speech response is not a supported WAV recording.');
    const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),text=(start,length)=>String.fromCharCode(...bytes.subarray(start,start+length));
    if(text(0,4)!=='RIFF'||text(8,4)!=='WAVE')throw Error('The speech response is not a WAV file.');
    let format=null,dataLength=0;
    for(let offset=12;offset+8<=bytes.length;){const size=view.getUint32(offset+4,true),end=offset+8+size;if(end>bytes.length)throw Error('The speech WAV response is incomplete.');
      if(text(offset,4)==='fmt '&&size>=16)format={code:view.getUint16(offset+8,true),channels:view.getUint16(offset+10,true),sample_rate:view.getUint32(offset+12,true),bits_per_sample:view.getUint16(offset+22,true)};
      if(text(offset,4)==='data')dataLength+=size;offset=end+(size%2);
    }
    if(!format||format.code!==1||format.channels!==1||format.bits_per_sample!==16||format.sample_rate<8000||format.sample_rate>48000||!dataLength||dataLength%2)throw Error('Speech must use 16-bit mono PCM WAV audio.');
    const seconds=dataLength/(format.sample_rate*2);if(seconds>180.01)throw Error('The speech response exceeds the three-minute playback limit.');
    return{...format,seconds,data_bytes:dataLength};
  }
  const WORKLET=`class BoxerCapture extends AudioWorkletProcessor{constructor(){super();this.buffer=new Float32Array(4096);this.used=0;this.port.onmessage=e=>{if(e.data==='flush'){this.flush();this.port.postMessage({flushed:true});}};}flush(){if(!this.used)return;const chunk=this.buffer.slice(0,this.used);this.port.postMessage({samples:chunk.buffer},[chunk.buffer]);this.used=0;}process(inputs){const channels=inputs[0];if(!channels||!channels.length)return true;for(let i=0;i<channels[0].length;i++){let value=0;for(const channel of channels)value+=channel[i]||0;this.buffer[this.used++]=value/channels.length;if(this.used===this.buffer.length)this.flush();}return true;}}registerProcessor('boxer-voice-capture',BoxerCapture);`;
  function create(options={}){
    const win=options.window||globalThis,devices=options.mediaDevices||win.navigator?.mediaDevices,Context=options.AudioContext||win.AudioContext||win.webkitAudioContext;
    const WorkletNode=options.AudioWorkletNode||win.AudioWorkletNode,AudioClass=options.Audio||win.Audio,URLApi=options.URL||win.URL;
    const maxSeconds=Math.max(.1,Math.min(MAX_SECONDS,Number(options.maxSeconds)||MAX_SECONDS));
    let generation=0,state='idle',context=null,stream=null,source=null,processor=null,gain=null,chunks=[],frames=0,startTime=0,limitTimer=null,tick=null,limitReached=false,flushResolve=null,flushTimer=null;
    let player=null,playerURL=null,playGeneration=0,destroyed=false,level=0;
    const supported=!!(devices?.getUserMedia&&Context);
    function notify(extra={}){options.onUpdate?.({state,recording:state==='recording'||state==='requesting',playing:!!player,seconds:state==='recording'?(performance.now()-startTime)/1000:0,level,...extra});}
    function timers(){if(limitTimer!==null)clearTimeout(limitTimer);if(tick!==null)clearInterval(tick);if(flushTimer!==null)clearTimeout(flushTimer);limitTimer=tick=flushTimer=null;flushResolve?.();flushResolve=null;}
    function cleanCapture(){
      timers();for(const item of [source,processor,gain])try{item?.disconnect();}catch{}
      if(processor){processor.onaudioprocess=null;try{processor.port.onmessage=null;}catch{}}
      for(const track of stream?.getTracks?.()||[])try{track.stop();}catch{}
      const pending=context;context=stream=source=processor=gain=null;
      return Promise.resolve(pending?.close?.()).catch(()=>{});
    }
    function limit(){if(limitReached||state!=='recording')return;limitReached=true;if(options.onLimit)options.onLimit();else cancel();}
    function append(samples,token){
      if(token!==generation||state!=='recording'||!context)return;
      const available=Math.max(0,Math.floor(context.sampleRate*maxSeconds)-frames),count=Math.min(available,samples.length);
      if(count){const chunk=Float32Array.from(samples.subarray? samples.subarray(0,count):samples.slice(0,count));chunks.push(chunk);frames+=count;let sum=0;for(let i=0;i<chunk.length;i++)sum+=chunk[i]*chunk[i];level=Math.min(1,Math.sqrt(sum/chunk.length)*4);}
      if(count<samples.length||frames>=context.sampleRate*maxSeconds)queueMicrotask(limit);
    }
    async function start(){
      if(destroyed)throw Error('Voice controls have closed.');if(!supported)throw Error('This browser cannot record a microphone here. Use a current browser on localhost or HTTPS.');
      if(state!=='idle')throw Error('A microphone recording is already active.');
      const token=++generation;state='requesting';notify();chunks=[];frames=0;level=0;limitReached=false;
      try{
        const input=await devices.getUserMedia({audio:{channelCount:1,sampleRate:TARGET_RATE,echoCancellation:true,noiseSuppression:true},video:false});
        if(destroyed||token!==generation){for(const track of input.getTracks())track.stop();throw new DOMException('Recording cancelled','AbortError');}
        stream=input;context=new Context({sampleRate:TARGET_RATE});await context.resume?.();
        if(token!==generation||destroyed)throw new DOMException('Recording cancelled','AbortError');
        if(!(context.sampleRate>=8000&&context.sampleRate<=192000))throw Error('The microphone returned an unsupported sample rate.');
        source=context.createMediaStreamSource(stream);gain=context.createGain();gain.gain.value=0;gain.connect(context.destination);
        if(context.audioWorklet?.addModule&&WorkletNode&&URLApi?.createObjectURL){
          const module=URLApi.createObjectURL(new Blob([WORKLET],{type:'application/javascript'}));
          try{await context.audioWorklet.addModule(module);}finally{URLApi.revokeObjectURL(module);}
          if(token!==generation||destroyed)throw new DOMException('Recording cancelled','AbortError');
          processor=new WorkletNode(context,'boxer-voice-capture');processor.port.onmessage=event=>{if(event.data.samples)append(new Float32Array(event.data.samples),token);if(event.data.flushed){flushResolve?.();flushResolve=null;}};
        }else{
          processor=context.createScriptProcessor(4096,1,1);processor.onaudioprocess=event=>append(event.inputBuffer.getChannelData(0),token);
        }
        state='recording';startTime=performance.now();source.connect(processor);processor.connect(gain);tick=setInterval(()=>notify(),250);limitTimer=setTimeout(limit,maxSeconds*1000);notify();
        return{sample_rate:context.sampleRate,max_seconds:maxSeconds};
      }catch(error){
        if(token===generation){await cleanCapture();if(token===generation){state='idle';notify();}}
        if(destroyed||token!==generation)throw new DOMException('Recording cancelled','AbortError');
        if(error.name==='NotAllowedError'||error.name==='PermissionDeniedError')throw Error('Microphone permission was denied. Allow the microphone for this Boxer page in your browser site settings, then try again.');
        if(error.name==='NotFoundError')throw Error('No microphone was found. Connect a microphone and try again.');
        throw error;
      }
    }
    async function finish(){
      if(state!=='recording')throw Error('Start a microphone recording first.');const token=generation,rate=context.sampleRate;
      try{
        if(processor?.port){await new Promise(resolve=>{flushResolve=resolve;flushTimer=setTimeout(resolve,250);processor.port.postMessage('flush');});}
        if(destroyed||token!==generation)throw new DOMException('Recording cancelled','AbortError');
        state='stopping';if(!frames)throw Error('No microphone audio was recorded. Try speaking for a moment before stopping.');
        const samples=new Float32Array(frames);let offset=0;for(const chunk of chunks){samples.set(chunk,offset);offset+=chunk.length;}
        const bytes=wav(samples,rate);if(bytes.length<=44)throw Error('The recording was too short. Please try again.');
        return{mime_type:'audio/wav',data:encode64(bytes),seconds:(bytes.length-44)/(TARGET_RATE*2),sample_rate:TARGET_RATE,channels:1,bits_per_sample:16};
      }finally{if(token===generation){await cleanCapture();if(token===generation){chunks=[];frames=0;state='idle';notify();}}}
    }
    function cancel(){generation++;state='idle';chunks=[];frames=0;level=0;const result=cleanCapture();notify();return result;}
    function stopPlayback(){
      playGeneration++;if(player){player.onended=player.onerror=null;try{player.pause();player.removeAttribute?.('src');player.load?.();}catch{}player=null;}
      if(playerURL){URLApi.revokeObjectURL(playerURL);playerURL=null;}notify();
    }
    async function play(audio){
      if(destroyed)throw Error('Voice controls have closed.');if(!AudioClass||!URLApi?.createObjectURL)throw Error('This browser cannot play reply audio.');
      const bytes=decode64(String(audio?.data||'')),information=inspectWav(bytes);stopPlayback();const token=playGeneration;
      playerURL=URLApi.createObjectURL(new Blob([bytes],{type:'audio/wav'}));const current=new AudioClass(playerURL);player=current;
      current.onended=()=>{if(token===playGeneration)stopPlayback();};current.onerror=()=>{if(token===playGeneration){stopPlayback();notify({error:'Reply audio could not be played.'});}};
      try{await current.play();if(token!==playGeneration||destroyed)return information;notify({duration:information.seconds});return information;}
      catch(error){if(token===playGeneration)stopPlayback();if(error.name==='NotAllowedError')throw Error('The browser blocked playback. Press Read last reply again to play the prepared audio.');throw Error('Reply audio could not be played. Check your audio output and try again.');}
    }
    return{supported,start,finish,cancel,play,stopPlayback,get state(){return state;},get recording(){return state==='recording'||state==='requesting';},get playing(){return!!player;},destroy(){if(destroyed)return;destroyed=true;cancel();stopPlayback();}};
  }
  return{create,wav,inspectWav,encode64,decode64,TARGET_RATE,MAX_SECONDS};
});
