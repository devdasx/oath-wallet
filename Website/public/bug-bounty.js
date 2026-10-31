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
