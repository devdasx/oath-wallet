(() => {
  const tool = document.querySelector('.transfer-tool');
  if (!tool) return;
  const controls = tool.querySelector('.transfer-controls');
  const token = tool.querySelector('#transfer-token');
  const network = tool.querySelector('#transfer-network');
  const choices = [...network.options].filter(option => option.dataset.token);
  const cards = [...tool.querySelectorAll('[data-transfer-path]')];
  const count = tool.querySelector('[data-transfer-count]');
  const review = tool.querySelector('.transfer-review');
  const checks = [...review.querySelectorAll('input')];
  const reviewStatus = tool.querySelector('[data-transfer-review-status]');
  function reviewUpdate() {
    reviewStatus.textContent = checks.every(check => check.checked)
      ? 'Your checklist is complete. Review the destination, amount and final fee in the sending app before confirming.'
      : 'Complete each check before confirming in the sending app.';
  }
  function update() {
    for (const option of choices) {
      option.hidden = option.disabled = option.dataset.token !== token.value;
    }
    if (!choices.some(option => !option.disabled && option.value === network.value)) network.value = '';
    network.disabled = !token.value;
    let shown = 0;
    for (const card of cards) {
      card.hidden = !!((token.value && card.dataset.transferToken !== token.value) || (network.value && card.dataset.transferPath !== network.value));
      if (!card.hidden) shown++;
    }
    count.textContent = network.value ? '1 exact token and network selected. Read its details and complete your checks below.' : `${shown} entries shown. ${token.value ? 'Choose the network offered by the sender.' : 'Choose a token to narrow the list.'}`;
    tool.classList.toggle('transfer-selected', !!network.value);
    review.hidden = !network.value;
    checks.forEach(check => {check.checked = false;});
    reviewUpdate();
  }
  function updateLocation() {
    const url = new URL(window.location.href);
    url.search = '';
    if (network.value) {
      url.searchParams.set('token', token.value);
      url.searchParams.set('network', network.value.split('/')[3]);
    }
    url.hash = 'prepare-transfer';
    window.history.replaceState(null, '', url.pathname + url.search + url.hash);
  }
  token.addEventListener('change', () => {network.value = ''; update(); updateLocation();});
  network.addEventListener('change', () => {update(); updateLocation();});
  tool.querySelector('[data-transfer-reset]').addEventListener('click', () => {token.value = ''; network.value = ''; update(); updateLocation(); token.focus();});
  checks.forEach(check => check.addEventListener('change', reviewUpdate));
  controls.hidden = false;
  update();
})();
