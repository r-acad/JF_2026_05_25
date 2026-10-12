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
 function create(host,{threshold=262144,linesPerChunk=400}={}){
  let current=null;
  function setText(value){
   const text=String(value??'');if(text===current)return false;current=text;
   host.classList.toggle('deck-chunked',text.length>threshold);host.replaceChildren();
   host.scrollTop=0;host.scrollLeft=0;
   if(text.length<=threshold){host.textContent=text;return true;}
   const index=chunks(text,linesPerChunk),lines=host.ownerDocument.createElement('span');lines.className='deck-lines';lines.style.minWidth=index.maxColumns+'ch';
   const fragment=host.ownerDocument.createDocumentFragment();
   for(const chunk of index.chunks){const block=host.ownerDocument.createElement('span');block.className='deck-chunk';block.style.setProperty('--deck-chunk-lines',chunk.lines);block.textContent=text.slice(chunk.start,chunk.end);fragment.append(block);}
   lines.append(fragment);host.append(lines);return true;
  }
  return{setText};
 }
 return{chunks,create};
});
