/* Oath social post templates — one canvas renderer used for both previews and full-size PNG export. */
(function (root) {
  var FMT = {
    x:   { w: 1600, h: 900,  pw: 480, label: 'X · 1600×900' },
    ig:  { w: 1080, h: 1080, pw: 340, label: 'Instagram · 1080×1080' },
    igp: { w: 1080, h: 1350, pw: 300, label: 'Instagram / Facebook portrait · 1080×1350' },
    st:  { w: 1080, h: 1920, pw: 220, label: 'Story / Reels · 1080×1920' },
    fb:  { w: 1200, h: 630,  pw: 480, label: 'Facebook post · 1200×630' },
    og:  { w: 1200, h: 630,  pw: 480, label: 'Link preview (X, Facebook, LinkedIn) · 1200×630' },
    fbc: { w: 1640, h: 624,  pw: 640, label: 'Facebook cover · 1640×624' },
    xh:  { w: 1500, h: 500,  pw: 600, label: 'X header · 1500×500' }
  };
  var THEMES = {
    light: { name: 'Light', bg: '#F4F4F2', surface: '#FFFFFF', panel: '#E9E9E7', ink: '#0B0B0D', muted: '#5E5E64', line: 'rgba(11,11,13,.14)', gBase: '#F4F4F2', gA: 0.62, gInk: '#0B0B0D', mGlow: 'light', mFlat: 'light', pillBg: '#0B0B0D', pillFg: '#FFFFFF' },
    dark:  { name: 'Dark', bg: '#0B0B0D', surface: '#161619', panel: '#161619', ink: '#F4F4F2', muted: '#9A9AA0', line: 'rgba(255,255,255,.16)', gBase: '#0B0B0D', gA: 1, gInk: '#FFFFFF', mGlow: 'white', mFlat: 'dark', pillBg: '#FFFFFF', pillFg: '#0B0B0D' }
  };
  var DEFAULTS = {
    a_kicker: 'Now available', a_headline: 'Oath is live on iPhone.', a_body: 'A self-custody wallet where your keys never leave your device. Android coming soon.', a_cta: 'Download on the App Store',
    f_kicker: 'New in Oath', f_headline: 'Swap in one tap.', f_p1: 'Best available rate, found for you', f_p2: 'Every fee shown before you confirm', f_p3: 'Your keys never leave the phone',
    q_text: 'I finally feel like my money is actually mine.', q_author: '[Customer name]', q_role: '[City] · Oath user',
    t_num: '04', t_text: 'Never type your recovery phrase into a website. Oath will never ask for it.',
    r_cat: 'Security', r_read: '6 min read', r_title: 'What self-custody really means — and why it matters', r_author: '[Author name]', r_domain: 'oath.app', r_post: 'New on the blog: what self-custody really means, in plain words.', r_desc: 'Your keys, your coins — explained without the jargon.',
    c_title: 'How to back up your wallet', c_s1: 'Write your 12 words on paper, in order.', c_s2: 'Store it somewhere only you can reach.', c_s3: 'Never photograph it or save it online.', c_handle: '@oathwallet', c_end: 'for a security tip every week',
    v_tagline: 'Your keys. Your word.'
  };
  var TPLS = [
    { id: 'announce', num: '01', title: 'Announcement', desc: 'Launches, releases, milestones. Glow ground, one headline, one action.', boards: [['x'], ['ig'], ['st'], ['fb']], fields: [['a_kicker', 'Kicker'], ['a_headline', 'Headline'], ['a_body', 'Body'], ['a_cta', 'Button']] },
    { id: 'feature', num: '02', title: 'Feature', desc: 'One feature, three plain facts about it. Flat ground so the words lead.', boards: [['igp'], ['x']], fields: [['f_kicker', 'Kicker'], ['f_headline', 'Headline'], ['f_p1', 'Point 1'], ['f_p2', 'Point 2'], ['f_p3', 'Point 3']] },
    { id: 'quote', num: '03', title: 'Quote', desc: 'Customer words, press lines, founder notes.', boards: [['ig'], ['x']], fields: [['q_text', 'Quote'], ['q_author', 'Name'], ['q_role', 'Detail']] },
    { id: 'tip', num: '04', title: 'Security tip', desc: 'A numbered weekly series. The number is the hook.', boards: [['igp'], ['st']], fields: [['t_num', 'Number'], ['t_text', 'Tip']] },
    { id: 'article', num: '05', title: 'Article & link preview', desc: 'Blog and press posts. The 1200×630 image is what X, Facebook and LinkedIn show when the link is shared.', boards: [['og'], ['igp']], fields: [['r_cat', 'Category'], ['r_read', 'Read time'], ['r_title', 'Title'], ['r_author', 'Author'], ['r_post', 'Post text'], ['r_desc', 'Description'], ['r_domain', 'Domain']], feed: true },
    { id: 'carousel', num: '06', title: 'Carousel', desc: 'Three-slide how-to for Instagram and Facebook: cover, steps, follow.', boards: [['igp', 'c1'], ['igp', 'c2'], ['igp', 'c3']], fields: [['c_title', 'Title'], ['c_s1', 'Step 1'], ['c_s2', 'Step 2'], ['c_s3', 'Step 3'], ['c_handle', 'Handle'], ['c_end', 'Follow line']] },
    { id: 'cover', num: '07', title: 'Profile covers', desc: 'Facebook cover and X header. Keep words to the centre band — profile photos overlap the lower left.', boards: [['fbc'], ['xh']], fields: [['v_tagline', 'Tagline']] }
  ];

  var ACC = [[0, 0, '217,138,18'], [1, 0, '61,111,240'], [1, 1, '227,18,79'], [0, 1, '18,168,142']];
  function F(ctx, size, weight, mono) { ctx.font = (weight || 400) + ' ' + size + 'px ' + (mono ? '"Geist Mono", ui-monospace, monospace' : 'Geist, system-ui, sans-serif'); }
  function wrap(ctx, text, maxW) {
    var out = [];
    String(text || '').split('\n').forEach(function (par) {
      var line = '';
      par.split(/\s+/).filter(Boolean).forEach(function (w) { var t = line ? line + ' ' + w : w; if (line && ctx.measureText(t).width > maxW) { out.push(line); line = w; } else line = t; });
      out.push(line);
    });
    return out;
  }
  function T(g, s, o) {
    var ctx = g.ctx; F(ctx, o.size, o.weight, o.mono);
    var ls = 'letterSpacing' in ctx; if (ls) ctx.letterSpacing = ((o.ls || 0) * o.size) + 'px';
    var lines = wrap(ctx, s, o.maxW || 1e9), lh = o.size * (o.lh || 1.2);
    if (o.draw !== false) {
      ctx.fillStyle = o.color; ctx.textAlign = o.align || 'left'; ctx.textBaseline = 'middle';
      lines.forEach(function (l, i) { ctx.fillText(l, o.x, o.y + i * lh + lh / 2); });
    }
    if (ls) ctx.letterSpacing = '0px';
    return lines.length * lh;
  }
  function measure(g, s, size, weight, ls, mono) { var ctx = g.ctx; F(ctx, size, weight, mono); if ('letterSpacing' in ctx) ctx.letterSpacing = ((ls || 0) * size) + 'px'; var w = ctx.measureText(s).width; if ('letterSpacing' in ctx) ctx.letterSpacing = '0px'; return w; }
  function glow(g, x, y, w, h, base, a) {
    var ctx = g.ctx; ctx.fillStyle = base; ctx.fillRect(x, y, w, h);
    ACC.forEach(function (p) {
      ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
      ctx.translate(x + p[0] * w, y + p[1] * h); ctx.scale(w * 0.6, h * 0.6);
      var gr = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
      gr.addColorStop(0, 'rgba(' + p[2] + ',' + a + ')'); gr.addColorStop(0.7, 'rgba(' + p[2] + ',0)');
      ctx.fillStyle = gr; ctx.fillRect(-2, -2, 4, 4); ctx.restore();
    });
  }
  function flat(g, c) { g.ctx.fillStyle = c; g.ctx.fillRect(0, 0, g.W, g.H); }
  function mark(g, key, x, y, h) { var im = g.imgs && g.imgs[key]; if (im) g.ctx.drawImage(im, x, y, h * 860 / 580, h); return h * 860 / 580; }
  function lockupW(g, h) { return h * 860 / 580 + h * 0.38 + measure(g, 'Oath', h * 1.3, 600, -0.045); }
  function lockup(g, key, x, y, h, color) { var mw = mark(g, key, x, y, h), fs = h * 1.3; T(g, 'Oath', { x: x + mw + h * 0.38, y: y + h / 2 - fs * 0.6 + h * 0.04, size: fs, weight: 600, ls: -0.045, color: color }); }
  function pill(g, s, x, y, size, bg, fg) {
    var ctx = g.ctx, w = measure(g, s, size, 500) + size * 2.2, h = size * 2.4;
    ctx.fillStyle = bg; ctx.beginPath(); if (ctx.roundRect) ctx.roundRect(x, y, w, h, h / 2); else ctx.rect(x, y, w, h); ctx.fill();
    T(g, s, { x: x + w / 2, y: y + h / 2 - size * 0.6, size: size, weight: 500, color: fg, align: 'center' });
  }
  function rule(g, x, y, w) { g.ctx.fillStyle = g.t.line; g.ctx.fillRect(x, y, w, Math.max(1, 0.16 * g.u)); }
  function label(g, s, x, y, color, align) { T(g, String(s || '').toUpperCase(), { x: x, y: y, size: 2.4 * g.u, weight: 500, mono: true, ls: 0.08, color: color, align: align }); }

  var DRAW = {
    announce: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H;
      glow(g, 0, 0, W, H, t.gBase, t.gA);
      lockup(g, t.mGlow, P, P, 4.4 * u, t.gInk);
      label(g, c.a_kicker, W - P, P + 2.2 * u - 1.44 * u, t.gInk, 'right');
      var mw = g.wide ? W * 0.64 : W - 2 * P, ps = 2.7 * u, ph = ps * 2.4, py = H - P - ph;
      var bo = { size: 3.6 * u, lh: 1.35, maxW: g.wide ? W * 0.5 : mw, color: t.gInk };
      var bh = T(g, c.a_body, Object.assign({ draw: false }, bo)), by = py - 4.6 * u - bh;
      var ho = { size: (g.wide ? 10 : 11) * u, weight: 600, lh: 1, ls: -0.045, maxW: mw, color: t.gInk };
      var hh = T(g, c.a_headline, Object.assign({ draw: false }, ho));
      T(g, c.a_headline, Object.assign({ x: P, y: by - 2.8 * u - hh }, ho));
      T(g, c.a_body, Object.assign({ x: P, y: by }, bo));
      pill(g, c.a_cta, P, py, ps, t.pillBg, t.pillFg);
    },
    feature: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H;
      flat(g, t.bg);
      label(g, c.f_kicker, P, P + 2.1 * u - 1.44 * u, t.muted);
      mark(g, t.mFlat, W - P - 4.2 * u * 860 / 580, P, 4.2 * u);
      T(g, c.f_headline, { x: P, y: P + 11 * u, size: 9.5 * u, weight: 600, lh: 1.02, ls: -0.04, maxW: g.wide ? W * 0.58 : W - 2 * P, color: t.ink });
      label(g, c.r_domain || 'oath.app', P, H - P - 2.9 * u, t.muted);
      var rh = 10.5 * u, top = H - P - 6 * u - 3 * rh;
      [c.f_p1, c.f_p2, c.f_p3].forEach(function (p, i) {
        var y = top + i * rh; rule(g, P, y, W - 2 * P);
        T(g, '0' + (i + 1), { x: P, y: y + 3.2 * u, size: 2.6 * u, weight: 500, mono: true, color: t.muted });
        T(g, p, { x: P + 9 * u, y: y + 2.9 * u, size: 3.9 * u, weight: 500, lh: 1.2, ls: -0.01, maxW: W - 2 * P - 9 * u, color: t.ink });
      });
    },
    quote: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H;
      flat(g, t.surface);
      T(g, '\u201C', { x: P - 1.2 * u, y: P - 5 * u, size: 26 * u, weight: 600, lh: 1, color: '#3D6FF0' });
      T(g, c.q_text, { x: P, y: P + 17 * u, size: (g.wide ? 6.2 : 7) * u, weight: 500, lh: 1.14, ls: -0.025, maxW: g.wide ? W * 0.74 : W - 2 * P, color: t.ink });
      T(g, c.q_author, { x: P, y: H - P - 7.4 * u, size: 3.2 * u, weight: 600, color: t.ink });
      label(g, c.q_role, P, H - P - 3.1 * u, t.muted);
      mark(g, t.mFlat, W - P - 4.6 * u * 860 / 580, H - P - 4.6 * u, 4.6 * u);
    },
    tip: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H, ctx = g.ctx;
      flat(g, t.bg);
      label(g, 'Security tip', P, P + 2.1 * u - 1.44 * u, t.muted);
      ['#D98A12', '#3D6FF0', '#E3124F', '#12A88E'].forEach(function (col, i) { ctx.fillStyle = col; ctx.beginPath(); ctx.arc(W - P - 0.8 * u - i * 2.6 * u, P + 2.1 * u, 0.8 * u, 0, Math.PI * 2); ctx.fill(); });
      T(g, c.t_num, { x: P - 1.4 * u, y: P + 7 * u, size: 30 * u, weight: 500, mono: true, lh: 1, ls: -0.06, color: t.ink });
      T(g, c.t_text, { x: P, y: P + 42 * u, size: 6.2 * u, weight: 500, lh: 1.16, ls: -0.02, maxW: W - 2 * P, color: t.ink });
      lockup(g, t.mFlat, P, H - P - 3.6 * u, 3.6 * u, t.ink);
      label(g, 'Save for later', W - P, H - P - 1.8 * u - 1.44 * u, t.muted, 'right');
    },
    article: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H, ctx = g.ctx;
      flat(g, t.bg);
      var px, py, pw, ph, meta = (c.r_cat + ' · ' + c.r_read);
      if (g.wide) { px = W * 0.56; py = P; pw = W - P - px; ph = H - 2 * P; }
      else { px = P; py = P; pw = W - 2 * P; ph = H * 0.44; }
      ctx.save(); ctx.beginPath(); if (ctx.roundRect) ctx.roundRect(px, py, pw, ph, 3 * u); else ctx.rect(px, py, pw, ph); ctx.clip();
      glow(g, px, py, pw, ph, t.panel, t.gA);
      var mh = Math.min(ph * 0.3, pw * 0.3 * 580 / 860); mark(g, t.mGlow, px + pw / 2 - mh * 430 / 580, py + ph / 2 - mh / 2, mh);
      ctx.restore();
      if (g.wide) {
        lockup(g, t.mFlat, P, P, 3.8 * u, t.ink);
        label(g, meta, P, P + 13 * u, t.muted);
        T(g, c.r_title, { x: P, y: P + 19 * u, size: 7.4 * u, weight: 600, lh: 1.05, ls: -0.035, maxW: px - P - 5 * u, color: t.ink });
        label(g, 'By ' + c.r_author, P, H - P - 2.9 * u, t.muted);
      } else {
        label(g, meta, P, py + ph + 6 * u, t.muted);
        T(g, c.r_title, { x: P, y: py + ph + 12 * u, size: 7.6 * u, weight: 600, lh: 1.05, ls: -0.035, maxW: W - 2 * P, color: t.ink });
        label(g, 'By ' + c.r_author, P, H - P - 2.9 * u, t.muted);
        mark(g, t.mFlat, W - P - 3.8 * u * 860 / 580, H - P - 3.8 * u, 3.8 * u);
      }
    },
    carousel: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H, ctx = g.ctx, v = g.v;
      var n = v === 'c1' ? '1 / 3' : v === 'c2' ? '2 / 3' : '3 / 3';
      if (v === 'c1') {
        glow(g, 0, 0, W, H, t.gBase, t.gA);
        lockup(g, t.mGlow, P, P, 4.4 * u, t.gInk);
        label(g, n, W - P, P + 2.2 * u - 1.44 * u, t.gInk, 'right');
        var ho = { size: 11 * u, weight: 600, lh: 1, ls: -0.045, maxW: W - 2 * P, color: t.gInk };
        var hh = T(g, c.c_title, Object.assign({ draw: false }, ho));
        T(g, c.c_title, Object.assign({ x: P, y: H - P - 9 * u - hh }, ho));
        label(g, 'Swipe \u2192', P, H - P - 2.9 * u, t.gInk);
      } else if (v === 'c2') {
        flat(g, t.bg);
        T(g, String(c.c_title || '').toUpperCase(), { x: P, y: P + 0.66 * u, size: 2.4 * u, weight: 500, mono: true, ls: 0.08, maxW: W - 2 * P - 14 * u, color: t.muted });
        label(g, n, W - P, P + 0.66 * u, t.muted, 'right');
        var y = P + 14 * u, acc = ['#D98A12', '#3D6FF0', '#E3124F'];
        [c.c_s1, c.c_s2, c.c_s3].forEach(function (s, i) {
          rule(g, P, y, W - 2 * P);
          ctx.fillStyle = acc[i]; ctx.beginPath(); ctx.arc(P + 1 * u, y + 4.4 * u, 1 * u, 0, Math.PI * 2); ctx.fill();
          label(g, 'Step 0' + (i + 1), P + 3.6 * u, y + 2.96 * u, t.muted);
          var h = T(g, s, { x: P, y: y + 8.4 * u, size: 5.6 * u, weight: 500, lh: 1.14, ls: -0.02, maxW: W - 2 * P, color: t.ink });
          y += 8.4 * u + h + 6 * u;
        });
        mark(g, t.mFlat, W - P - 3.8 * u * 860 / 580, H - P - 3.8 * u, 3.8 * u);
      } else {
        glow(g, 0, 0, W, H, t.gBase, t.gA);
        label(g, n, W - P, P + 0.66 * u, t.gInk, 'right');
        var mh = 15 * u; mark(g, t.mGlow, W / 2 - mh * 430 / 580, H / 2 - 20 * u, mh);
        T(g, 'Follow ' + c.c_handle, { x: W / 2, y: H / 2 + 2 * u, size: 5.6 * u, weight: 600, ls: -0.03, align: 'center', maxW: W - 2 * P, color: t.gInk });
        T(g, c.c_end, { x: W / 2, y: H / 2 + 10.5 * u, size: 2.8 * u, mono: true, align: 'center', maxW: W - 2 * P, color: t.gInk });
      }
    },
    cover: function (g) {
      var t = g.t, c = g.c, u = g.u, P = g.P, W = g.W, H = g.H;
      glow(g, 0, 0, W, H, t.gBase, t.gA);
      var ho = { size: 12 * u, weight: 600, lh: 1, ls: -0.045, maxW: W * 0.5, color: t.gInk };
      var hh = T(g, c.v_tagline, Object.assign({ draw: false }, ho));
      T(g, c.v_tagline, Object.assign({ x: W * 0.08, y: H / 2 - hh / 2 - 4 * u }, ho));
      var lh = 9 * u; lockup(g, t.mGlow, W - W * 0.08 - lockupW(g, lh), H / 2 - lh / 2 - 4 * u, lh, t.gInk);
    }
  };

  function render(tpl, fmt, variant, theme, scale, c, imgs) {
    var f = FMT[fmt], cv = document.createElement('canvas');
    cv.width = Math.round(f.w * scale); cv.height = Math.round(f.h * scale);
    var ctx = cv.getContext('2d'); ctx.scale(scale, scale);
    var u = Math.min(f.w, f.h) / 100;
    DRAW[tpl]({ ctx: ctx, W: f.w, H: f.h, u: u, P: 7 * u, t: THEMES[theme], c: c, imgs: imgs, wide: f.w / f.h > 1.3, v: variant });
    return cv;
  }

  root.OathSocial = { FMT: FMT, THEMES: THEMES, DEFAULTS: DEFAULTS, TPLS: TPLS, render: render };
})(window);
