// The report stays in the browser until the researcher chooses a private channel.
const copyButton=document.getElementById('copy-report');
copyButton?.addEventListener('click',async()=>{
 const template=document.getElementById('report-template');
 const status=document.getElementById('copy-status');
 try {
  await navigator.clipboard.writeText(template.textContent);
  status.textContent='Template copied. Paste it into your private report.';
 } catch {
  template.closest('details').open=true;
  status.textContent='Copy is unavailable here. Select the template below or download the text file.';
 }
});

// A fixed UTC launch instant keeps the countdown consistent across time zones.
const launch=document.querySelector('.bounty-launch');
if(launch){
 const start=Date.parse(launch.dataset.bountyStart);
 const timer=launch.querySelector('.bounty-countdown');
 const status=document.getElementById('bounty-launch-status');
 if(Number.isFinite(start)&&timer&&status){
  let interval;
  const update=()=>{
   const remaining=Math.max(0,Math.ceil((start-Date.now())/1000));
   if(remaining===0){
    timer.hidden=true;
    status.textContent='Program is open';
    launch.querySelector('time').hidden=true;
    if(interval!==undefined)clearInterval(interval);
    return false;
   }
   const values={days:Math.floor(remaining/86400),hours:Math.floor(remaining/3600)%24,minutes:Math.floor(remaining/60)%60,seconds:remaining%60};
   for(const [unit,value] of Object.entries(values)){
    timer.querySelector(`[data-countdown="${unit}"]`).textContent=String(value).padStart(2,'0');
   }
   timer.hidden=false;
   return true;
  };
  if(update())interval=setInterval(update,1000);
 }
}
