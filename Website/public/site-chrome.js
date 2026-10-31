(()=>{
// Search and article content are server-rendered. Enhance the shared website
// menu without loading a client-side template compiler into the Help Center.
const siteHeader = document.querySelector('.oath-site-header');
const menu = document.querySelector('#oath-site-menu');
const toggle = siteHeader?.querySelector('[data-oath-toggle]');
const compact = window.matchMedia('(max-width: 1023px)');
// Mark the current section without creating page-specific component copies.
const current = new URL(window.location.href);
const section = current.hostname === 'help.oathwallet.org' ? 'https://help.oathwallet.org/'
  : current.hostname === 'articles.oathwallet.org' ? 'https://articles.oathwallet.org/'
  : current.pathname.startsWith('/networks') ? 'https://oathwallet.org/networks'
  : current.pathname === '/' ? 'https://oathwallet.org/'
  : 'https://oathwallet.org' + current.pathname.replace(/\/$/, '');
siteHeader?.querySelectorAll('nav a').forEach(link => {
 if(link.getAttribute('href') === section)link.setAttribute('aria-current','page');
});
let savedOverflow = '';
let inertElements = [];

function setMenu(open, restoreFocus = true) {
  if (!siteHeader || !menu || !toggle || open === siteHeader.hasAttribute('data-menu-open')) return;
  siteHeader.toggleAttribute('data-menu-open', open);
  menu.inert = !open;
  menu.setAttribute('aria-hidden', String(!open));
  toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  if (open) {
    // Include the fixed bar and its close button in the modal's accessible tree.
    siteHeader.setAttribute('role', 'dialog');
    siteHeader.setAttribute('aria-modal', 'true');
    siteHeader.setAttribute('aria-label', 'Navigation');
    savedOverflow = document.documentElement.style.overflow;
    document.documentElement.style.overflow = 'hidden';
    inertElements = [...document.querySelectorAll('body > main, body > .support, body > .oath-site-footer, #oath-server-content > main, #oath-server-content > .oath-site-footer')]
      .map(element => ({element, wasInert: element.inert}));
    inertElements.forEach(({element}) => { element.inert = true; });
    menu.querySelector('a')?.focus({preventScroll: true});
  } else {
    siteHeader.removeAttribute('role');
    siteHeader.removeAttribute('aria-modal');
    siteHeader.removeAttribute('aria-label');
    document.documentElement.style.overflow = savedOverflow;
    inertElements.forEach(({element, wasInert}) => { element.inert = wasInert; });
    inertElements = [];
    if (restoreFocus) toggle.focus({preventScroll: true});
  }
}
toggle?.addEventListener('click', () => setMenu(!siteHeader.hasAttribute('data-menu-open')));
siteHeader?.querySelectorAll('[data-oath-close]').forEach(link => {
  link.addEventListener('click', () => setMenu(false, false));
});
compact.addEventListener('change', event => {
  if (!event.matches) setMenu(false, false);
});
window.addEventListener('pagehide', () => setMenu(false, false));
document.addEventListener('keydown', event => {
  if (!siteHeader?.hasAttribute('data-menu-open')) return;
  if (event.key === 'Escape') {
    event.preventDefault(); setMenu(false);
  } else if (event.key === 'Tab') {
    const links = [...siteHeader.querySelectorAll('a[href], button')]
      .filter(element => !element.closest('[inert]') && element.getClientRects().length);
    const index = links.indexOf(document.activeElement);
    if ((event.shiftKey && index <= 0) || (!event.shiftKey && index === links.length - 1)) {
      event.preventDefault(); links[event.shiftKey ? links.length-1 : 0]?.focus();
    }
  }
});

})();
