/* A shared presentation preference for detached tables; never changes a Study. */
(function(){
 'use strict';const KEY='WingFEGen.detached-table-theme.v1',button=document.getElementById('theme-button');
 function apply(value){const theme=value==='light'?'light':'dark';document.documentElement.dataset.tableTheme=theme;if(button){button.textContent=theme==='light'?'Dark theme':'Light theme';button.setAttribute('aria-pressed',String(theme==='light'));button.title='Switch detached tables between light and dark backgrounds';}}
 let saved='dark';try{saved=localStorage.getItem(KEY);}catch(_){}apply(saved);
 if(button)button.onclick=()=>{const next=document.documentElement.dataset.tableTheme==='light'?'dark':'light';apply(next);try{localStorage.setItem(KEY,next);}catch(_){}};
 addEventListener('storage',event=>{if(event.key===KEY)apply(event.newValue);});
})();
