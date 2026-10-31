// Filtering never removes the server-rendered links from the initial document.
const search = document.querySelector('[data-network-search]');
if (search) search.addEventListener('input', () => {
  const query = search.value.trim().toLocaleLowerCase();
  let visible = 0;
  for (const card of document.querySelectorAll('[data-network-keywords]')) {
    card.hidden = !card.dataset.networkKeywords.toLocaleLowerCase().includes(query);
    if (!card.hidden) visible++;
  }
  document.querySelector('[data-network-count]').textContent = `${visible} networks`;
  document.querySelector('[data-network-empty]').hidden = visible !== 0;
});
