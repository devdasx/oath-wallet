/* Oath app icon generator — builds each mark as an SVG string (1024 grid). Used by "Oath App Icon.dc.html". */
(function (root) {
  var PALETTES = {
    Prism:  { A: '#D98A12', B: '#3D6FF0', C: '#E3124F', D: '#12A88E' },
    Aurora: { A: '#8B5CF6', B: '#22C3E6', C: '#F0459A', D: '#43D17A' },
    Gold:   { A: '#E0A526', B: '#F5D27A', C: '#C2531F', D: '#9C7A2A' }
  };
  function n(v) { return Math.round(v * 100) / 100; }
  function rgb(h) { h = h.replace('#', ''); return [0, 2, 4].map(function (i) { return parseInt(h.slice(i, i + 2), 16); }); }
  function hex(a) { return '#' + a.map(function (v) { v = Math.round(Math.max(0, Math.min(255, v))); return (v < 16 ? '0' : '') + v.toString(16); }).join(''); }
  function mix(a, b, t) { var x = rgb(a), y = rgb(b); return hex(x.map(function (v, i) { return v + (y[i] - v) * t; })); }
  function ring(cx, cy, r, w, color, clip) {
    return '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="' + color + '" stroke-width="' + w + '"' + (clip ? ' clip-path="url(#' + clip + ')"' : '') + '/>';
  }

  var CONCEPTS = {
    vault: {
      bbox: [162, 162, 700, 700],
      glows: [
        { x: 118, y: 118, r: 370, k: 'A' },
        { x: 906, y: 118, r: 370, k: 'B', k2: 'B' },
        { x: 906, y: 906, r: 370, k: 'C' },
        { x: 118, y: 906, r: 350, k: 'D', k2: 'A' }
      ],
      masks: ['<rect x="162" y="162" width="700" height="700" rx="120" fill="#fff"/><circle cx="512" cy="512" r="352" fill="#000"/>'],
      inner: {
        grad: [412, 346, 612, 672],
        body: '<circle cx="512" cy="446" r="100"/><path d="M464 466 L435.1 652.2 Q432 672 452 672 L572 672 Q592 672 588.9 652.2 L560 466 Z"/>'
      }
    },
    vow: {
      bbox: [82, 222, 860, 580],
      glows: [
        { x: 40, y: 500, r: 380, k: 'A', k2: 'A' },
        { x: 250, y: 870, r: 330, k: 'D' },
        { x: 800, y: 160, r: 360, k: 'B', k2: 'B' },
        { x: 940, y: 760, r: 340, k: 'C' }
      ],
      defs: '<clipPath id="ct"><rect width="1024" height="512"/></clipPath><clipPath id="cb"><rect y="512" width="1024" height="512"/></clipPath>',
      masks: [
        ring(372, 512, 230, 120, '#fff') + ring(652, 512, 230, 164, '#000', 'cb'),
        ring(652, 512, 230, 120, '#fff') + ring(372, 512, 230, 164, '#000', 'ct')
      ]
    },
    pact: {
      bbox: [119, 177, 786, 670],
      glows: [
        { x: 90, y: 350, r: 370, k: 'A', k2: 'A' },
        { x: 760, y: 140, r: 340, k: 'B' },
        { x: 270, y: 910, r: 330, k: 'D' },
        { x: 950, y: 650, r: 370, k: 'C', k2: 'B' }
      ],
      defs: '<clipPath id="ct"><rect width="1024" height="494"/></clipPath><clipPath id="cb"><rect y="530" width="1024" height="494"/></clipPath>',
      masks: [ring(454, 512, 250, 170, '#fff', 'ct') + ring(570, 512, 250, 170, '#fff', 'cb')]
    }
  };

  function corners(b) {
    var x0 = b[0] - 44, y0 = b[1] - 44, x1 = b[0] + b[2] + 44, y1 = b[1] + b[3] + 44, r = Math.round(Math.max(b[2], b[3]) * 0.53);
    return [
      { x: x0, y: y0, r: r, k: 'A' },
      { x: x1, y: y0, r: r, k: 'B', k2: 'B' },
      { x: x1, y: y1, r: r, k: 'C' },
      { x: x0, y: y1, r: r * 0.95, k: 'D', k2: 'A' }
    ];
  }
  var W = '#fff', K = '#000';
  var more = {
    coin: {
      bbox: [172, 172, 680, 680],
      masks: ['<circle cx="512" cy="512" r="340" fill="' + W + '"/><rect x="392" y="392" width="240" height="240" rx="44" fill="' + K + '"/>']
    },
    shield: {
      bbox: [182, 200, 660, 680],
      masks: ['<path d="M212 200 H812 Q842 200 842 230 V470 C842 690 690 820 512 880 C334 820 182 690 182 470 V230 Q182 200 212 200 Z" fill="' + W + '"/><circle cx="512" cy="470" r="190" fill="' + K + '"/>'],
      inner: { grad: [482, 395, 542, 545], body: '<rect x="482" y="395" width="60" height="150" rx="30"/>' }
    },
    ledger: {
      bbox: [172, 172, 680, 680],
      masks: ['<circle cx="512" cy="512" r="340" fill="' + W + '"/><rect y="404" width="1024" height="28" fill="' + K + '"/><rect y="592" width="1024" height="28" fill="' + K + '"/>']
    },
    key: {
      bbox: [115, 287, 795, 450],
      masks: [ring(340, 512, 170, 110, W) + '<rect x="560" y="472" width="350" height="80" rx="6" fill="' + W + '"/><rect x="770" y="540" width="44" height="80" rx="6" fill="' + W + '"/><rect x="850" y="540" width="60" height="80" rx="6" fill="' + W + '"/>']
    },
    orbit: {
      bbox: [197, 197, 630, 630],
      masks: [ring(512, 512, 240, 150, W) + '<circle cx="682" cy="342" r="115" fill="' + K + '"/>'],
      inner: { grad: [610, 270, 754, 414], body: '<circle cx="682" cy="342" r="72"/>' }
    },
    lock: {
      bbox: [262, 200, 500, 625],
      defs: '<clipPath id="ct"><rect width="1024" height="460"/></clipPath>',
      masks: [ring(512, 415, 170, 90, W, 'ct') + '<rect x="262" y="445" width="500" height="380" rx="90" fill="' + W + '"/><circle cx="512" cy="610" r="58" fill="' + K + '"/><rect x="490" y="610" width="44" height="110" rx="22" fill="' + K + '"/>']
    }
  };
  more.prism = {
    bbox: [152, 152, 720, 720],
    masks: ['<path d="M484 180 Q512 152 540 180 L844 484 Q872 512 844 540 L540 844 Q512 872 484 844 L180 540 Q152 512 180 484 Z" fill="' + W + '"/><circle cx="512" cy="512" r="150" fill="' + K + '"/>']
  };
  more.eclipse = {
    bbox: [150, 192, 640, 640],
    masks: ['<circle cx="470" cy="512" r="320" fill="' + W + '"/><circle cx="610" cy="430" r="240" fill="' + K + '"/>'],
    inner: { grad: [560, 380, 660, 480], body: '<circle cx="610" cy="430" r="60"/>' }
  };
  more.hex = {
    bbox: [200, 152, 624, 720],
    masks: ['<path d="M512 152 L824 332 L824 692 L512 872 L200 692 L200 332 Z" fill="' + W + '" stroke="' + W + '" stroke-width="40" stroke-linejoin="round"/><path d="M512 362 L642 437 L642 587 L512 662 L382 587 L382 437 Z" fill="' + K + '"/>']
  };
  more.quad = {
    bbox: [177, 177, 670, 670],
    masks: [ring(512, 512, 250, 170, W) + '<rect x="490" width="44" height="1024" fill="' + K + '"/><rect y="490" width="1024" height="44" fill="' + K + '"/>'],
    inner: { grad: [462, 462, 562, 562], body: '<circle cx="512" cy="512" r="50"/>' }
  };
  more.arch = {
    bbox: [212, 212, 600, 660],
    masks: ['<path d="M212 872 V512 A300 300 0 0 1 812 512 V872 Z" fill="' + W + '"/><circle cx="512" cy="530" r="150" fill="' + K + '"/><rect x="362" y="530" width="300" height="400" fill="' + K + '"/>']
  };
  more.delta = {
    bbox: [154, 160, 716, 670],
    masks: ['<path d="M512 160 L870 830 L154 830 Z" fill="' + W + '" stroke="' + W + '" stroke-width="50" stroke-linejoin="round"/><circle cx="512" cy="620" r="125" fill="' + K + '"/>']
  };
  Object.keys(more).forEach(function (id) { more[id].glows = corners(more[id].bbox); CONCEPTS[id] = more[id]; });

  // --- Turn 4: 10 outer forms × 10 cut-outs = 100 marks ---
  function f(v) { return Math.round(v); }
  var OUTERS = [
    { key: 'circle', name: 'Circle', bbox: [172, 172, 680, 680], cy: 512, s: 130, d: '<circle cx="512" cy="512" r="340"/>' },
    { key: 'squircle', name: 'Tile', bbox: [184, 184, 656, 656], cy: 512, s: 130, d: '<rect x="184" y="184" width="656" height="656" rx="170"/>' },
    { key: 'diamond', name: 'Diamond', bbox: [152, 152, 720, 720], cy: 512, s: 112, d: '<path d="M484 180 Q512 152 540 180 L844 484 Q872 512 844 540 L540 844 Q512 872 484 844 L180 540 Q152 512 180 484 Z"/>' },
    { key: 'hexa', name: 'Hexagon', bbox: [190, 142, 644, 740], cy: 512, s: 122, d: '<path d="M512 152 L824 332 L824 692 L512 872 L200 692 L200 332 Z" stroke="#fff" stroke-width="30" stroke-linejoin="round"/>' },
    { key: 'octa', name: 'Octagon', bbox: [162, 162, 700, 700], cy: 512, s: 128, d: (function () { var p = []; for (var i = 0; i < 8; i++) { var a = Math.PI / 8 + i * Math.PI / 4; p.push(f(512 + 370 * Math.cos(a)) + ' ' + f(512 + 370 * Math.sin(a))); } return '<path d="M' + p.join(' L') + ' Z" stroke="#fff" stroke-width="30" stroke-linejoin="round"/>'; })() },
    { key: 'archx', name: 'Arch', bbox: [212, 212, 600, 660], cy: 560, s: 118, d: '<path d="M212 872 V512 A300 300 0 0 1 812 512 V872 Z"/>' },
    { key: 'shieldx', name: 'Shield', bbox: [182, 200, 660, 680], cy: 480, s: 118, d: '<path d="M212 200 H812 Q842 200 842 230 V470 C842 690 690 820 512 880 C334 820 182 690 182 470 V230 Q182 200 212 200 Z"/>' },
    { key: 'tri', name: 'Triangle', bbox: [129, 135, 766, 720], cy: 640, s: 92, d: '<path d="M512 160 L870 830 L154 830 Z" stroke="#fff" stroke-width="50" stroke-linejoin="round"/>' },
    { key: 'leaf', name: 'Leaf', bbox: [172, 172, 680, 680], cy: 512, s: 130, d: '<path d="M512 172 H852 V512 A340 340 0 0 1 512 852 H172 V512 A340 340 0 0 1 512 172 Z"/>' },
    { key: 'pill', name: 'Pill', bbox: [132, 312, 760, 400], cy: 512, s: 108, d: '<rect x="132" y="312" width="760" height="400" rx="200"/>' }
  ];
  var CUTS = [
    { key: 'dot', name: 'Dot', d: function (y, s) { return '<circle cx="512" cy="' + y + '" r="' + s + '" fill="#000"/>'; } },
    { key: 'square', name: 'Square', d: function (y, s) { var a = s * 1.7; return '<rect x="' + f(512 - a / 2) + '" y="' + f(y - a / 2) + '" width="' + f(a) + '" height="' + f(a) + '" rx="' + f(s * .32) + '" fill="#000"/>'; } },
    { key: 'keyhole', name: 'Keyhole', d: function (y, s) { var t = y - s * .35; return '<circle cx="512" cy="' + f(t) + '" r="' + f(s * .62) + '" fill="#000"/><path d="M' + f(512 - s * .26) + ' ' + f(t) + ' L' + f(512 - s * .44) + ' ' + f(y + s * 1.05) + ' H' + f(512 + s * .44) + ' L' + f(512 + s * .26) + ' ' + f(t) + ' Z" fill="#000"/>'; } },
    { key: 'ring', name: 'Ring', d: function (y, s) { return '<circle cx="512" cy="' + y + '" r="' + f(s * 1.12) + '" fill="#000"/><circle cx="512" cy="' + y + '" r="' + f(s * .55) + '" fill="#fff"/>'; } },
    { key: 'slits', name: 'Ledger', d: function (y, s) { var w = s * 6, h = s * .26; return [-.5, .5].map(function (k) { return '<rect x="' + f(512 - w / 2) + '" y="' + f(y + k * s * 1.1 - h / 2) + '" width="' + f(w) + '" height="' + f(h) + '" fill="#000"/>'; }).join(''); } },
    { key: 'cross', name: 'Cross', d: function (y, s) { var l = s * 2.6, t = s * .38; return '<rect x="' + f(512 - l / 2) + '" y="' + f(y - t / 2) + '" width="' + f(l) + '" height="' + f(t) + '" rx="' + f(t / 2) + '" fill="#000"/><rect x="' + f(512 - t / 2) + '" y="' + f(y - l / 2) + '" width="' + f(t) + '" height="' + f(l) + '" rx="' + f(t / 2) + '" fill="#000"/>'; } },
    { key: 'slot', name: 'Slot', d: function (y, s) { var w = s * .52, h = s * 2.1; return '<rect x="' + f(512 - w / 2) + '" y="' + f(y - h / 2) + '" width="' + f(w) + '" height="' + f(h) + '" rx="' + f(w / 2) + '" fill="#000"/>'; } },
    { key: 'gem', name: 'Gem', d: function (y, s) { var r = s * 1.2; return '<path d="M512 ' + f(y - r) + ' L' + f(512 + r) + ' ' + y + ' L512 ' + f(y + r) + ' L' + f(512 - r) + ' ' + y + ' Z" fill="#000"/>'; } },
    { key: 'peak', name: 'Peak', d: function (y, s) { var r = s * 1.15; return '<path d="M512 ' + f(y - r) + ' L' + f(512 + r) + ' ' + f(y + r * .75) + ' H' + f(512 - r) + ' Z" fill="#000"/>'; } },
    { key: 'moon', name: 'Moon', d: function (y, s) { return '<circle cx="512" cy="' + y + '" r="' + f(s * 1.05) + '" fill="#000"/><circle cx="' + f(512 + s * .5) + '" cy="' + f(y - s * .3) + '" r="' + f(s * .85) + '" fill="#fff"/>'; } }
  ];
  var GRID = [];
  OUTERS.forEach(function (o, i) {
    var row = { name: o.name, items: [] };
    CUTS.forEach(function (c, j) {
      var id = o.key + '_' + c.key, gl = corners(o.bbox), sh = (i + j) % 4, keys = ['A', 'B', 'C', 'D'];
      gl.forEach(function (g) { g.k = keys[(keys.indexOf(g.k) + sh) % 4]; if (g.k2) g.k2 = keys[(keys.indexOf(g.k2) + sh) % 4]; });
      CONCEPTS[id] = { bbox: o.bbox, glows: gl, masks: ['<g fill="#fff">' + o.d + '</g>' + c.d(o.cy, o.s)] };
      row.items.push({ id: id, n: i * 10 + j + 1, name: o.name + ' · ' + c.name });
    });
    GRID.push(row);
  });

  // --- Turn 5: 30 one-off marks, each its own geometry ---
  var S = function (w) { return ' fill="none" stroke="#fff" stroke-width="' + w + '" stroke-linecap="round" stroke-linejoin="round"'; };
  var SB = function (w) { return ' fill="none" stroke="#000" stroke-width="' + w + '" stroke-linecap="round" stroke-linejoin="round"'; };
  var pix = (function () { var o = ''; for (var r = 0; r < 5; r++) for (var c = 0; c < 5; c++) { var edge = (r === 0 || r === 4) ? (c > 0 && c < 4) : (c === 0 || c === 4); if (edge || (r === 2 && c === 2)) o += '<rect x="' + (189 + c * 134) + '" y="' + (189 + r * 134) + '" width="110" height="110" rx="20"/>'; } return o; })();
  var seal = (function () { var o = ''; for (var i = 0; i < 16; i++) { var a = i * Math.PI / 8; o += '<circle cx="' + f(512 + 330 * Math.cos(a)) + '" cy="' + f(512 + 330 * Math.sin(a)) + '" r="36" fill="#000"/>'; } return o; })();
  var petals = (function () { var o = ''; for (var i = 0; i < 8; i++) o += '<rect x="447" y="172" width="130" height="300" rx="65" transform="rotate(' + i * 45 + ' 512 512)"/>'; return o; })();
  var net = (function () { var o = '', d = ''; for (var i = 0; i < 6; i++) { var a = -Math.PI / 2 + i * Math.PI / 3, x = f(512 + 290 * Math.cos(a)), y = f(512 + 290 * Math.sin(a)); o += '<circle cx="' + x + '" cy="' + y + '" r="72"/>'; d += 'M512 512 L' + x + ' ' + y + ' '; } return '<path d="' + d + '"' + S(40) + '/>' + o + '<circle cx="512" cy="512" r="104"/>'; })();
  var ticks = (function () { var o = ''; for (var i = 0; i < 12; i++) o += '<rect x="504" y="186" width="16" height="56" rx="8" fill="#000" transform="rotate(' + i * 30 + ' 512 512)"/>'; return o; })();
  var hexP = 'M512 152 L824 332 L824 692 L512 872 L200 692 L200 332 Z';
  var UNIQUE = [
    ['stack', 'Stack', 'Coins piling up — savings you can see.', [172, 252, 680, 520], '<rect x="252" y="252" width="520" height="140" rx="70"/><rect x="212" y="442" width="600" height="140" rx="70"/><rect x="172" y="632" width="680" height="140" rx="70"/>'],
    ['null', 'Null', 'An O struck through — zero fees, zero trust needed.', [150, 150, 724, 724], ring(512, 512, 250, 150, '#fff') + '<rect x="467" y="130" width="90" height="764" rx="45" transform="rotate(38 512 512)"/>'],
    ['nest', 'Nest', 'A key held inside a vault inside a vault.', [182, 182, 660, 660], '<rect x="182" y="182" width="660" height="660" rx="70"/><rect x="282" y="282" width="460" height="460" rx="36" fill="#000"/><rect x="382" y="382" width="260" height="260" rx="30" transform="rotate(45 512 512)"/>'],
    ['pixel', 'Pixel', 'The O rebuilt from blocks, a coin at its core.', [189, 189, 646, 646], pix],
    ['wave', 'Tide', 'Money that flows, cut through a solid coin.', [172, 172, 680, 680], '<circle cx="512" cy="512" r="340"/><path d="M130 540 C 270 380 390 380 512 512 S 754 644 894 484"' + SB(76) + '/>'],
    ['seal', 'Seal', 'A wax stamp — the mark you put on a promise.', [146, 146, 732, 732], '<circle cx="512" cy="512" r="340"/>' + seal + '<circle cx="512" cy="512" r="130" fill="#000"/>'],
    ['fold', 'Contract', 'A signed page with its corner turned — terms kept.', [192, 192, 640, 640], '<path d="M232 192 H612 L832 412 V792 Q832 832 792 832 H232 Q192 832 192 792 V232 Q192 192 232 192 Z"/><path d="M652 192 L832 372 H672 Q652 372 652 352 Z"/><rect x="292" y="532" width="300" height="52" rx="26" fill="#000"/><rect x="292" y="652" width="440" height="52" rx="26" fill="#000"/>'],
    ['stairs', 'Climb', 'Three steps up — a portfolio that grows.', [172, 212, 680, 640], '<path d="M212 852 Q172 852 172 812 V672 Q172 632 212 632 H392 V472 Q392 432 432 432 H612 V252 Q612 212 652 212 H812 Q852 212 852 252 V812 Q852 852 812 852 Z"/>'],
    ['chev', 'Ascend', 'Double chevron — send it up, fast.', [207, 275, 610, 560], '<path d="M262 520 L512 300 L762 520"' + S(120) + '/><path d="M262 780 L512 560 L762 780"' + S(120) + '/>'],
    ['swap', 'Swap', 'Two directions, one motion — trade in a tap.', [182, 220, 660, 584], '<path d="M252 390 H752 M632 270 L752 390 L632 510"' + S(100) + '/><path d="M772 634 H272 M392 514 L272 634 L392 754"' + S(100) + '/>'],
    ['hour', 'Hourglass', 'Time-locked value — staking made visible.', [212, 162, 600, 700], '<path d="M242 182 H782 L552 512 L782 842 H242 L472 512 Z"' + ' stroke="#fff" stroke-width="40" stroke-linejoin="round"/><path d="M412 842 L512 712 L612 842 Z" fill="#000"/>'],
    ['bridge', 'Bridge', 'Arches between chains — move assets across.', [172, 302, 680, 420], '<rect x="172" y="302" width="680" height="420" rx="44"/><circle cx="347" cy="722" r="125" fill="#000"/><circle cx="677" cy="722" r="125" fill="#000"/><rect x="172" y="392" width="680" height="34" fill="#000"/>'],
    ['inf', 'Forever', 'An endless loop — a vow with no expiry.', [142, 330, 740, 364], '<path d="M512 512 C 420 370 202 370 202 512 C 202 654 420 654 512 512 C 604 370 822 370 822 512 C 822 654 604 654 512 512 Z"' + S(124) + '/>'],
    ['crown', 'Crown', 'Sovereign money — you rule your own keys.', [162, 242, 700, 570], '<path d="M192 792 V362 L352 532 L512 272 L672 532 L832 362 V792 Z" stroke="#fff" stroke-width="40" stroke-linejoin="round"/><rect x="152" y="662" width="720" height="44" fill="#000"/>'],
    ['target', 'Target', 'Rings closing on a point — precise, on goal.', [152, 152, 720, 720], ring(512, 512, 305, 110, '#fff') + ring(512, 512, 160, 90, '#fff') + '<circle cx="512" cy="512" r="46"/>'],
    ['pie', 'Portfolio', 'A coin split into shares, one slice pulled out.', [192, 152, 680, 680], '<path d="M512 512 V192 A320 320 0 1 0 832 512 Z"/><path d="M552 472 V152 A320 320 0 0 1 872 472 Z"/>'],
    ['finger', 'Print', 'A fingerprint — only you can open it.', [150, 150, 724, 724], '<path d="M213 651 A330 330 0 1 1 811 651"' + S(56) + '/><path d="M262 512 A250 250 0 1 1 703 673"' + S(56) + '/><path d="M382 621 A170 170 0 1 1 682 512"' + S(56) + '/><path d="M427 481 A90 90 0 1 1 581 570"' + S(56) + '/>'],
    ['scan', 'Scan', 'Corner marks framing a coin — scan to pay.', [167, 167, 690, 690], '<path d="M212 392 V272 Q212 212 272 212 H392 M632 212 H752 Q812 212 812 272 V392 M812 632 V752 Q812 812 752 812 H632 M392 812 H272 Q212 812 212 752 V632"' + S(90) + '/><rect x="402" y="402" width="220" height="220" rx="50"/>'],
    ['cube', 'Block', 'One block, three faces — the chain’s unit.', [190, 142, 644, 740], '<path d="' + hexP + '" stroke="#fff" stroke-width="30" stroke-linejoin="round"/><path d="M512 512 V890 M512 512 L180 320 M512 512 L844 320"' + SB(34) + '/>'],
    ['wallet', 'Pocket', 'A wallet with its clasp shut.', [172, 252, 680, 520], '<rect x="172" y="252" width="680" height="520" rx="90"/><rect x="172" y="340" width="680" height="32" fill="#000"/><rect x="572" y="432" width="330" height="180" rx="90" fill="#000"/><circle cx="672" cy="522" r="46"/>'],
    ['cards', 'Cards', 'Three cards fanned — every asset in one place.', [172, 212, 680, 580], '<rect x="312" y="212" width="540" height="340" rx="56"/><rect x="222" y="312" width="580" height="380" rx="76" fill="#000"/><rect x="242" y="332" width="540" height="340" rx="56"/><rect x="152" y="432" width="580" height="380" rx="76" fill="#000"/><rect x="172" y="452" width="540" height="340" rx="56"/><rect x="172" y="532" width="540" height="56" fill="#000"/>'],
    ['bloom', 'Bloom', 'Eight petals opening — yield that blossoms.', [172, 172, 680, 680], petals + '<circle cx="512" cy="512" r="92" fill="#000"/>'],
    ['net', 'Network', 'Six nodes, one hub — decentralised by design.', [150, 150, 724, 724], net],
    ['drop', 'Drop', 'A single drop — liquidity, pure and simple.', [222, 152, 580, 770], '<path d="M512 152 C 512 152 802 452 802 632 A290 290 0 0 1 222 632 C 222 452 512 152 512 152 Z"/><circle cx="512" cy="642" r="120" fill="#000"/><circle cx="560" cy="596" r="112"/>'],
    ['recv', 'Receive', 'A coin with an arrow landing — money in.', [172, 172, 680, 680], '<circle cx="512" cy="512" r="340"/><path d="M512 302 V612 M382 492 L512 622 L642 492"' + SB(80) + '/><rect x="372" y="692" width="280" height="64" rx="32" fill="#000"/>'],
    ['dial', 'Dial', 'A safe’s combination dial — turn to unlock.', [172, 172, 680, 680], '<circle cx="512" cy="512" r="340"/>' + ticks + '<circle cx="512" cy="512" r="220" fill="#000"/><circle cx="512" cy="512" r="178"/><rect x="494" y="354" width="36" height="130" rx="18" fill="#000"/>'],
    ['roll', 'Roll', 'A coin roll seen from the side — stacked value.', [212, 242, 600, 540], '<rect x="212" y="352" width="600" height="320"/><ellipse cx="512" cy="672" rx="300" ry="110"/><ellipse cx="512" cy="352" rx="300" ry="110"/><ellipse cx="512" cy="352" rx="276" ry="92"' + SB(26) + '/><path d="M212 470 A300 110 0 0 0 812 470 M212 580 A300 110 0 0 0 812 580"' + SB(26) + '/>'],
    ['ticket', 'Token', 'A punched ticket — access, owned outright.', [142, 302, 740, 420], '<rect x="142" y="302" width="740" height="420" rx="50"/><circle cx="142" cy="512" r="76" fill="#000"/><circle cx="882" cy="512" r="76" fill="#000"/><circle cx="642" cy="372" r="18" fill="#000"/><circle cx="642" cy="442" r="18" fill="#000"/><circle cx="642" cy="512" r="18" fill="#000"/><circle cx="642" cy="582" r="18" fill="#000"/><circle cx="642" cy="652" r="18" fill="#000"/>'],
    ['spark', 'Spark', 'A four-point star — the moment value is born.', [152, 152, 720, 720], '<path d="M512 152 C 540 400 624 484 872 512 C 624 540 540 624 512 872 C 484 624 400 540 152 512 C 400 484 484 400 512 152 Z"/>'],
    ['door', 'Entry', 'A door left ajar — your way in, and no one else’s.', [252, 172, 520, 680], '<rect x="252" y="172" width="520" height="680" rx="40"/><rect x="322" y="242" width="380" height="610" fill="#000"/><path d="M322 242 L602 302 V852 H322 Z"/><circle cx="552" cy="560" r="28" fill="#000"/>']
  ];
  var ONEOFF = UNIQUE.map(function (u, i) {
    var id = 'u_' + u[0], gl = corners(u[3]), sh = i % 4, keys = ['A', 'B', 'C', 'D'];
    gl.forEach(function (g) { g.k = keys[(keys.indexOf(g.k) + sh) % 4]; if (g.k2) g.k2 = keys[(keys.indexOf(g.k2) + sh) % 4]; });
    CONCEPTS[id] = { bbox: u[3], glows: gl, masks: ['<g fill="#fff">' + u[4] + '</g>'] };
    return { id: id, n: i + 1, name: u[1], copy: u[2] };
  });

  // mode: 'light' | 'dark' | 'tinted'. o: { palette, glow, lights: 'Four'|'Two', tint, mark }
  function build(id, mode, o) {
    o = o || {};
    var c = CONCEPTS[id], P = PALETTES[o.palette] || PALETTES.Prism;
    var k = o.glow == null ? 1 : +o.glow, two = o.lights === 'Two', tint = o.tint || '#FFFFFF';
    var bg, base, col;
    if (mode === 'dark') { bg = '#0B0B0D'; base = '#EDEDEF'; col = function (key) { return P[key]; }; }
    else if (mode === 'tinted') { bg = '#000000'; base = mix(tint, '#000000', 0.45); col = function () { return tint; }; }
    else { bg = '#E3E3E4'; base = '#060608'; col = function (key) { return P[key]; }; }

    if (o.solid) base = o.solid;
    var glows = [];
    if (!o.solid) c.glows.forEach(function (g) { var key = two ? g.k2 : g.k; if (key) glows.push({ x: g.x, y: g.y, r: g.r, color: col(key) }); });
    var stops = [[0, 1], [0.32, 0.78], [0.66, 0.3], [1, 0]];
    var defs = glows.map(function (g, i) {
      return '<radialGradient id="g' + i + '" gradientUnits="userSpaceOnUse" cx="' + g.x + '" cy="' + g.y + '" r="' + n(g.r * (0.85 + 0.15 * k)) + '">' +
        stops.map(function (s) { return '<stop offset="' + s[0] + '" stop-color="' + g.color + '" stop-opacity="' + n(Math.min(1, s[1] * k)) + '"/>'; }).join('') +
        '</radialGradient>';
    }).join('');
    var field = '<rect width="1024" height="1024" fill="' + base + '"/>' +
      glows.map(function (g, i) { return '<rect width="1024" height="1024" fill="url(#g' + i + ')"/>'; }).join('');

    var inner = '';
    if (c.inner) {
      var gi = c.inner.grad, ic = mode === 'tinted' ? [tint, base, tint] : [P.B, base, two ? P.A : P.C];
      defs += '<linearGradient id="gi" gradientUnits="userSpaceOnUse" x1="' + gi[0] + '" y1="' + gi[1] + '" x2="' + gi[2] + '" y2="' + gi[3] + '">' +
        '<stop offset="0" stop-color="' + ic[0] + '"/><stop offset=".5" stop-color="' + ic[1] + '"/><stop offset="1" stop-color="' + ic[2] + '"/></linearGradient>';
      inner = '<g fill="url(#gi)">' + c.inner.body + '</g>';
    }
    defs += (c.defs || '') + c.masks.map(function (m, i) {
      return '<mask id="m' + i + '" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">' + m + '</mask>';
    }).join('');

    var b = c.bbox, vb = o.mark ? b.join(' ') : '0 0 1024 1024', w = o.mark ? b[2] : 1024, h = o.mark ? b[3] : 1024;
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="' + vb + '" width="' + w + '" height="' + h + '"><defs>' + defs + '</defs>' +
      (o.mark ? '' : '<rect width="1024" height="1024" fill="' + bg + '"/>') +
      c.masks.map(function (m, i) { return '<g mask="url(#m' + i + ')">' + field + '</g>'; }).join('') +
      inner + '</svg>';
  }
  function url(svg) { return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg); }

  root.OathIcons = { build: build, url: url, concepts: CONCEPTS, palettes: PALETTES, grid: GRID, oneoff: ONEOFF };
})(typeof window !== 'undefined' ? window : this);
