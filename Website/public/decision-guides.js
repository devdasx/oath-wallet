(() => {
 const panel=document.querySelector('.decision-controls'),filter=document.querySelector('[data-decision-filter]');
 if(!panel||!filter)return;
 const cards=[...document.querySelectorAll('[data-decision-value]')],count=document.querySelector('[data-decision-count]');
 function update(){let shown=0;for(const card of cards){card.hidden=!!filter.value&&card.dataset.decisionValue!==filter.value;if(!card.hidden)shown++;}count.textContent=`${shown} ${shown===1?'entry':'entries'} shown`;}
 panel.hidden=false;filter.addEventListener('change',update);update();
})();
