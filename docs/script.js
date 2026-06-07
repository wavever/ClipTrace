/* ClipTrace · 剪迹 — landing page behaviour
   No build step, no dependencies. */
(() => {
  'use strict';

  const root = document.documentElement;
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ----------------------------------------------------------
     i18n — every translatable node carries data-en / data-zh.
     Values may contain inline HTML, so we set innerHTML.
     Choice persists in localStorage; first visit auto-detects.
  ---------------------------------------------------------- */
  const META = {
    en: {
      title: '剪迹 · ClipTrace — Local-first clipboard history for macOS & AI',
      description: 'ClipTrace is an open-source macOS clipboard manager with offline semantic search and a built-in MCP server. Local-first, private, and AI-ready.',
      toggleLabel: 'Switch language to Chinese',
      swQuery: 'meeting notes from last week'
    },
    zh: {
      title: '剪迹 · ClipTrace — 面向 macOS 与 AI 工具的本地优先剪贴板历史',
      description: '剪迹是一款开源 macOS 剪贴板管理工具，支持离线语义搜索和内置 MCP 服务器。本地优先、隐私默认、面向 AI 工具。',
      toggleLabel: '切换语言为 English',
      swQuery: '上周的会议记录'
    }
  };

  const nodes = Array.from(document.querySelectorAll('[data-en],[data-zh]'));
  const langToggle = document.getElementById('langToggle');
  const setMeta = (selector, value) => {
    document.querySelector(selector)?.setAttribute('content', value);
  };

  function applyLang(lang) {
    root.setAttribute('lang', lang);
    document.title = META[lang].title;
    setMeta('meta[name="description"]', META[lang].description);
    setMeta('meta[property="og:title"]', '剪迹 · ClipTrace');
    setMeta('meta[property="og:description"]', META[lang].description);
    setMeta('meta[name="twitter:title"]', '剪迹 · ClipTrace');
    setMeta('meta[name="twitter:description"]', META[lang].description);
    langToggle?.setAttribute('aria-label', META[lang].toggleLabel);

    nodes.forEach((el) => {
      const val = el.dataset[lang];
      if (val != null) el.innerHTML = val;
    });

    document.querySelectorAll('.lang-opt').forEach((o) => {
      o.classList.toggle('active', o.dataset.lang === lang);
    });

    try { localStorage.setItem('cliptrace-lang', lang); } catch (_) {}
    // restart the typing demo in the new language
    startTyping(META[lang].swQuery);
  }

  function initLang() {
    let lang = new URLSearchParams(location.search).get('lang');
    if (lang !== 'en' && lang !== 'zh') {
      try { lang = localStorage.getItem('cliptrace-lang'); } catch (_) {}
    }
    if (lang !== 'en' && lang !== 'zh') {
      lang = (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh' : 'en';
    }
    applyLang(lang);
  }

  langToggle?.addEventListener('click', () => {
    applyLang(root.getAttribute('lang') === 'zh' ? 'en' : 'zh');
  });

  /* ----------------------------------------------------------
     Sticky-nav shadow on scroll
  ---------------------------------------------------------- */
  const nav = document.getElementById('nav');
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 12);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  /* ----------------------------------------------------------
     Scroll reveals
  ---------------------------------------------------------- */
  const revealIO = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); revealIO.unobserve(e.target); }
    });
  }, { threshold: 0.16, rootMargin: '0px 0px -8% 0px' });
  document.querySelectorAll('.reveal').forEach((el) => revealIO.observe(el));

  // search-demo result rows animate when the window is in view
  const swDemo = document.querySelector('.search-window');
  if (swDemo) {
    const rowIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.querySelectorAll('.sw-row').forEach((r) => r.classList.add('in'));
          rowIO.unobserve(e.target);
        }
      });
    }, { threshold: 0.4 });
    rowIO.observe(swDemo);
  }

  /* ----------------------------------------------------------
     Photo stack — pull forward the print actually under the pointer.
     We prefer stable layout boxes so an animating/raised print cannot steal
     the pointer from the photo currently under the cursor.
  ---------------------------------------------------------- */
  const stack = document.getElementById('photoStack');
  if (stack && !reduceMotion && window.matchMedia('(pointer:fine)').matches) {
    const P = {
      stats: stack.querySelector('.ph-stats'),
      main:  stack.querySelector('.ph-main'),
      mcp:   stack.querySelector('.ph-mcp'),
    };
    if (P.stats && P.main && P.mcp) {
      stack.classList.add('controlled');   // hand control to JS, disable CSS :hover
      const photos = [P.stats, P.main, P.mcp];
      let active = null, lastClientX = 0, lastClientY = 0, raf = null;
      const departureTimers = new Map();

      const clearDeparture = (el) => {
        const timer = departureTimers.get(el);
        if (timer) clearTimeout(timer);
        departureTimers.delete(el);
        el.classList.remove('is-departing');
      };

      const markDeparting = (el) => {
        if (!el) return;
        clearDeparture(el);
        el.classList.add('is-departing');
        departureTimers.set(el, setTimeout(() => {
          el.classList.remove('is-departing');
          departureTimers.delete(el);
        }, 760));
      };

      const clearAllDepartures = () => {
        photos.forEach(clearDeparture);
      };

      const syncActiveClass = (el) => {
        stack.classList.remove('active-stats', 'active-main', 'active-mcp');
        if (el === P.stats) stack.classList.add('active-stats');
        if (el === P.main) stack.classList.add('active-main');
        if (el === P.mcp) stack.classList.add('active-mcp');
      };

      const setActive = (el, options = {}) => {
        if (el === active) return;
        const { keepDeparture = Boolean(el) } = options;
        const previous = active;
        active = el;
        if (previous && keepDeparture) markDeparting(previous);
        if (!keepDeparture) clearAllDepartures();
        if (el) clearDeparture(el);
        syncActiveClass(el);
        P.stats.classList.toggle('is-active', el === P.stats);
        P.main.classList.toggle('is-active',  el === P.main);
        P.mcp.classList.toggle('is-active',   el === P.mcp);
      };

      const uniquePhotoHits = (clientX, clientY) => {
        const seen = new Set();
        return document.elementsFromPoint(clientX, clientY)
          .map((el) => el.closest?.('.photo'))
          .filter((photo) => {
            if (!photo || !stack.contains(photo) || !photos.includes(photo) || seen.has(photo)) return false;
            seen.add(photo);
            return !photo.classList.contains('is-departing');
          });
      };

      const stableLayoutPick = (clientX, clientY) => {
        const r = stack.getBoundingClientRect();
        const x = clientX - r.left;
        const y = clientY - r.top;
        const candidates = photos.filter((photo) => {
          if (photo.classList.contains('is-departing')) return false;
          return x >= photo.offsetLeft &&
            x <= photo.offsetLeft + photo.offsetWidth &&
            y >= photo.offsetTop &&
            y <= photo.offsetTop + photo.offsetHeight;
        });
        if (!candidates.length) return null;

        return candidates
          .map((photo) => {
            const cx = photo.offsetLeft + photo.offsetWidth / 2;
            const cy = photo.offsetTop + photo.offsetHeight / 2;
            const dx = Math.abs(x - cx) / (photo.offsetWidth / 2);
            const dy = Math.abs(y - cy) / (photo.offsetHeight / 2);
            const activeBias = photo === active ? 0.18 : 0;
            const frontBias = photo === P.main ? 0.04 : 0;
            return { photo, score: Math.hypot(dx, dy) - activeBias - frontBias };
          })
          .sort((a, b) => a.score - b.score)[0].photo;
      };

      const pick = (clientX, clientY) => {
        return stableLayoutPick(clientX, clientY) || uniquePhotoHits(clientX, clientY)[0];
      };

      const update = () => {
        raf = null;
        const picked = pick(lastClientX, lastClientY);
        stack.classList.toggle('engaged', Boolean(picked));
        setActive(picked);
      };

      stack.addEventListener('pointermove', (e) => {
        lastClientX = e.clientX;
        lastClientY = e.clientY;
        if (!raf) raf = requestAnimationFrame(update);
      });
      stack.addEventListener('pointerleave', () => {
        if (raf) { cancelAnimationFrame(raf); raf = null; }
        stack.classList.remove('engaged');
        setActive(null, { keepDeparture: false });
      });
    }
  }

  /* ----------------------------------------------------------
     Trace-spine: highlight the node for the section in view
  ---------------------------------------------------------- */
  const spineNodes = Array.from(document.querySelectorAll('.spine-node'));
  if (spineNodes.length) {
    const sections = spineNodes
      .map((n) => document.getElementById(n.dataset.target))
      .filter(Boolean);
    const spineIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          const id = e.target.id;
          spineNodes.forEach((n) => n.classList.toggle('active', n.dataset.target === id));
        }
      });
    }, { threshold: 0.5, rootMargin: '-40% 0px -40% 0px' });
    sections.forEach((s) => spineIO.observe(s));
    // node click → scroll to section
    spineNodes.forEach((n) => {
      n.style.pointerEvents = 'auto';
      n.addEventListener('click', () => {
        document.getElementById(n.dataset.target)?.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth' });
      });
    });
  }

  /* ----------------------------------------------------------
     Typing demo in the search window
  ---------------------------------------------------------- */
  const typed = document.getElementById('swTyped');
  let typeTimer = null;
  function startTyping(text) {
    if (!typed) return;
    clearTimeout(typeTimer);
    if (reduceMotion) { typed.textContent = text; return; }
    typed.textContent = '';
    let i = 0;
    const tick = () => {
      typed.textContent = text.slice(0, i);
      if (i++ <= text.length) typeTimer = setTimeout(tick, 55 + Math.random() * 40);
    };
    // delay until the demo is likely on screen
    typeTimer = setTimeout(tick, 600);
  }

  /* ----------------------------------------------------------
     Copy the MCP config
  ---------------------------------------------------------- */
  const copyBtn = document.getElementById('termCopy');
  copyBtn?.addEventListener('click', async () => {
    const cfg = {
      mcpServers: {
        clipboard: {
          command: '/Applications/ClipTrace.app/Contents/MacOS/ClipTrace',
          args: ['--mcp']
        }
      }
    };
    try {
      await navigator.clipboard.writeText(JSON.stringify(cfg, null, 2));
      const original = copyBtn.dataset[root.getAttribute('lang')] || 'Copy';
      copyBtn.textContent = root.getAttribute('lang') === 'zh' ? '已复制 ✓' : 'Copied ✓';
      copyBtn.classList.add('copied');
      setTimeout(() => { copyBtn.textContent = original; copyBtn.classList.remove('copied'); }, 1800);
    } catch (_) { /* clipboard blocked — no-op */ }
  });

  /* ----------------------------------------------------------
     Boot
  ---------------------------------------------------------- */
  initLang();
})();
