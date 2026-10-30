/* First-party anonymous website statistics. No GPS, fingerprinting or query strings. */
(() => {
  if (location.hostname !== 'oathwallet.org' || window.__oathVisitorEventsLoaded) return;
  window.__oathVisitorEventsLoaded = true;
  let pending = Promise.resolve();
  if (navigator.globalPrivacyControl || navigator.doNotTrack === '1' || window.doNotTrack === '1') return;
  let current;
  const session = () => {
    const now=Date.now();
    try { current=JSON.parse(sessionStorage.getItem('oath-visit')); } catch {}
    if(!current || now-current.last>30*60*1000) current={id:crypto.randomUUID(),last:now};
    current.last=now;
    try {sessionStorage.setItem('oath-visit',JSON.stringify(current));} catch {}
    return current.id;
  };
  function record(kind) {
    const payload={id:crypto.randomUUID(), session:session(),kind,path:location.pathname,referrer:document.referrer};
    // A short, bounded retry preserves the event ID, so retrying never double-counts.
    const send=()=>fetch('/_events',{method:'POST',credentials:'same-origin',keepalive:true,headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
    pending = pending.then(send).then(async r=>{if(r.status===503){await new Promise(resolve=>setTimeout(resolve,2000));await send();}}).catch(()=>{});
  }
  let viewed=false;
  function visible(){if(!viewed && document.visibilityState==='visible'){viewed=true;record('page_view');}}
  document.addEventListener('visibilitychange',visible); visible();
  document.addEventListener('click',event=>{
    const link=event.target.closest?.('a[href]'); if(!link)return;
    try {const u=new URL(link.href); if(u.hostname==='apps.apple.com' && u.pathname.includes('id6780187283') && !u.searchParams.has('see-all')) record('download');} catch {}
  },{capture:true});
})();
