document.querySelectorAll('.oath-walkthrough').forEach(root=>{
  const steps=[...root.querySelectorAll('[data-step]')];
  const controls=root.querySelector('.walkthrough-controls');
  const previous=root.querySelector('[data-prev]');
  const next=root.querySelector('[data-next]');
  const progress=root.querySelector('[data-progress]');
  if(!steps.length||!controls||!previous||!next||!progress)return;
  let current=0;
  function show(index){
    current=index;
    steps.forEach((step,i)=>{step.hidden=i!==current;});
    previous.disabled=current===0;
    next.textContent=current===steps.length-1?'Start again':'Next step';
    progress.textContent=`Step ${current+1} of ${steps.length}`;
  }
  previous.addEventListener('click',()=>show(Math.max(0,current-1)));
  next.addEventListener('click',()=>show((current+1)%steps.length));
  controls.hidden=false;show(0);
});
