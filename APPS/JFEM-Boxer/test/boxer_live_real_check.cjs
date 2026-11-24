'use strict';
// Optional check of Boxer's browser-direct Gemini connection against the real
// Google Live service, run from a terminal with Node 22 or later. It uses the
// same module as the page (web/boxer_live.js) and is never part of the tests.
//
//   node APPS/JFEM-Boxer/test/boxer_live_real_check.cjs
//       Without a key: records how Google closes the connection for an unknown
//       key and for a missing key. Nothing is generated.
//
//   set BOXER_GEMINI_LIVE_KEY=<your key>      (PowerShell: $env:BOXER_GEMINI_LIVE_KEY="<your key>")
//   node APPS/JFEM-Boxer/test/boxer_live_real_check.cjs
//       With a key: connects exactly as the page does, sends one request that
//       needs a tool, answers the tool call and prints what came back: which
//       kinds of reply parts, whether text arrived, how much sound. This uses a
//       few seconds of the key's allowance. The key is never printed.
const path=require('node:path'),assert=require('node:assert/strict');
const Live=require(path.join(__dirname,'../web/boxer_live.js'));
const key=process.env.BOXER_GEMINI_LIVE_KEY||'',hide=text=>key?String(text).split(key).join('[key]'):String(text);
const declarations=[{name:'get_state',description:'Read the current Study status.'},
  {name:'set_input',description:'Set one input.',parameters:{type:'OBJECT',properties:{id:{type:'STRING',description:'The name of the input.'},value:{type:'STRING',description:'The new value as text.'}},required:['id','value']}}];
(async()=>{
  for(const [label,value,code,kind] of [['unknown key','AIzaSyINVALIDKEYFORSHAPEPROBE0000000000',1007,'invalid_key'],['no key','',1008,'permission']]){
    const session=Live.create({speak:false,connectTimeout:15000});
    const result=await session.connect(value,{instructions:'Connection test.',declarations});session.destroy();
    console.log(label.padEnd(12),'-> close code',result.failure?.code,JSON.stringify(result.failure?.reason),'=>',result.failure?.explained.kind,'·',result.failure?.explained.text);
    assert.equal(result.ok,false);assert.equal(result.failure.code,code);assert.equal(result.failure.explained.kind,kind);
  }
  if(!key){console.log('\nNo BOXER_GEMINI_LIVE_KEY was set: a successful connection, a tool call and a reply were NOT exercised against the real service.');return;}
  const shape=Live.keyShape(key);console.log('\nkey shape     ->',shape.kind,shape.usable?'(usable)':'(not usable: '+shape.message+')');
  const seen={text:0,thoughts:0,audio:0,transcript:0,calls:[],textSample:''};let finish;const done=new Promise(resolve=>{finish=resolve;});
  const session=Live.create({speak:false,connectTimeout:15000,
    onText:(text,info)=>{if(info.thought)seen.thoughts++;else{seen.text++;seen.textSample+=text;}},onAudio:()=>{seen.audio++;},onTranscript:()=>{seen.transcript++;},
    onToolCall:call=>{seen.calls.push(call.name+' '+JSON.stringify(call.args));session.respond(call,call.name==='get_state'?{ok:true,state:{title:'Live check',aspect_ratio:8}}:{ok:true,status:'updated'});},
    onTurnComplete:()=>finish('turn complete'),onClose:failure=>finish('closed: code '+failure.code+' '+JSON.stringify(hide(failure.reason)))});
  const started=Date.now(),connected=await session.connect(key,{instructions:'You operate a test application with the provided tools. Reply briefly.',declarations});
  if(!connected.ok){console.log('connect       -> FAILED after',Date.now()-started,'ms\n'+hide(connected.failure.report));process.exitCode=1;return;}
  console.log('connect       -> setupComplete after',Date.now()-started,'ms with',Live.MODEL);
  session.sendText('Set the aspect ratio to 15 with the set_input tool, then tell me in one short sentence what you did.');
  const outcome=await Promise.race([done,new Promise(resolve=>setTimeout(()=>resolve('no end of turn within 60 s'),60000))]);session.destroy();
  console.log('turn          ->',outcome);
  console.log('tool calls    ->',seen.calls.length?seen.calls.join(' ; '):'(none)');
  console.log('reply parts   -> text parts:',seen.text,'· thought parts:',seen.thoughts,'· sound chunks:',seen.audio,'· transcript pieces:',seen.transcript);
  console.log('reply text    ->',seen.textSample?JSON.stringify(hide(seen.textSample).slice(0,300)):'(none: the reply was spoken only)');
})().catch(error=>{console.error(hide(error.stack||error));process.exitCode=1;});
