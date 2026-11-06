// Keep the initials readable if the first-party image request itself fails.
// Provider outages are normally handled by the image route's cached fallback.
(() => {
  const failed = image => {if (image.matches?.('.token-artwork > img')) image.hidden = true;};
  document.addEventListener('error', event => failed(event.target), true);
  document.querySelectorAll('.token-artwork > img').forEach(image => {
    if (image.complete && !image.naturalWidth) failed(image);
  });
})();
