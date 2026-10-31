(() => {
 const status=document.getElementById('press-copy-status');let timeout;
 document.querySelectorAll('[data-copy-target],[data-copy-value]').forEach(button=>button.addEventListener('click',async()=>{
  const text=button.dataset.copyValue||document.getElementById(button.dataset.copyTarget)?.textContent;
  if(!text)return;
  try{await navigator.clipboard.writeText(text.trim());status.textContent=button.dataset.copyValue?'Colour copied.':'Press text copied.';}
  catch{status.textContent='Copy unavailable. Select the visible text to copy it manually.';}
  clearTimeout(timeout);status.classList.add('visible');timeout=setTimeout(()=>status.classList.remove('visible'),4500);
 }));
})();
