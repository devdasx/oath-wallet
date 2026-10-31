// Initial HTML contains every guide. Filtering only hides matching cards.
(()=>{
 const search=document.querySelector('[data-network-search]');
 if(!search)return;
 const cards=[...document.querySelectorAll('[data-network-keywords]')];
 const filters=[...document.querySelectorAll('[data-network-filter]')];
 let group='all';
 function update(){
  const query=search.value.trim().toLocaleLowerCase();let visible=0;
  for(const card of cards){card.hidden=!(group==='all'||card.dataset.networkGroup===group)||!card.dataset.networkKeywords.toLocaleLowerCase().includes(query);if(!card.hidden)visible++;}
  document.querySelector('[data-network-count]').textContent=`${visible} ${visible===1?'network':'networks'}`;
  document.querySelector('[data-network-empty]').hidden=visible!==0;
  filters.forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.networkFilter===group)));
 }
 search.addEventListener('input',update);
 filters.forEach(button=>button.addEventListener('click',()=>{group=button.dataset.networkFilter;update();}));
 document.querySelector('[data-network-reset]')?.addEventListener('click',()=>{group='all';search.value='';update();search.focus();});
})();
