const params=new URLSearchParams(location.search),token=params.get('token')||history.state?.token,messageID=params.get('message')||history.state?.messageID,controls=document.querySelector('#controls'),message=document.querySelector('#message');
// Remove bearer links from the address bar after reading them. Referrer-Policy also prevents leakage.
history.replaceState({token,messageID},'',location.pathname);
async function call(action,data={}){const r=await fetch('/_newsletter/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token,message_id:messageID,...data})});const d=await r.json();if(!r.ok)throw new Error(d.error);return d;}
function showError(e){message.className='form-error';message.textContent=e.message;}
async function init(){
 if(!token){document.querySelector('#description').textContent='Open the private link in your Oath email to manage your subscription.';return;}
 if(location.pathname==='/confirm'){
  document.querySelector('#title').textContent='No confirmation needed.';
  try{const d=await call('confirm');document.querySelector('#description').textContent=d.message;}
  catch(e){showError(e);}
  return;
 }
 try{
  const d=await call('preferences');document.querySelector('#description').textContent=d.status==='active'?'Choose the topics that belong in your inbox.':d.status==='pending'?'This signup is inactive. Subscribe on the newsletter page to join, or cancel it below.':d.status==='unsubscribed'?'You’re unsubscribed. Sign up again on the newsletter page if you’d like to rejoin.':'Email delivery to this address is paused. Contact care@oathwallet.org for help.';
  if(d.status==='active'){
   controls.innerHTML='<form id="prefs"><div class="preference-topics">'+[['oath','Oath Wallet updates'],['markets','Crypto news & market prices'],['security','Security alerts & scam awareness'],['guides','Wallet guides & network explainers']].map(([v,t])=>`<label><input type="checkbox" name="topic" value="${v}" ${d.topics.includes(v)?'checked':''}>${t}</label>`).join('')+'</div><button class="button primary full">Save preferences</button></form><button class="button danger-text full" id="unsubscribe">Unsubscribe from all emails</button>';
   controls.querySelector('form').onsubmit=async e=>{e.preventDefault();try{const r=await call('updatePreferences',{topics:[...controls.querySelectorAll('[name=topic]:checked')].map(i=>i.value)});message.className='success-text';message.textContent=r.message;}catch(e){showError(e);}};
  }
  if(d.status==='pending')controls.innerHTML='<button class="button danger-text full" id="unsubscribe">Cancel this signup</button>';
  controls.querySelector('#unsubscribe')?.addEventListener('click',async()=>{try{const r=await call('unsubscribe');controls.replaceChildren();document.querySelector('#title').textContent='You’re unsubscribed.';document.querySelector('#description').textContent=r.message;message.textContent='';}catch(e){showError(e);}});
 }catch(e){document.querySelector('#description').textContent='We couldn’t load your subscription.';showError(e);}
}
init();
