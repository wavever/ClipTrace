/* Clipth · landing-page behaviour
 * Language state, workbench position, and the post-tour download dock.
 */

(() => {
  const root = document.documentElement;
  root.classList.add('js');

  const langToggle = document.getElementById('langToggle');
  const downloadDock = document.getElementById('downloadDock');
  const copyNodes = Array.from(document.querySelectorAll('[data-en][data-zh]'));
  const translatedImages = Array.from(document.querySelectorAll('img[data-alt-en][data-alt-zh]'));
  const railItems = Array.from(document.querySelectorAll('[data-rail]'));
  const chapters = Array.from(document.querySelectorAll('[data-chapter]'));
  const featureRows = Array.from(document.querySelectorAll('.feature-row'));

  const META = {
    en: {
      title: '剪迹 · Clipth — Local-first clipboard history for macOS',
      description: 'Clipth is an open-source, local-first clipboard manager for macOS with offline semantic search, encrypted sync, content protection, and a built-in MCP server.',
      social: 'Copy once. Find it when it matters. Local-first clipboard history for macOS.',
      toggle: 'Switch language to Chinese'
    },
    zh: {
      title: '剪迹 · Clipth — 本地优先的 macOS 剪贴板历史',
      description: '剪迹是一款开源、本地优先的 macOS 剪贴板管理工具，支持离线语义搜索、加密同步、内容保护和内置 MCP 服务器。',
      social: '复制过的，需要时都找得回来。本地优先的 macOS 剪贴板历史。',
      toggle: 'Switch language to English'
    }
  };

  const setMeta = (selector, value) => {
    document.querySelector(selector)?.setAttribute('content', value);
  };

  function applyLanguage(language) {
    const lang = language === 'zh' ? 'zh' : 'en';
    root.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = META[lang].title;

    copyNodes.forEach((node) => {
      node.innerHTML = node.dataset[lang];
    });

    translatedImages.forEach((image) => {
      image.alt = image.dataset[`alt${lang === 'zh' ? 'Zh' : 'En'}`];
    });

    document.querySelectorAll('.lang-toggle [data-lang]').forEach((option) => {
      option.classList.toggle('is-active', option.dataset.lang === lang);
    });

    langToggle?.setAttribute('aria-label', META[lang].toggle);
    setMeta('meta[name="description"]', META[lang].description);
    setMeta('meta[property="og:description"]', META[lang].social);
    setMeta('meta[name="twitter:description"]', META[lang].social);

    try {
      localStorage.setItem('clipth-language', lang);
    } catch (_) {
      // The language still applies when storage is unavailable.
    }
  }

  function initialLanguage() {
    const queryLanguage = new URLSearchParams(window.location.search).get('lang');
    if (queryLanguage === 'en' || queryLanguage === 'zh') return queryLanguage;

    try {
      const storedLanguage = localStorage.getItem('clipth-language');
      if (storedLanguage === 'en' || storedLanguage === 'zh') return storedLanguage;
    } catch (_) {
      // Fall through to the browser language.
    }

    return (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh' : 'en';
  }

  langToggle?.addEventListener('click', () => {
    applyLanguage(root.lang.startsWith('zh') ? 'en' : 'zh');
  });

  if ('IntersectionObserver' in window && chapters.length) {
    const chapterObserver = new IntersectionObserver((entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

      if (!visible) return;
      const activeChapter = visible.target.dataset.chapter;
      railItems.forEach((item) => {
        item.classList.toggle('is-active', item.dataset.rail === activeChapter);
      });
    }, {
      threshold: [0.25, 0.5, 0.75],
      rootMargin: '-18% 0px -42% 0px'
    });

    chapters.forEach((chapter) => chapterObserver.observe(chapter));
  }

  if ('IntersectionObserver' in window && featureRows.length) {
    const featureObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, {
      threshold: 0.12,
      rootMargin: '0px 0px -8% 0px'
    });

    featureRows.forEach((row) => featureObserver.observe(row));
  } else {
    featureRows.forEach((row) => row.classList.add('is-visible'));
  }

  if ('IntersectionObserver' in window && downloadDock) {
    const privacySection = document.getElementById('privacy');
    const downloadSection = document.getElementById('download');
    let featureTourCompleted = false;
    let downloadVisible = false;

    const syncDock = () => {
      const visible = featureTourCompleted && !downloadVisible;
      downloadDock.classList.toggle('is-visible', visible);
      downloadDock.setAttribute('aria-hidden', String(!visible));
    };

    if (privacySection) {
      new IntersectionObserver((entries, observer) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          featureTourCompleted = true;
          syncDock();
          observer.disconnect();
        }
      }, { threshold: 0.25 }).observe(privacySection);
    }

    if (downloadSection) {
      new IntersectionObserver((entries) => {
        downloadVisible = entries.some((entry) => entry.isIntersecting);
        syncDock();
      }, { threshold: 0.2 }).observe(downloadSection);
    }
  }

  const year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  applyLanguage(initialLanguage());
})();
