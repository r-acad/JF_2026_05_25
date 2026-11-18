'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const listeners=new Map(),messages=[],origin='http://127.0.0.1:43989',draft={value:'3.125',hasDrafts:false,assessment:'RF 0.75'};
let report={rows:[{pid:1,reserveFactor:.75}]},editorCleared=0;
const child={closed:false,document:{},focus(){},postMessage(message,target){assert.equal(target,origin);messages.push(message);}};
const env={location:{origin,href:origin+'/'},URL,Uint32Array,crypto:{getRandomValues:a=>a.fill(1)},WingReserveFactorTableData:{compact:value=>value},
 open:()=>child,setInterval:()=>1,clearInterval(){},addEventListener:(name,fn)=>listeners.set(name,fn),removeEventListener:name=>listeners.delete(name)};
vm.createContext(env);vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/reserve_factor_table_window.js'),'utf8'),env);
const bridge=env.WingReserveFactorTables.connect({readSnapshot:()=>({report}),onEditProperty:()=>({hasDrafts:()=>draft.hasDrafts,clearAssessment(reason){draft.assessment=reason;editorCleared++;},close(){}})});
assert(bridge.open());const token=env.WingReserveFactorTables.CHANNEL;
function receive(type,extra={}){listeners.get('message')({origin,source:child,data:{channel:token,token:messages[0]?.token||'00000001000000010000000100000001',type,...extra}});}
receive('ready');assert.equal(messages.at(-1).type,'snapshot');assert.equal(messages.at(-1).snapshot.report.rows[0].reserveFactor,.75);
assert(bridge.openProperty(1));draft.hasDrafts=true;
const count=messages.length;bridge.refresh(true);assert.equal(messages.length,count,'Normal refresh must retain unfinished property drafts.');
report=null;bridge.clearResults({reason:'Starting a new aerodynamic analysis.'});
assert.equal(messages.at(-1).type,'clear');assert.equal(editorCleared,1);assert.equal(draft.value,'3.125');assert.equal(draft.hasDrafts,true);assert.match(draft.assessment,/Starting/);
receive('ready');assert.equal(messages.at(-1).type,'clear','A table reconnect must receive invalidation even while drafts prevent refresh.');
draft.hasDrafts=false;bridge.refresh(true);assert.equal(messages.at(-1).snapshot.report,null);
report={rows:[{pid:1,reserveFactor:1.25}]};bridge.refresh();assert.equal(messages.at(-1).snapshot.report.rows[0].reserveFactor,1.25);
bridge.destroy();console.log('PASS detached RF invalidation bypasses draft guards, preserves inputs, survives reconnect and accepts only fresh results');
