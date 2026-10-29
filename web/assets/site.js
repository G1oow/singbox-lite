/* ==========================================================================
   Netmeter — shared site behaviour
   Progressive enhancement only: every page stays usable if this file fails.
   ========================================================================== */

(function () {
  "use strict";

  if (!("IntersectionObserver" in window)) {
    // Reveal states are CSS-driven and gated on .js, so simply not adding the
    // class keeps everything visible on very old browsers.
    return;
  }

  document.documentElement.classList.add("js");

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* ---------- reveal on scroll ---------- */

  function markGroupChildren(root) {
    var i = 0;
    Array.prototype.forEach.call(root.children, function (child) {
      child.style.setProperty("--i", String(i++));
    });
  }

  var revealTargets = document.querySelectorAll("[data-reveal], [data-reveal-group]");
  Array.prototype.forEach.call(document.querySelectorAll("[data-reveal-group]"), markGroupChildren);

  if (reduceMotion.matches) {
    Array.prototype.forEach.call(revealTargets, function (el) {
      el.classList.add("is-revealed");
    });
  } else {
    var revealObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-revealed");
        revealObserver.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.08 });

    Array.prototype.forEach.call(revealTargets, function (el) {
      revealObserver.observe(el);
    });
  }

  /* ---------- count-up numbers ---------- */

  function animateCount(el) {
    var raw = el.getAttribute("data-count-to");
    var target = parseFloat(raw);
    if (isNaN(target)) return;

    var decimals = parseInt(el.getAttribute("data-decimals") || "0", 10);
    var suffix = el.getAttribute("data-suffix") || "";
    var prefix = el.getAttribute("data-prefix") || "";

    if (reduceMotion.matches) {
      el.textContent = prefix + target.toFixed(decimals) + suffix;
      return;
    }

    var duration = 900;
    var start = 0;

    function tick(now) {
      if (!start) start = now;
      var t = Math.min(1, (now - start) / duration);
      // easeOutCubic
      var eased = 1 - Math.pow(1 - t, 3);
      el.textContent = prefix + (target * eased).toFixed(decimals) + suffix;
      if (t < 1) window.requestAnimationFrame(tick);
    }

    window.requestAnimationFrame(tick);
  }

  var counters = document.querySelectorAll("[data-count-to]");
  if (counters.length) {
    var countObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        animateCount(entry.target);
        countObserver.unobserve(entry.target);
      });
    }, { threshold: 0.4 });

    Array.prototype.forEach.call(counters, function (el) {
      // Start from a plausible zero so the element never renders blank.
      el.textContent = (el.getAttribute("data-prefix") || "") + "0" +
        (parseInt(el.getAttribute("data-decimals") || "0", 10) > 0 ? "." + Array(parseInt(el.getAttribute("data-decimals"), 10) + 1).join("0") : "") +
        (el.getAttribute("data-suffix") || "");
      countObserver.observe(el);
    });
  }

  /* ---------- topbar scrolled state ---------- */

  var topbar = document.querySelector(".topbar");
  if (topbar) {
    var lastScrolled = null;
    var onScroll = function () {
      var scrolled = window.scrollY > 8;
      if (scrolled !== lastScrolled) {
        lastScrolled = scrolled;
        topbar.setAttribute("data-scrolled", scrolled ? "true" : "false");
      }
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  /* ---------- mobile nav ---------- */

  var toggle = document.querySelector(".nav-toggle");
  var nav = document.querySelector(".topnav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.getAttribute("data-open") === "true";
      nav.setAttribute("data-open", open ? "false" : "true");
      toggle.setAttribute("aria-expanded", open ? "false" : "true");
    });

    document.addEventListener("click", function (e) {
      if (nav.getAttribute("data-open") !== "true") return;
      if (nav.contains(e.target) || toggle.contains(e.target)) return;
      nav.setAttribute("data-open", "false");
      toggle.setAttribute("aria-expanded", "false");
    });

    document.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      if (nav.getAttribute("data-open") !== "true") return;
      nav.setAttribute("data-open", "false");
      toggle.setAttribute("aria-expanded", "false");
      toggle.focus();
    });
  }

  /* ---------- copy-to-clipboard ---------- */

  Array.prototype.forEach.call(document.querySelectorAll("[data-copy]"), function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy") || "";
      var note = btn.parentNode.querySelector(".copy-note");
      var flash = function (msg) {
        if (!note) return;
        note.textContent = msg;
        window.setTimeout(function () { note.textContent = ""; }, 1800);
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () { flash("Copied"); },
          function () { flash("Copy failed"); }
        );
      } else {
        flash("Copy unavailable");
      }
    });
  });

  /* ---------- in-page table of contents highlight ---------- */

  var tocLinks = document.querySelectorAll("[data-toc] a[href^='#']");
  if (tocLinks.length) {
    var sections = [];
    Array.prototype.forEach.call(tocLinks, function (link) {
      var id = link.getAttribute("href").slice(1);
      var section = document.getElementById(id);
      if (section) sections.push({ link: link, section: section });
    });

    if (sections.length && "IntersectionObserver" in window) {
      var tocObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          sections.forEach(function (item) {
            item.link.removeAttribute("aria-current");
          });
          for (var i = 0; i < sections.length; i++) {
            if (sections[i].section === entry.target) {
              sections[i].link.setAttribute("aria-current", "true");
              break;
            }
          }
        });
      }, { rootMargin: "-20% 0px -70% 0px" });

      sections.forEach(function (item) { tocObserver.observe(item.section); });
    }
  }

  /* ---------- footer year ---------- */

  Array.prototype.forEach.call(document.querySelectorAll("[data-year]"), function (el) {
    el.textContent = String(new Date().getFullYear());
  });
})();
