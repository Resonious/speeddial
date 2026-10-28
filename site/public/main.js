// SpeedDial landing page: fire, reveals, the screenshot window and the keypad.
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // --- Fire -------------------------------------------------------------
  // Additive glowing blobs rising from a source line: one coherent flame
  // rather than a cloud of dust. Runs only while on screen.
  const COLORS = [
    [255, 241, 201], // core
    [255, 192, 74], // tip
    [255, 122, 51], // ember
    [229, 64, 42], // root
  ];

  function fire(canvas, opts) {
    const ctx = canvas.getContext('2d');
    const parts = [];
    let w = 0, h = 0, dpr = 1, running = false, raf = 0, last = 0;

    function resize() {
      dpr = Math.min(devicePixelRatio || 1, 2);
      const r = canvas.getBoundingClientRect();
      w = r.width; h = r.height;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    function spawn() {
      const src = opts.source(w, h);
      const x = src.x + (Math.random() - 0.5) * src.spread;
      const life = 0.9 + Math.random() * 1.1;
      parts.push({
        x, y: src.y + Math.random() * 10,
        vx: (Math.random() - 0.5) * 30,
        vy: -(60 + Math.random() * 120) * opts.speed,
        r: (opts.size * (0.6 + Math.random() * 0.8)),
        age: 0, life,
        seed: Math.random() * 1000,
      });
    }

    function colorAt(t) {
      // t: 0 (young, hot) → 1 (old, cooled)
      const s = Math.min(t * 3, 2.999);
      const i = Math.floor(s), f = s - i;
      const a = COLORS[i], b = COLORS[i + 1];
      return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
    }

    function frame(now) {
      const dt = Math.min((now - last) / 1000, 0.05);
      last = now;
      ctx.globalCompositeOperation = 'source-over';
      ctx.clearRect(0, 0, w, h);
      ctx.globalCompositeOperation = 'lighter';
      const want = opts.rate * dt * (w / 1000 + 0.4);
      for (let n = want + Math.random(); n >= 1; n--) spawn();
      for (let i = parts.length - 1; i >= 0; i--) {
        const p = parts[i];
        p.age += dt;
        const t = p.age / p.life;
        if (t >= 1) { parts.splice(i, 1); continue; }
        // Licks sway; drag keeps them near their source.
        p.vx += Math.sin(now / 300 + p.seed) * 40 * dt;
        p.vx *= 0.98;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        const r = p.r * (1 - t * 0.7);
        const [cr, cg, cb] = colorAt(t);
        const alpha = (t < 0.1 ? t / 0.1 : 1 - (t - 0.1) / 0.9) * opts.alpha;
        const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
        g.addColorStop(0, `rgba(${cr|0},${cg|0},${cb|0},${alpha})`);
        g.addColorStop(1, `rgba(${cr|0},${cg|0},${cb|0},0)`);
        ctx.fillStyle = g;
        // Stretch each blob upward into a lick of flame.
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.scale(1, 1.7 + t);
        ctx.translate(-p.x, -p.y);
        ctx.beginPath();
        ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      if (running) raf = requestAnimationFrame(frame);
    }

    function start() {
      if (running) return;
      running = true;
      last = performance.now();
      raf = requestAnimationFrame(frame);
    }
    function stop() { running = false; cancelAnimationFrame(raf); }

    resize();
    addEventListener('resize', resize);
    if (reduced) {
      // One still frame: the end state, no ticker.
      last = performance.now() - 16;
      for (let k = 0; k < 90; k++) frame(last + 16 * (k + 1));
      return;
    }
    new IntersectionObserver(([e]) => (e.isIntersecting ? start() : stop()))
      .observe(canvas);
  }

  const heroFire = document.querySelector('.hero-fire');
  const phone = document.querySelector('.phone');
  if (heroFire && phone) {
    fire(heroFire, {
      rate: 260, size: 46, speed: 1.4, alpha: 0.32,
      source: (w, h) => {
        const r = phone.getBoundingClientRect();
        const c = heroFire.getBoundingClientRect();
        // Mostly from the phone's base, sometimes licking up its sides.
        const roll = Math.random();
        const left = r.left - c.left, right = r.right - c.left;
        if (roll < 0.55) return { x: (left + right) / 2, y: r.bottom - c.top - 30, spread: r.width * 1.1 };
        const side = roll < 0.775 ? left + 10 : right - 10;
        const y = r.top - c.top + r.height * (0.35 + Math.random() * 0.6);
        return { x: side, y, spread: 40 };
      },
    });
  }
  const footFire = document.querySelector('.footer-fire');
  if (footFire) {
    fire(footFire, {
      rate: 200, size: 40, speed: 1, alpha: 0.22,
      source: (w, h) => ({ x: w / 2, y: h + 20, spread: w * 1.1 }),
    });
  }

  // --- Reveals ----------------------------------------------------------
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }
  }, { threshold: 0, rootMargin: '0px 0px -10% 0px' });
  document.querySelectorAll('.reveal').forEach((el) => io.observe(el));

  // --- Screenshot window ------------------------------------------------
  const win = document.querySelector('[data-theme-target]');
  if (win) {
    const img = win.querySelector('[data-shot-img]');
    let shot = 'run', theme = 'dark';
    const show = () => {
      const src = `/shots/${shot}-${theme}.webp`;
      win.classList.toggle('light', theme === 'light');
      if (reduced) { img.src = src; return; }
      const pre = new Image();
      pre.src = src;
      img.classList.add('swap');
      pre.decode().catch(() => {}).then(() => setTimeout(() => {
        img.src = src;
        img.classList.remove('swap');
      }, 180));
    };
    win.querySelectorAll('[data-shot]').forEach((b) => b.addEventListener('click', () => {
      win.querySelectorAll('[data-shot]').forEach((o) => o.classList.toggle('on', o === b));
      shot = b.dataset.shot;
      show();
    }));
    win.querySelector('[data-theme-toggle]').addEventListener('click', () => {
      theme = theme === 'dark' ? 'light' : 'dark';
      show();
    });
  }

  // --- Light/dark compare -------------------------------------------------
  const duo = document.querySelector('.duo-compare');
  if (duo) {
    const range = duo.querySelector('input');
    range.addEventListener('input', () => duo.style.setProperty('--split', `${range.value}%`));
  }

  // --- Keypad: DTMF beeps and a little burst of sparks --------------------
  let audio = null;
  const DTMF = {
    1: [697, 1209], 2: [697, 1336], 3: [697, 1477],
    4: [770, 1209], 5: [770, 1336], 6: [770, 1477],
    7: [852, 1209], 8: [852, 1336], 9: [852, 1477],
    '*': [941, 1209], 0: [941, 1336], '#': [941, 1477],
  };
  function beep(key) {
    try {
      audio = audio || new AudioContext();
      const t = audio.currentTime;
      const gain = audio.createGain();
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.06, t + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.16);
      gain.connect(audio.destination);
      for (const f of DTMF[key]) {
        const o = audio.createOscillator();
        o.frequency.value = f;
        o.connect(gain);
        o.start(t);
        o.stop(t + 0.18);
      }
    } catch (_) { /* no audio: silent keypad */ }
  }
  function sparks(el) {
    if (reduced) return;
    const r = el.getBoundingClientRect();
    for (let i = 0; i < 7; i++) {
      const s = document.createElement('i');
      s.className = 'spark';
      s.style.left = `${r.left + r.width / 2}px`;
      s.style.top = `${r.top + r.height / 2}px`;
      document.body.appendChild(s);
      const a = -Math.PI / 2 + (Math.random() - 0.5) * 2.2;
      const d = 40 + Math.random() * 50;
      s.animate([
        { transform: 'translate(0,0) scale(1)', opacity: 1 },
        { transform: `translate(${Math.cos(a) * d}px, ${Math.sin(a) * d}px) scale(.3)`, opacity: 0 },
      ], { duration: 650 + Math.random() * 300, easing: 'cubic-bezier(.16,1,.3,1)' }).onfinish = () => s.remove();
    }
  }
  document.querySelectorAll('.key').forEach((k) => {
    k.addEventListener('click', () => {
      beep(k.dataset.key);
      sparks(k);
      k.classList.add('lit');
      setTimeout(() => k.classList.remove('lit'), 400);
    });
  });

  // --- Copy button: an ember check and "Copied" for two seconds ------------
  document.querySelectorAll('[data-copy]').forEach((b) => {
    const label = b.querySelector('.copy-label');
    b.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(b.dataset.copy);
        b.classList.add('copied');
        label.textContent = '✓ Copied';
      } catch (_) {
        label.textContent = 'Copy failed';
      }
      setTimeout(() => { b.classList.remove('copied'); label.textContent = 'Copy'; }, 2000);
    });
  });
})();
