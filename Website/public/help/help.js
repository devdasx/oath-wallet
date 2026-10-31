document.querySelector('[data-print]')?.addEventListener('click', () => window.print());
document.addEventListener('keydown', event => {
  const editing = document.activeElement?.matches('input, textarea, select, [contenteditable]:not([contenteditable="false"])');
  if (event.key === '/' && !event.ctrlKey && !event.metaKey && !event.altKey && !editing
    && !document.querySelector('.oath-site-header')?.hasAttribute('data-menu-open')) {
    event.preventDefault();
    document.querySelector('#help-search')?.focus();
  }
});
