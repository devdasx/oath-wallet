document.querySelector('[data-print]')?.addEventListener('click', () => window.print());
document.addEventListener('keydown', event => {
  if (event.key === '/' && !document.querySelector('.oath-site-header')?.hasAttribute('data-menu-open') && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName || '')) {
    event.preventDefault(); document.querySelector('#help-search')?.focus();
  }
});
