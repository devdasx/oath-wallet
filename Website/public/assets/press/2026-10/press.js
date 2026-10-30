(() => {
  const notice = document.getElementById('copy-status');
  let noticeTimeout;
  document.querySelectorAll('[data-copy-target], [data-copy-value]').forEach(button => {
    button.addEventListener('click', async () => {
      const text = button.dataset.copyValue || document.getElementById(button.dataset.copyTarget)?.textContent;
      if (!text) return;
      let message;
      try {
        await navigator.clipboard.writeText(text.trim());
        message = button.dataset.copyValue ? `${text} copied` : 'Press copy copied';
      } catch {
        // Clipboard access can be denied by browser settings. Keep the text selectable.
        message = 'Copy unavailable. Select the text to copy it manually.';
      }
      clearTimeout(noticeTimeout);
      notice.textContent = message;
      notice.classList.add('is-visible');
      noticeTimeout = setTimeout(() => notice.classList.remove('is-visible'), 4000);
    });
  });
})();
