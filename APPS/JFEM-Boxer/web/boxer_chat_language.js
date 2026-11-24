/* Plain-language reading of chat requests for the built-in Commands mode.
 * Pure functions: no DOM, no network and no AI. The chat panel supplies the
 * live catalog of menu actions and inputs and performs the chosen command.
 */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.WingBoxerChatLanguage=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const clean=value=>String(value??'').replace(/\s+/g,' ').trim();
  const fold=value=>clean(value).normalize('NFKD').replace(/[̀-ͯ]/g,'').toLowerCase().replace(/[“”„«»]/g,'"').replace(/[‘’`´]/g,"'").replace(/[−–—]/g,'-');

  // Words that carry no meaning in the name of an input or action.
  const STOP=new Set(['the','a','an','of','for','to','in','on','at','my','our','this','that','please','pls','value','values','input','inputs','field','fields','parameter','parameters','setting','settings','option','options','its','is','be','and','with','by','me']);
  // Each word is replaced by one canonical word on both sides of a comparison.
  const SAME={thick:'thickness',thk:'thickness',thicknes:'thickness',gauge:'thickness',gage:'thickness',spacing:'pitch',separation:'pitch',
    num:'number',nb:'number',nr:'number',count:'number',qty:'number',quantity:'number',top:'upper',bottom:'lower',fwd:'front',forward:'front',aft:'rear',back:'rear',
    youngs:'young',poissons:'poisson',ang:'angle',len:'length',dia:'diameter',diam:'diameter',mesh:'fem',fe:'fem',meshing:'fem',
    analyse:'analysis',analyze:'analysis',solve:'analysis',solver:'analysis',generate:'create',build:'create',make:'create',
    colour:'color',centre:'center',fibre:'fiber',aluminium:'aluminum',metre:'meter',display:'show',view:'show',goto:'open',launch:'run',start:'run',execute:'run',
    stiffener:'stringer',longeron:'stringer',wingspan:'span',dens:'density',mat:'material',prop:'property',props:'property',geom:'geometry',config:'configuration',
    max:'maximum',min:'minimum',ref:'reference',pos:'position',location:'position',coord:'coordinate',temp:'temperature',freq:'frequency',eigenmode:'mode',eigenvalue:'mode'};
  // Abbreviations that stand for several words.
  const EXPAND={ar:['aspect','ratio'],le:['leading','edge'],te:['trailing','edge'],rf:['reserve','factor'],cg:['center','gravity'],aoa:['angle','attack'],nmodes:['number','mode']};
  function singular(word){
    if(word.length<4||/\d/.test(word))return word;
    if(word.endsWith('ies'))return word.slice(0,-3)+'y';
    if(word.endsWith('sses'))return word.slice(0,-2);
    if(/(?:ss|us|is)$/.test(word))return word;
    if(/(?:xes|ches|shes)$/.test(word))return word.slice(0,-2);
    return word.endsWith('s')?word.slice(0,-1):word;
  }
  function words(text){
    const out=[];
    for(const raw of fold(text).replace(/(\d)[.,](\d)/g,'$1_$2').match(/[a-z0-9_]+/g)||[]){
      for(const part of raw.replace(/_/g,'.').replace(/([a-z])(\d)/g,'$1 $2').replace(/(\d)([a-z])/g,'$1 $2').split(' ')){
        if(!part||STOP.has(part))continue;
        const base=singular(part);
        for(const word of EXPAND[base]||[SAME[base]||SAME[part]||base])if(!STOP.has(word))out.push(word);
      }
    }
    return out;
  }
  // Optimal-string-alignment distance with an early exit; names are short.
  function distance(a,b,limit){
    if(Math.abs(a.length-b.length)>limit)return limit+1;
    let previous=null,current=Array.from({length:b.length+1},(_,i)=>i);
    for(let i=1;i<=a.length;i++){
      const next=[i];let best=i;
      for(let j=1;j<=b.length;j++){
        let value=Math.min(current[j]+1,next[j-1]+1,current[j-1]+(a[i-1]===b[j-1]?0:1));
        if(previous&&i>1&&j>1&&a[i-1]===b[j-2]&&a[i-2]===b[j-1])value=Math.min(value,previous[j-2]+1);
        next.push(value);best=Math.min(best,value);
      }
      if(best>limit)return limit+1;
      previous=current;current=next;
    }
    return current[b.length];
  }
  function similar(a,b){
    if(a===b)return 1;
    if(/\d/.test(a)||/\d/.test(b))return 0;
    const short=Math.min(a.length,b.length);
    if(short>=3&&(a.startsWith(b)||b.startsWith(a)))return .85;
    if(short>=4&&distance(a,b,1)<=1)return .8;
    if(short>=7&&distance(a,b,2)<=2)return .7;
    return 0;
  }
  function compare(query,name,context){
    if(!query.length||!name.length)return{score:0,exact:false,fuzzy:false};
    let total=0,fuzzy=false,outside=0;const used=new Set();
    for(const word of query){
      let best=0,index=-1;
      name.forEach((candidate,i)=>{const value=similar(word,candidate);if(value>best){best=value;index=i;}});
      if(best>=.7){used.add(index);if(best<1)fuzzy=true;total+=best;continue;}
      let other=0;for(const candidate of context)other=Math.max(other,similar(word,candidate));
      if(other>=.7){total+=.6*other;outside++;}
    }
    if(!used.size)return{score:outside?Math.min(.45,.6*outside/query.length):0,exact:false,fuzzy:false};
    const recall=total/query.length,precision=used.size/name.length;
    return{score:recall*(.8+.2*precision),exact:!fuzzy&&!outside&&recall===1&&precision===1,fuzzy};
  }
  // A view is published as “Model: Materials”; people call it “materials”.
  const names=entry=>{
    const label=clean(entry.label??entry.name??entry.title??''),tail=/^[^:]{2,24}:\s+(.+)$/.exec(label);
    return[label,...(Array.isArray(entry.aliases)?entry.aliases:[]),...(tail?[tail[1]]:[])].filter(Boolean);
  };
  const available=entry=>entry.enabled!==false&&entry.disabled!==true&&entry.readonly!==true&&entry.editable!==false;
  const identity=entry=>entry.action_id??entry.input_id??entry.id??entry.key;

  /* Rank catalog entries against a spoken name. Returns the best first. */
  function rank(query,entries,limit=40){
    const wanted=words(query),plain=fold(query),results=[];
    if(!wanted.length&&!plain)return results;
    (entries||[]).forEach((entry,index)=>{
      const context=words([Array.isArray(entry.path)?entry.path.join(' '):entry.context??entry.group??'',entry.parameter_key??'',identity(entry)??''].join(' '));
      let best={score:0,exact:false,fuzzy:false};
      for(const name of names(entry)){
        const value=fold(name)===plain?{score:1,exact:true,fuzzy:false}:compare(wanted,words(name),context);
        if(value.exact&&!best.exact||value.score>best.score&&!best.exact)best=value;
      }
      if(String(identity(entry)??'').toLowerCase()===plain)best={score:1,exact:true,fuzzy:false};
      // The “?” buttons beside forms share their form's name. They are offered only when help is asked for.
      if(/^help\b/i.test(names(entry)[0]??'')&&!/\bhelp\b/.test(plain))best={score:best.score*.6,exact:false,fuzzy:best.fuzzy};
      if(best.score<=0)return;
      results.push({entry,index,exact:best.exact,fuzzy:best.fuzzy,raw:best.score,score:best.exact?1:Math.min(.98,best.score)*(available(entry)?1:.85)});
    });
    results.sort((a,b)=>Number(b.exact)-Number(a.exact)||b.score-a.score||Number(!!b.entry.curated)-Number(!!a.entry.curated)||a.index-b.index);
    return results.slice(0,limit);
  }
  /* Decide whether the ranking names one entry, several, or none.
   * match: the single entry to use; candidates: entries to offer as choices;
   * loose: weaker look-alikes to mention when nothing matched. */
  function decide(ranked){
    const exact=ranked.filter(item=>item.exact);
    if(exact.length){
      const curated=exact.filter(item=>item.entry.curated===true&&available(item.entry)),usable=exact.filter(item=>available(item.entry));
      // Boxer gives spoken aliases to its principal inputs. Among identical names that one is meant.
      const principal=usable.filter(item=>Array.isArray(item.entry.aliases)&&item.entry.aliases.length);
      const match=curated.length===1?curated[0]:usable.length===1?usable[0]:principal.length===1?principal[0]:exact.length===1?exact[0]:null;
      return{match,candidates:match?[match]:exact.slice(0,8),loose:[]};
    }
    let strong=ranked.filter(item=>item.score>=.5);
    if(!strong.length)return{match:null,candidates:[],loose:ranked.filter(item=>item.score>=.28).slice(0,4)};
    // A curated command and the menu button it wraps carry the same label.
    const label=item=>fold(names(item.entry)[0]??''),twins=strong.filter(item=>item.score===strong[0].score&&label(item)===label(strong[0]));
    const curated=twins.filter(item=>item.entry.curated===true&&available(item.entry));
    if(twins.length>1&&curated.length===1)strong=strong.filter(item=>item===curated[0]||!twins.includes(item));
    const top=strong[0],second=strong[1],gap=second?top.score-second.score:1;
    if(top.score>=.75&&gap>=.12||top.score>=.6&&gap>=.3)return{match:top,candidates:[top],loose:[]};
    return{match:null,candidates:strong.filter(item=>item.score>=top.score-.25).slice(0,8),loose:[]};
  }

  const UNIT={mm:'mm',millimetre:'mm',millimetres:'mm',millimeter:'mm',millimeters:'mm',cm:'cm',centimetre:'cm',centimetres:'cm',centimeter:'cm',centimeters:'cm',
    m:'m',metre:'m',metres:'m',meter:'m',meters:'m',in:'in',inch:'in',inches:'in','"':'in',ft:'ft',foot:'ft',feet:'ft',"'":'ft',
    deg:'deg',degs:'deg',degree:'deg',degrees:'deg','°':'deg','º':'deg',rad:'rad',radian:'rad',radians:'rad','%':'%',percent:'%',pct:'%',
    pa:'pa',kpa:'kpa',mpa:'mpa',gpa:'gpa',n:'n',kn:'kn',newton:'n',newtons:'n',kg:'kg',g:'g',kilogram:'kg',kilograms:'kg',
    mm2:'mm2',cm2:'cm2',m2:'m2',in2:'in2',ft2:'ft2',sqm:'m2'};
  const SCALE={length:{mm:.001,cm:.01,m:1,in:.0254,ft:.3048},area:{mm2:1e-6,cm2:1e-4,m2:1,in2:.0254**2,ft2:.3048**2},
    pressure:{pa:1,kpa:1e3,mpa:1e6,gpa:1e9},force:{n:1,kn:1e3},mass:{g:.001,kg:1},angle:{deg:Math.PI/180,rad:1}};
  const unitName=value=>{const text=fold(value).replaceAll('²','2').replaceAll('³','3').replace(/\^/g,'').replace(/\s+/g,'').replace(/\.$/,'');return UNIT[text]??text;};
  const entryLabel=entry=>clean(entry?.label??entry?.name??entry?.title??identity(entry??{})??'this input');
  function entryUnit(entry){
    const stated=clean(entry?.units??entry?.unit??'')||((entryLabel(entry).match(/\(([^()]{1,8})\)\s*$/)||[])[1]??'');
    const unit=unitName(stated);return /^[-–—]?$|^none$/.test(unit)?'':unit;
  }
  const TRUE=['true','on','yes','enabled','enable','show','shown','visible','checked','active','activated','1'];
  const FALSE=['false','off','no','disabled','disable','hide','hidden','invisible','unchecked','inactive','deactivated','0'];
  const boolean=entry=>['checkbox','radio'].includes(entry?.type)||entry?.kind==='boolean'||typeof entry?.value==='boolean';
  const NUMBER='[-+]?\\s?(?:\\d[\\d.,]*\\d|\\d|[.,]\\d+)(?:e[-+]?\\d+)?';
  function decimal(text){
    let value=text.replace(/\s/g,'');const sign=value.startsWith('-')?-1:1;value=value.replace(/^[-+]/,'');
    let exponent='';const power=value.match(/e[-+]?\d+$/i);if(power){exponent=power[0];value=value.slice(0,-exponent.length);}
    const commas=(value.match(/,/g)||[]).length,dots=(value.match(/\./g)||[]).length;
    if(commas&&dots)value=value.lastIndexOf(',')>value.lastIndexOf('.')?value.replace(/\./g,'').replace(',','.'):value.replace(/,/g,'');
    else if(commas>1||dots>1){
      if(!/^\d{1,3}(?:[.,]\d{3})+$/.test(value))throw Error('I could not read “'+text+'” as a number.');
      value=value.replace(/[.,]/g,'');
    }else if(commas){
      // One comma before exactly three digits can be a decimal or a thousands separator.
      if(/^[1-9]\d{0,2},\d{3}$/.test(value))throw Error('“'+text+'” can mean '+value.replace(',','.')+' or '+value.replace(',','')+'. Write the number without a thousands separator, for example '+value.replace(',','.')+' or '+value.replace(',','')+'.');
      value=value.replace(',','.');
    }
    const number=sign*Number(value+exponent);
    if(!Number.isFinite(number))throw Error('I could not read “'+text+'” as a number.');
    return number;
  }
  function chooseOption(text,entry){
    const options=(entry.options||[]).filter(option=>!option.disabled),wanted=fold(text).replace(/^"(.*)"$/,'$1');
    const direct=options.filter(option=>fold(option.value)===wanted||fold(option.label??'')===wanted);
    if(direct.length===1)return direct[0].value;
    const result=decide(rank(text,options.map(option=>({label:option.label||option.value,aliases:[String(option.value)],option}))));
    if(result.match)return result.match.entry.option.value;
    const list=(result.candidates.length?result.candidates.map(item=>item.entry.option):options).slice(0,12).map(option=>'“'+clean(option.label||option.value)+'”').join(', ');
    throw Error(result.candidates.length?'“'+clean(text)+'” matches several choices of '+entryLabel(entry)+': '+list+'. Repeat the request with one of them.':
      entryLabel(entry)+' has no choice like “'+clean(text)+'”. It accepts: '+list+(options.length>12?' and '+(options.length-12)+' more':'')+'.');
  }
  /* Read the value a person typed for a given input: numbers with a decimal
   * point or comma, an optional unit that is converted to the input's unit,
   * on/off words for switches and option names for lists. */
  function parseValue(text,entry){
    let value=clean(text).replace(/[!?]+$/,'').replace(/(?<=\D)\.$/,'').trim();
    const quoted=value.match(/^(["'“”‘’])(.*)\1$/)||value.match(/^[“‘](.*)[”’]$/);
    if(quoted&&!boolean(entry)&&!Array.isArray(entry?.options))return quoted[quoted.length-1];
    if(quoted)value=quoted[quoted.length-1];
    const word=fold(value);
    if(boolean(entry)){
      if(TRUE.includes(word))return true;
      if(FALSE.includes(word))return false;
      throw Error(entryLabel(entry)+' is an on/off switch. Say “on” or “off”, for example “turn '+entryLabel(entry).toLowerCase()+' on”.');
    }
    if(Array.isArray(entry?.options)&&entry.options.length)return chooseOption(value,entry);
    const number=fold(value).match(new RegExp('^('+NUMBER+')\\s*(.*)$','i'));
    const numeric=['number','range','float','int','integer'].includes(entry?.type)||typeof entry?.value==='number';
    // Free-text inputs (a title, a file name) keep exactly what was typed.
    if(!numeric&&!entryUnit(entry)&&!(number&&!number[2].replace(/\.$/,'').trim()&&/^[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?\.?$/i.test(value)))return value;
    if(!number)throw Error(entryLabel(entry)+' needs a number'+(entryUnit(entry)?' in '+entryUnit(entry):'')+', but “'+clean(text)+'” is not one.');
    const tail=number[2].replace(/\.$/,'').trim(),supplied=unitName(tail),target=entryUnit(entry);
    if(tail&&!/^[a-zµ%°º"'/0-9]{1,12}$/.test(supplied))throw Error('I could not read “'+clean(text)+'” as a number'+(target?' in '+target:'')+' for '+entryLabel(entry)+'.');
    let result=decimal(number[1]);
    if(supplied&&supplied!==target){
      const family=Object.values(SCALE).find(table=>table[supplied]!==undefined&&table[target]!==undefined);
      if(family)result=Number((result*family[supplied]/family[target]).toPrecision(12));
      else if(supplied==='%'&&!target)result=Number((result/100).toPrecision(12));
      else if(!target)throw Error(entryLabel(entry)+' shows no unit in Boxer, but the value was given in “'+tail+'”. Enter the number alone.');
      else throw Error('The value was given in “'+tail+'”, but '+entryLabel(entry)+' is in '+target+'. Enter it in '+target+'.');
    }
    return result;
  }

  const POLITE=/^(?:(?:please|pls|kindly|ok|okay|hey|hi|hello|now|boxer|and|then|also)[,!]?\s+|(?:can|could|would|will) you (?:please )?|(?:i|we)(?: would|'d)? (?:like|want|need) (?:you )?to |let(?:'s| us) )/i;
  const ASSIGN='set|make|change|put|use|update|adjust|modify|edit|define|enter|give|apply|switch|turn|fix|specify|assign|let|have|bring|move|select|choose|pick|increase|decrease|raise|lower|reduce';
  const LINK='to be|to|as|at|equal to|equals|equal|be|is|into|with a value of|with value|to a value of';
  const VALUE=NUMBER+'(?:\\s?(?:%|°|º|"|[a-zµ²³/]{1,12}[0-9²³]?))?';
  const NAVIGATE=/^(?:open|go to|goto|switch to|navigate to|take me to|bring up|jump to|show me|show|display|view|click on|click|press|push|run|start|launch|execute|do|perform|select|choose|activate)\s+(?:the\s+)?/i;
  function strip(text){
    let value=clean(text),previous;
    do{previous=value;value=value.replace(POLITE,'');}while(value!==previous);
    return value.replace(/[\s,]+(?:please|pls|thanks|thank you|for me|now)[.!]*$/i,'').replace(/[?!]+$/,'').replace(/(?<=[^\d.])\.+$/,'').trim();
  }
  /* Turn one request into an intent. Nothing is looked up here. */
  function parse(text){
    const original=clean(text),value=strip(original),plain=fold(value);
    const out=(intent,extra)=>({intent,text:value,original,...extra});
    if(!plain)return out('empty');
    if(/^(?:show |what is |whats |what's |get |give me |display |tell me )?(?:the )?(?:current )?(?:study |model |boxer )?(?:status|state)$/.test(plain))return out('status');
    if(/^(?:help|\?|what can (?:you|i) (?:do|say|ask)|examples?|commands?|how does this work|how do i use this)$/.test(plain))return out('help');
    let match=value.match(/^(?:find|list|search(?: for)?|show(?: me)?|which|what)\s+(?:all\s+)?(?:the\s+)?(.*?)\s*\b(inputs?|settings|parameters?|fields?|actions?|commands?|buttons?|menus?)(?:\s+(?:for|about|with|matching|containing|named|called|are there for)\s+(.+))?$/i);
    if(match)return out('search',{kind:/^(?:action|command|button|menu)/i.test(match[2])?'actions':'inputs',target:clean(match[3]||match[1]).replace(/^(?:all|every|available)\s*/i,'')});
    match=value.match(/^(?:find|search(?: for)?|look for|where is|where are)\s+(?:the\s+)?(.+)$/i);
    if(match)return out('search',{kind:'any',target:match[1]});
    match=value.match(new RegExp('^(increase|raise|grow|decrease|reduce|lower|shrink)\\s+(?:the\\s+)?(.+?)\\s+by\\s+(?:a factor of\\s+)?('+VALUE+')$','i'));
    if(match)return out('adjust',{target:match[2],amount:match[3],sign:/^(?:increase|raise|grow)$/i.test(match[1])?1:-1});
    match=value.match(new RegExp('^(add|subtract)\\s+('+VALUE+')\\s+(?:to|from)\\s+(?:the\\s+)?(.+)$','i'));
    if(match)return out('adjust',{target:match[3],amount:match[2],sign:/^add$/i.test(match[1])?1:-1});
    match=value.match(/^(double|halve|half)\s+(?:the\s+)?(.+)$/i);
    if(match)return out('adjust',{target:match[2],factor:/^double$/i.test(match[1])?2:.5});
    const verb=new RegExp('^(?:'+ASSIGN+')\\s+','i');
    match=value.match(/^(.+?)\s*(?::=|==|=>|->|→|=)\s*(.+)$/);
    if(match&&clean(match[1].replace(verb,'')))return out('assign',{target:clean(match[1].replace(verb,'').replace(/^(?:the|an?)\s+/i,'')),value:match[2]});
    match=value.match(new RegExp('^(.+?):\\s*('+VALUE+'|on|off|yes|no|true|false)$','i'));
    if(match)return out('assign',{target:match[1].replace(verb,'').replace(/^(?:the|an?)\s+/i,''),value:match[2]});
    match=value.match(/^(?:turn|switch)\s+(?:the\s+)?(.+?)\s+(on|off)$/i);
    if(match)return out('toggle',{target:match[1],on:/^on$/i.test(match[2])});
    match=value.match(/^(show|unhide|enable|activate|turn on|switch on|check|tick|hide|disable|deactivate|turn off|switch off|uncheck|untick)\s+(?:the\s+)?(.+)$/i);
    if(match)return out('toggle',{target:match[2],on:/^(?:show|unhide|enable|activate|turn on|switch on|check|tick)$/i.test(match[1]),verb:match[1].toLowerCase()});
    const first=value.match(verb);
    if(first){
      const rest=value.slice(first[0].length).replace(/^(?:the|an?)\s+/i,'');
      // “put 2,5 mm as upper skin thickness”: the value comes first.
      match=rest.match(new RegExp('^('+VALUE+')\\s+(?:for|as|in|on|to|into)\\s+(?:the\\s+)?(.+)$','i'));
      if(match)return out('assign',{target:match[2],value:match[1]});
      match=rest.match(new RegExp('^(.+)\\s+(?:'+LINK+')\\s+(.+)$','i'));
      if(match)return out('assign',{target:match[1].replace(/\s+from\s+\S+(?:\s+\S+)?$/i,''),value:match[2]});
      match=rest.match(new RegExp('^(.+?)\\s+of\\s+('+VALUE+')$','i'));
      if(match)return out('assign',{target:match[1],value:match[2]});
      match=rest.match(new RegExp('^(.+?)\\s+('+VALUE+')$','i'));
      if(match)return out('assign',{target:match[1],value:match[2]});
      if(/^(?:set|change|update|adjust|modify|edit|define|enter|specify|assign|fix)\b/i.test(first[0]))return out('search',{kind:'inputs',target:rest,needsValue:true});
    }
    match=value.match(new RegExp('^(?:i|we)\\s+(?:want|need|would like|\'d like)\\s+(?:the\\s+|an?\\s+)?(.+?)\\s+(?:to be|to equal|to|at|of|as)\\s+(.+)$','i'))||
      value.match(/^(?:the\s+)?(.+?)\s+(?:should|must|shall|needs to|has to|ought to)\s+(?:be|equal)\s+(.+)$/i);
    if(match)return out('assign',{target:match[1],value:match[2]});
    match=value.match(/^(?:what is|whats|what's|what are|tell me|give me|get|read|how (?:much|many|big|long|thick|large|wide) is|value of|current)\s+(?:the\s+)?(?:current\s+)?(?:value of\s+)?(?:the\s+)?(.+)$/i);
    if(match)return out('read',{target:match[1]});
    match=value.match(new RegExp('^(.+?)\\s+(?:'+LINK+')\\s+('+VALUE+')$','i'))||value.match(new RegExp('^(.+?)\\s+('+VALUE+')$','i'));
    // “go to the materials tab” names the view “materials”.
    const query=value.replace(NAVIGATE,'').replace(/\s+(?:tab|page|view|form|menu|panel|window|screen|section)$/i,'');
    if(match)return out('assign',{target:match[1].replace(/^(?:the|an?)\s+/i,''),value:match[2],implicit:true,query});
    return out('action',{target:value,query});
  }
  /* Split “set A to 1 and B to 2; open Geometry” into separate requests.
   * Names may contain “and”, so the caller must confirm that every part
   * resolves before it runs any of them. Quoted text is never split. */
  function parseAll(text){
    const whole=parse(text);
    if(/["“”]/.test(text))return[whole];
    const pieces=clean(text).split(/\s*;\s*|\s*,?\s+(?:and then|then|and also|and)\s+/i).map(clean).filter(Boolean);
    if(pieces.length<2||pieces.length>6)return[whole];
    const parsed=[];let lead='';
    for(const piece of pieces){
      let item=parse(piece);
      // “… and aspect ratio to 9” inherits the verb of the previous part.
      if(lead&&(item.intent==='action'||item.implicit)){const retry=parse(lead+' '+piece);if(retry.intent==='assign'&&!retry.implicit)item=retry;}
      if(!['assign','adjust','toggle','status','action'].includes(item.intent))return[whole];
      const verb=strip(piece).match(new RegExp('^(?:'+ASSIGN+')\\b','i'));if(verb)lead=verb[0];
      parsed.push(item);
    }
    return parsed;
  }
  /* One sentence that tells the person how the request was read. */
  function describe(parsed){
    const quote=value=>'“'+clean(value)+'”';
    switch(parsed.intent){
      case 'assign':return 'set '+quote(parsed.target)+' to '+quote(parsed.value);
      case 'adjust':return parsed.factor?(parsed.factor>1?'double ':'halve ')+quote(parsed.target):(parsed.sign>0?'increase ':'decrease ')+quote(parsed.target)+' by '+quote(parsed.amount);
      case 'toggle':return 'turn '+quote(parsed.target)+(parsed.on?' on':' off');
      case 'read':return 'read the value of '+quote(parsed.target);
      case 'search':return parsed.needsValue?'change '+quote(parsed.target)+' (no new value given)':'find '+(parsed.kind==='actions'?'actions':parsed.kind==='inputs'?'inputs':'items')+' named '+quote(parsed.target);
      case 'status':return 'show the Study status';
      case 'help':return 'show help';
      default:return 'run the menu action '+quote(parsed.query||parsed.target);
    }
  }
  return{parse,parseAll,describe,rank,decide,parseValue,words,similar,entryUnit,available};
});
