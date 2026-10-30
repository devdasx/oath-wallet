(() => {
 'use strict';
 if(window.__oathNewsletterLoaded)return;window.__oathNewsletterLoaded=true;
 const key='oath_newsletter_seen_v1';
 const topics=[['oath','Oath updates','New features & release notes'],['markets','Markets & prices','The moves, with context'],['security','Security brief','Scams, alerts & safer habits'],['guides','Wallet essentials','Useful guides, minus the jargon']];
 function seen(){try{if(localStorage.getItem(key))return true;}catch{}return document.cookie.split(';').some(v=>v.trim().startsWith(key+'='));}
 function remember(){try{localStorage.setItem(key,'1');}catch{}const domain=location.hostname.endsWith('oathwallet.org')?'; Domain=oathwallet.org':'';document.cookie=`${key}=1; Path=/; Max-Age=34560000; SameSite=Lax${domain}${location.protocol==='https:'?'; Secure':''}`;}
 const dialog=document.createElement('dialog');dialog.className='on-dialog';dialog.setAttribute('aria-labelledby','on-title');
 dialog.innerHTML=`<button type="button" class="on-close" aria-label="Close newsletter signup">×</button><div class="on-layout"><div class="on-intro"><img src="/assets/brand/oath-mark-light.svg" width="44" height="44" alt="Oath Wallet"><span class="on-kicker">THE OATH NEWSLETTER</span><h2 id="on-title">Crypto, <br>with perspective.</h2><p>A little clarity in a noisy world. Meet <strong>Oath Notes</strong> — the updates worth opening.</p><div class="on-edition"><span>01 / IN YOUR INBOX</span><strong>Less noise.<br>More understanding.</strong><span>By the people behind Oath Wallet.</span></div></div><form class="on-form"><span class="on-kicker">MAKE IT YOURS</span><h3>Stay in the know.</h3><p class="on-muted">Choose what you’d like to hear about.</p><div class="on-topics">${topics.map(([id,title,detail])=>`<label class="on-topic"><input type="checkbox" name="topic" value="${id}" checked><span><strong>${title}</strong><small>${detail}</small></span></label>`).join('')}</div><label class="on-label" for="on-email">Email address</label><input id="on-email" class="on-email" name="email" type="email" inputmode="email" autocomplete="email" placeholder="you@example.com" maxlength="100" required><div class="on-trap" aria-hidden="true"><label>Website<input name="website" tabindex="-1" autocomplete="off"></label></div><p class="on-consent"><span>By selecting Join Oath Notes, you agree to receive the newsletter. Unsubscribe anytime. <a href="https://oathwallet.org/privacy" target="_blank" rel="noopener">Privacy policy</a></span></p><button class="on-submit" type="submit">Join Oath Notes <span aria-hidden="true">↗</span></button><p class="on-status" role="status" aria-live="polite"></p><p class="on-fine">Free to join. Subscribe instantly. No email confirmation needed. Never share your recovery phrase or private keys.</p></form></div>`;
 document.body.append(dialog);
 const close=()=>dialog.close();dialog.querySelector('.on-close').addEventListener('click',close);
 dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)close();}});
 let previousFocus;function open(){if(dialog.open)return;previousFocus=document.activeElement;dialog.showModal();remember();document.documentElement.classList.add('on-modal-open');}
 dialog.addEventListener('close',()=>{document.documentElement.classList.remove('on-modal-open');previousFocus?.focus?.();});
 document.querySelectorAll('[data-newsletter-open]').forEach(button=>button.addEventListener('click',open));
 if(location.hostname!=='news.oathwallet.org'&&!location.pathname.startsWith('/news/')&&!location.pathname.startsWith('/newsletter-preview')){
  const launcher=document.createElement('button');launcher.className='on-launcher';launcher.type='button';launcher.innerHTML='<span aria-hidden="true">✉</span> Oath Notes';launcher.addEventListener('click',open);document.body.append(launcher);
  if(!seen())setTimeout(()=>{
   const showWhenVisible=()=>{if(seen()){document.removeEventListener('visibilitychange',showWhenVisible);return;}if(document.visibilityState==='visible'){document.removeEventListener('visibilitychange',showWhenVisible);open();}};
   document.addEventListener('visibilitychange',showWhenVisible);showWhenVisible();
  },6000);
 }
 const form=dialog.querySelector('form');form.addEventListener('submit',async event=>{
  event.preventDefault();const status=form.querySelector('.on-status'),button=form.querySelector('.on-submit');
  const selected=[...form.querySelectorAll('[name=topic]:checked')].map(i=>i.value);
  if(!selected.length){status.textContent='Choose at least one topic.';return;}
  button.disabled=true;button.textContent='Saving your signup…';status.textContent='';
  try{
   const response=await fetch('/_newsletter/signup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:form.email.value,topics:selected,consent:true,website:form.website.value,source:location.pathname}),signal:AbortSignal.timeout(25000)});
   const result=await response.json();if(!response.ok)throw new Error(result.error||'Please try again.');
   remember();form.innerHTML='<div class="on-success"><span class="on-success-icon" aria-hidden="true">✓</span><span class="on-kicker">A LITTLE MORE CLARITY</span><h3>You’re subscribed.</h3><p class="on-success-message"></p><button type="button" class="on-submit">Back to Oath</button><p class="on-fine">Look for care@oathwallet.org. We’ll never ask for your wallet keys.</p></div>';
   form.querySelector('.on-success-message').textContent=result.message;form.querySelector('button').addEventListener('click',close);form.querySelector('button').focus();
  }catch(error){status.textContent=error.name==='TimeoutError'?'The connection took too long. Try again; duplicate signups are safely handled.':error.message;button.disabled=false;button.innerHTML='Join Oath Notes <span aria-hidden="true">↗</span>';}
 });
})();
