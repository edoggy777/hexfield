// Hexfield client — zero dependencies, so the whole UI fits in a few onchain chunks.
// Reads via raw JSON-RPC eth_call against the World; writes via the injected wallet (EIP-1193).
(() => {
  'use strict';

  // ---------------------------------------------------------------- selectors (from World ABI)
  const SEL = {
    config: '0x79502c55',
    getRegion: '0x8ecfe170',
    player: '0x4c54e1b5',
    spawn: '0x73ddd167',
    move: '0x3232df23',
    recruit: '0x0e0f3396',
    build: '0x4273ef2f',
  };
  const RPC = {
    8453: 'https://mainnet.base.org',
    84532: 'https://sepolia.base.org',
    31337: 'http://127.0.0.1:8545',
  };
  const TERRAIN = ['#5f7f3a', '#2f5a2b', '#7a6a4a', '#1f3b5c']; // plains forest hills water
  const BUILDING = ['', 'F', 'M', '⌂'];

  // ---------------------------------------------------------------- abi helpers
  const pad = (v) => BigInt(v).toString(16).padStart(64, '0');
  const enc = (sel, ...args) => sel + args.map(pad).join('');
  const words = (hex) => {
    const h = hex.startsWith('0x') ? hex.slice(2) : hex;
    const out = [];
    for (let i = 0; i < h.length; i += 64) out.push(BigInt('0x' + h.slice(i, i + 64)));
    return out;
  };

  // ---------------------------------------------------------------- state
  let cfg = null; // { world, chainId, renderer }
  let rpc = null;
  let W = 0, H = 0, endBlock = 0n, startBlock = 0n;
  let tiles = []; // bigint per tile, terrain in bits 64..67
  let block = 0n;
  let account = null;
  let me = null; // { id, grain, ore, tiles, score }
  let sel = -1, target = -1;

  // view
  const cv = document.getElementById('c');
  const ctx = cv.getContext('2d');
  let S = 22, ox = 40, oy = 40, drag = null;

  const $ = (id) => document.getElementById(id);
  const msg = (t, warn) => { $('msg').textContent = t; $('msg').className = warn ? 'warn' : ''; };

  // ---------------------------------------------------------------- rpc
  async function call(data) {
    const r = await fetch(rpc, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: cfg.world, data }, 'latest'] }),
    }).then((r) => r.json());
    if (r.error) throw new Error(r.error.message);
    return r.result;
  }
  async function blockNumber() {
    const r = await fetch(rpc, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_blockNumber', params: [] }),
    }).then((r) => r.json());
    return BigInt(r.result);
  }
  async function send(data) {
    if (!account) throw new Error('connect a wallet first');
    const cid = '0x' + Number(cfg.chainId).toString(16);
    try { await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: cid }] }); } catch (_) {}
    const hash = await window.ethereum.request({
      method: 'eth_sendTransaction', params: [{ from: account, to: cfg.world, data }],
    });
    msg('sent ' + hash.slice(0, 10) + '…');
    return hash;
  }

  // ---------------------------------------------------------------- loading
  async function loadConfig() {
    cfg = await fetch('config.json', { cache: 'no-store' }).then((r) => r.json());
    if (!/^0x[0-9a-fA-F]{40}$/.test(cfg.world || '')) {
      throw new Error(`config.json "world" must be a 42-char 0x address (got ${JSON.stringify(cfg.world)})`);
    }
    rpc = RPC[cfg.chainId] || RPC[8453];
    const raw = await call(SEL.config);
    if (!raw || raw === '0x') {
      throw new Error(`no World contract at ${cfg.world} on chain ${cfg.chainId} — redeploy and update config.json`);
    }
    const c = words(raw);
    W = Number(c[0]); H = Number(c[1]); startBlock = c[3]; endBlock = c[4];
    $('end').textContent = endBlock.toString();
  }
  let bootError = null;
  async function refresh() {
    if (bootError) return msg('boot failed: ' + bootError, true);
    if (!rpc) return;
    try {
      block = await blockNumber();
      $('blk').textContent = block.toString();
      const r = words(await call(enc(SEL.getRegion, 0, 0, W, H)));
      tiles = r.slice(2); // skip offset + length
      if (account) {
        const p = words(await call(SEL.player + pad(account)));
        me = { id: Number(p[0]), grain: p[1], ore: p[2], tiles: Number(p[5]), score: Number(p[6]) };
        $('grain').textContent = me.grain; $('ore').textContent = me.ore;
        $('tiles').textContent = me.tiles; $('score').textContent = me.score;
      }
      draw(); updateButtons();
      if ($('msg').className === 'warn') msg(''); // a successful read clears a stale error
    } catch (e) { msg(e.message, true); }
  }

  // ---------------------------------------------------------------- tile accessors
  const owner = (t) => Number(t & 0xffffffn);
  const building = (t) => Number((t >> 24n) & 0xffn);
  const garrison = (t) => Number((t >> 32n) & 0xffffffffn);
  const terrain = (t) => Number((t >> 64n) & 0xfn);
  const idOf = (x, y) => y * W + x;
  const xyOf = (id) => [id % W, Math.floor(id / W)];
  const ownerColor = (id) => `hsl(${(id * 137.508) % 360} 70% 55%)`;

  function adjacent(a, b) {
    if (a === b) return false;
    const [ax, ay] = xyOf(a), [bx, by] = xyOf(b);
    const dx = bx - ax, dy = by - ay;
    if (dy === 0) return Math.abs(dx) === 1;
    if (Math.abs(dy) !== 1) return false;
    return ay & 1 ? dx === 0 || dx === 1 : dx === 0 || dx === -1;
  }

  // ---------------------------------------------------------------- geometry (pointy-top, odd-r)
  const SQ3 = Math.sqrt(3);
  const center = (x, y) => [ox + S * SQ3 * (x + 0.5 * (y & 1)), oy + S * 1.5 * y];
  function hit(px, py) {
    // pixel -> fractional axial -> cube round -> odd-r
    const qf = ((px - ox) * SQ3 / 3 - (py - oy) / 3) / S;
    const rf = (py - oy) * 2 / 3 / S;
    let q = Math.round(qf), r = Math.round(rf), s = Math.round(-qf - rf);
    const dq = Math.abs(q - qf), dr = Math.abs(r - rf), ds = Math.abs(s + qf + rf);
    if (dq > dr && dq > ds) q = -r - s; else if (dr > ds) r = -q - s;
    const y = r, x = q + ((r - (r & 1)) >> 1);
    return x >= 0 && y >= 0 && x < W && y < H ? idOf(x, y) : -1;
  }

  // ---------------------------------------------------------------- drawing
  function resize() {
    const r = cv.parentElement.getBoundingClientRect();
    cv.width = r.width * devicePixelRatio; cv.height = r.height * devicePixelRatio;
    ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
    draw();
  }
  function hexPath(cx, cy, s) {
    ctx.beginPath();
    for (let i = 0; i < 6; i++) {
      const a = Math.PI / 180 * (60 * i - 30);
      const px = cx + s * Math.cos(a), py = cy + s * Math.sin(a);
      i ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
    }
    ctx.closePath();
  }
  function draw() {
    const w = cv.width / devicePixelRatio, h = cv.height / devicePixelRatio;
    ctx.clearRect(0, 0, w, h);
    if (!tiles.length) return;
    ctx.font = `${Math.max(9, S * 0.55)}px ui-monospace,monospace`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const id = idOf(x, y), t = tiles[id];
      const [cx, cy] = center(x, y);
      if (cx < -S || cy < -S || cx > w + S || cy > h + S) continue;
      hexPath(cx, cy, S - 1);
      ctx.fillStyle = TERRAIN[terrain(t)]; ctx.fill();
      const o = owner(t);
      if (o) {
        ctx.strokeStyle = ownerColor(o); ctx.lineWidth = me && o === me.id ? 3 : 2; ctx.stroke();
        ctx.fillStyle = '#fff';
        ctx.fillText(garrison(t) + (building(t) ? ' ' + BUILDING[building(t)] : ''), cx, cy);
      } else if (building(t)) {
        ctx.fillStyle = '#ccc'; ctx.fillText(BUILDING[building(t)], cx, cy);
      }
      if (id === sel || id === target) {
        hexPath(cx, cy, S - 1);
        ctx.strokeStyle = id === sel ? '#f2b134' : '#ff7b6b'; ctx.lineWidth = 3; ctx.stroke();
      }
    }
  }

  // ---------------------------------------------------------------- interaction
  cv.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY, ox, oy, moved: false }; cv.setPointerCapture(e.pointerId); });
  cv.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
    if (drag.moved) { ox = drag.ox + dx; oy = drag.oy + dy; draw(); }
  });
  cv.addEventListener('pointerup', (e) => {
    if (!drag) return;
    const moved = drag.moved; drag = null;
    if (moved) return;
    const r = cv.getBoundingClientRect();
    const id = hit(e.clientX - r.left, e.clientY - r.top);
    if (id < 0) return;
    const t = tiles[id];
    if (sel >= 0 && me && owner(tiles[sel]) === me.id && adjacent(sel, id) && terrain(t) !== 3) {
      target = target === id ? -1 : id;
    } else { sel = id; target = -1; }
    describe(); draw(); updateButtons();
  });
  cv.addEventListener('wheel', (e) => {
    e.preventDefault();
    const k = e.deltaY < 0 ? 1.1 : 0.9;
    const r = cv.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    ox = mx - (mx - ox) * k; oy = my - (my - oy) * k; S = Math.min(60, Math.max(6, S * k));
    draw();
  }, { passive: false });
  addEventListener('resize', resize);

  function describe() {
    if (sel < 0) { $('sel').textContent = ''; return; }
    const t = tiles[sel], [x, y] = xyOf(sel);
    const names = ['plains', 'forest', 'hills', 'water'];
    $('sel').textContent = `#${sel} (${x},${y}) ${names[terrain(t)]}` +
      (owner(t) ? ` · player ${owner(t)} · ${garrison(t)} troops` : ' · unowned') +
      (building(t) ? ` · ${['', 'farm', 'mine', 'fort'][building(t)]}` : '') +
      (target >= 0 ? ` → #${target}` : '');
  }
  function updateButtons() {
    const have = sel >= 0 && tiles.length;
    const t = have ? tiles[sel] : 0n;
    const mine = have && me && me.id && owner(t) === me.id;
    const active = block >= startBlock && block <= endBlock;
    $('spawn').disabled = !(have && account && active && me && !me.id && !owner(t) && terrain(t) !== 3);
    $('move').disabled = !(mine && target >= 0 && active);
    $('recruit').disabled = !(mine && active);
    $('farm').disabled = !(mine && active && !building(t) && terrain(t) <= 1);
    $('mine').disabled = !(mine && active && !building(t) && terrain(t) === 2);
    $('fort').disabled = !(mine && active && !building(t));
  }
  const n = () => Math.max(1, parseInt($('n').value, 10) || 1);

  function setAccount(a) {
    account = a || null;
    me = null;
    $('acct').textContent = account ? account.slice(0, 6) + '…' + account.slice(-4) : '';
    $('connect').textContent = account ? 'connected' : 'connect wallet';
    msg('');
    refresh();
  }
  $('connect').onclick = async () => {
    if (!window.ethereum) return msg('no wallet found', true);
    try {
      const [a] = await window.ethereum.request({ method: 'eth_requestAccounts' });
      setAccount(a);
    } catch (e) { msg(e.message, true); }
  };
  if (window.ethereum && window.ethereum.on) {
    window.ethereum.on('accountsChanged', (accs) => setAccount(accs[0]));
    window.ethereum.on('chainChanged', () => refresh());
  }
  $('spawn').onclick = () => send(enc(SEL.spawn, sel)).catch((e) => msg(e.message, true));
  $('move').onclick = () => send(enc(SEL.move, sel, target, n())).catch((e) => msg(e.message, true));
  $('recruit').onclick = () => send(enc(SEL.recruit, sel, n())).catch((e) => msg(e.message, true));
  $('farm').onclick = () => send(enc(SEL.build, sel, 1)).catch((e) => msg(e.message, true));
  $('mine').onclick = () => send(enc(SEL.build, sel, 2)).catch((e) => msg(e.message, true));
  $('fort').onclick = () => send(enc(SEL.build, sel, 3)).catch((e) => msg(e.message, true));

  // ---------------------------------------------------------------- boot
  (async () => {
    try {
      await loadConfig();
      resize();
      await refresh();
      setInterval(refresh, 2000);
      msg(`${W}×${H} map · ${cfg.world.slice(0, 10)}…`);
    } catch (e) { bootError = e.message; msg('boot failed: ' + e.message, true); console.error(e); }
  })();
})();
