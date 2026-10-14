/* Large decks retain their complete, selectable text without laying out every
 * line on each pane resize. Browser search can reveal content-visibility chunks. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingDeckView=api;})(globalThis,function(){
 'use strict';
 function chunks(text,linesPerChunk=400){
  const result=[];let start=0,offset=0,lines=0,maxColumns=1;
  const tabs=text.includes('\t');
  while(offset<text.length){
   const newline=text.indexOf('\n',offset),end=newline<0?text.length:newline;
   let columns=end-offset;
   if(tabs){columns=0;for(let i=offset;i<end;i++)columns=text.charCodeAt(i)===9?columns+8-columns%8:columns+1;}
   maxColumns=Math.max(maxColumns,columns);lines++;offset=newline<0?text.length:newline+1;
   if(lines>=linesPerChunk||offset===text.length){result.push({start,end:offset,lines});start=offset;lines=0;}
  }
  return{chunks:result,maxColumns};
 }
 function create(host,{threshold=262144,linesPerChunk=400,search=null}={}){
  let current=null,blocks=[],highlighted=[],controls=null;
  function clearHighlight(){
   for(const block of highlighted)block.element.textContent=current.slice(block.start,block.end);
   highlighted=[];
  }
  function findFirst(query,{matchCase=false,scroll=true}={}){
   clearHighlight();query=String(query??'');
   if(!query||current===null)return{found:false,query};
   // Escape every metacharacter: deck search is literal, not a regex filter.
   const match=new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),matchCase?'':'i').exec(current);
   if(!match)return{found:false,query};
   const start=match.index,end=start+match[0].length;let first=null,firstBlock=null;
   for(const block of blocks){
    if(block.end<=start)continue;if(block.start>=end)break;
    const from=Math.max(start,block.start),to=Math.min(end,block.end),mark=host.ownerDocument.createElement('mark');
    mark.className='deck-search-match';mark.textContent=current.slice(from,to);
    block.element.replaceChildren(host.ownerDocument.createTextNode(current.slice(block.start,from)),mark,host.ownerDocument.createTextNode(current.slice(to,block.end)));
    highlighted.push(block);if(!first){first=mark;firstBlock=block;}
   }
   const prefix=current.slice(firstBlock.start,start),line=firstBlock.line+(prefix.match(/\n/g)||[]).length;
   const column=start-(start>0?current.lastIndexOf('\n',start-1):-1);
   if(scroll&&first)first.scrollIntoView({block:'center',inline:'center'});
   return{found:true,query,start,end,line,column};
  }
  function runSearch(scroll=true){
   if(!controls)return;
   const result=findFirst(controls.input.value,{matchCase:!!controls.matchCase?.checked,scroll});
   if(controls.status)controls.status.textContent=!result.query?'':result.found?'First match · line '+result.line+', column '+result.column:'No match in this deck.';
   return result;
  }
  function attachSearch(next){
   if(controls)throw Error('Deck search controls are already connected.');controls=next;
   controls.button?.addEventListener('click',()=>runSearch());
   controls.input.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();runSearch();}else if(event.key==='Escape'){event.preventDefault();controls.input.value='';runSearch(false);}});
   controls.input.addEventListener('input',()=>{clearHighlight();if(controls.status)controls.status.textContent='';});
   controls.matchCase?.addEventListener('change',()=>runSearch());
  }
  function setText(value){
   const text=String(value??'');if(text===current)return false;current=text;
   blocks=[];highlighted=[];host.classList.toggle('deck-chunked',text.length>threshold);host.replaceChildren();
   host.scrollTop=0;host.scrollLeft=0;
   if(text.length<=threshold){host.textContent=text;blocks=[{start:0,end:text.length,line:1,element:host}];}
   else{
    const index=chunks(text,linesPerChunk),lines=host.ownerDocument.createElement('span');lines.className='deck-lines';lines.style.minWidth=index.maxColumns+'ch';
    const fragment=host.ownerDocument.createDocumentFragment();let line=1;
    for(const chunk of index.chunks){const block=host.ownerDocument.createElement('span');block.className='deck-chunk';block.style.setProperty('--deck-chunk-lines',chunk.lines);block.textContent=text.slice(chunk.start,chunk.end);fragment.append(block);blocks.push({...chunk,line,element:block});line+=chunk.lines;}
    lines.append(fragment);host.append(lines);
   }
   runSearch(false);return true;
  }
  if(search)attachSearch(search);
  return{setText,findFirst,attachSearch};
 }
 return{chunks,create};
});
