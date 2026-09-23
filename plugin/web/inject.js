/*
 * CommunityCAD for Mainsail - injection prototype (feasibility spike, not production code).
 *
 * Loaded via an nginx sub_filter-injected <script defer> tag. It must never break
 * Mainsail: every entry point is wrapped, nothing here patches Mainsail's JS, and all
 * UI lives inside a Shadow DOM. If any selector stops matching, the script degrades
 * to doing nothing (or to a floating button), never to throwing.
 */
(function () {
    'use strict';

    var VERSION = '0.0.1-spike';

    // Every DOM assumption about Mainsail lives here, most specific first.
    var SELECTORS = {
        navList: ['nav.v-navigation-drawer .v-list', 'nav .v-list'],
        navLink: 'a.v-list-item[href]',
        navTitle: '.v-list-item__title',
        navIconPath: 'svg path',
        main: ['main#content', 'main.v-main', 'main'],
        mainWrap: '.v-main__wrap',
        pageContainer: '#page-container',
        mobileDrawerOpen: 'nav.v-navigation-drawer--is-mobile.v-navigation-drawer--open',
        drawerToggle: 'header button.v-app-bar__nav-icon',
    };

    // mdi-cube-outline
    var ICON_PATH =
        'M21,16.5C21,16.88 20.79,17.21 20.47,17.38L12.57,21.82C12.41,21.94 12.21,22 12,22C11.79,22 11.59,21.94 11.43,21.82L3.53,17.38C3.21,17.21 3,16.88 3,16.5V7.5C3,7.12 3.21,6.79 3.53,6.62L11.43,2.18C11.59,2.06 11.79,2 12,2C12.21,2 12.41,2.06 12.57,2.18L20.47,6.62C20.79,6.79 21,7.12 21,7.5V16.5M12,4.15L6.04,7.5L12,10.85L17.96,7.5L12,4.15M5,15.91L11,19.29V12.58L5,9.21V15.91M19,15.91V9.21L13,12.58V19.29L19,15.91Z';

    var ACTIVE_CLASS = 'ccad-active';
    var NAV_ID = 'ccad-nav-item';
    var HOST_ID = 'ccad-root';
    var FALLBACK_ID = 'ccad-fallback-button';
    var GIVE_UP_MS = 20000;

    var state = { active: false, activeHref: null, observer: null, startedAt: Date.now() };

    function log() {
        try {
            var args = Array.prototype.slice.call(arguments);
            args.unshift('[communitycad]');
            console.debug.apply(console, args);
        } catch (e) {
            /* ignore */
        }
    }

    function guard(fn) {
        return function () {
            try {
                return fn.apply(this, arguments);
            } catch (e) {
                log('suppressed error', e);
            }
        };
    }

    function first(selectors, root) {
        root = root || document;
        for (var i = 0; i < selectors.length; i++) {
            var el = root.querySelector(selectors[i]);
            if (el) return el;
        }
        return null;
    }

    // Global CSS is limited to hiding Mainsail's page while our view is shown and
    // muting Mainsail's active-item highlight; everything is keyed on ACTIVE_CLASS.
    function ensureGlobalStyle() {
        if (document.getElementById('ccad-global-style')) return;
        var style = document.createElement('style');
        style.id = 'ccad-global-style';
        style.textContent =
            '#' + HOST_ID + '{display:none}' +
            'html.' + ACTIVE_CLASS + ' #' + HOST_ID + '{display:block}' +
            'html.' + ACTIVE_CLASS + ' ' + SELECTORS.pageContainer + '{display:none!important}' +
            'html.' + ACTIVE_CLASS + ' nav a.v-list-item--active:not(.ccad-link)::before{opacity:0!important}' +
            'html.' + ACTIVE_CLASS + ' nav a.active-nav-item:not(.ccad-link){border-right-color:transparent!important;border-right-width:0!important}';
        document.head.appendChild(style);
    }

    function buildNavItem(navList) {
        // Clone a real page link (title + icon). Not simply the first link: on mobile the list
        // starts with a logo/printer-name item that has neither.
        var links = Array.prototype.filter.call(navList.querySelectorAll(SELECTORS.navLink), function (a) {
            return a.id !== NAV_ID && a.querySelector(SELECTORS.navTitle) && a.querySelector(SELECTORS.navIconPath);
        });
        var template = links[links.length - 1];
        if (!template) return null;
        // Clone Mainsail's own markup so Vuetify/scoped styles apply; cloneNode does not copy Vue listeners.
        var wrapper = template.parentElement !== navList ? template.parentElement : template;
        var item = wrapper.cloneNode(true);
        item.id = NAV_ID;
        var link = item.matches(SELECTORS.navLink) ? item : item.querySelector(SELECTORS.navLink);
        link.classList.add('ccad-link');
        link.setAttribute('href', '#communitycad');
        link.removeAttribute('aria-current');
        link.removeAttribute('router');
        link.classList.remove('v-list-item--active', 'active-nav-item');
        var title = link.querySelector(SELECTORS.navTitle);
        if (title) title.textContent = ' CommunityCAD ';
        var paths = link.querySelectorAll(SELECTORS.navIconPath);
        if (paths.length) {
            paths[0].setAttribute('d', ICON_PATH);
            for (var i = 1; i < paths.length; i++) paths[i].remove();
        }
        link.addEventListener(
            'click',
            guard(function (ev) {
                ev.preventDefault();
                ev.stopPropagation();
                activate();
            })
        );
        return item;
    }

    function buildHost() {
        var host = document.createElement('div');
        host.id = HOST_ID;
        var root = host.attachShadow({ mode: 'open' });
        root.innerHTML =
            '<style>' +
            // Page rules that match the host element (e.g. Vuetify's `*{padding:0}` reset) beat :host,
            // so layout lives on an inner wrapper.
            ':host{display:block;color:inherit}' +
            '.wrap{box-sizing:border-box;padding:24px;font:14px/1.5 Roboto,system-ui,-apple-system,"Segoe UI",sans-serif}' +
            '.panel{border:1px solid rgba(127,127,127,.35);border-radius:6px;padding:20px 24px;' +
            'background:rgba(127,127,127,.08);max-width:900px}' +
            'h2{margin:0 0 8px;font-size:20px;font-weight:500}' +
            'p{margin:0 0 8px;opacity:.85}' +
            'code{font-family:ui-monospace,monospace;font-size:12px;opacity:.7}' +
            '</style>' +
            '<div class="wrap"><div class="panel" part="panel">' +
            '<h2>CommunityCAD</h2>' +
            '<p>Model browser placeholder. This panel is rendered by an injected script inside a Shadow DOM.</p>' +
            '<code>inject.js ' + VERSION + '</code>' +
            '</div></div>';
        return host;
    }

    function setNavActive(on) {
        var link = document.querySelector('#' + NAV_ID + ' a');
        if (!link) return;
        link.classList.toggle('v-list-item--active', on);
        link.classList.toggle('active-nav-item', on);
    }

    // On mobile Mainsail closes its drawer on route change; we don't change the route, so toggle
    // it with the app bar's menu button. (Vuetify ignores synthetic clicks on the overlay scrim.)
    // Only ever this exact element: the header's other buttons include EMERGENCY STOP.
    function closeMobileDrawer() {
        if (!document.querySelector(SELECTORS.mobileDrawerOpen)) return;
        var buttons = document.querySelectorAll(SELECTORS.drawerToggle);
        if (buttons.length === 1) buttons[0].click();
    }

    function activate() {
        ensureMounted();
        state.active = true;
        state.activeHref = location.href;
        document.documentElement.classList.add(ACTIVE_CLASS);
        setNavActive(true);
        closeMobileDrawer();
    }

    function deactivate() {
        if (!state.active) return;
        state.active = false;
        state.activeHref = null;
        document.documentElement.classList.remove(ACTIVE_CLASS);
        setNavActive(false);
    }

    // Mount (or re-mount after a Vue re-render removed our nodes). Idempotent.
    function ensureMounted() {
        var main = first(SELECTORS.main);
        if (!main) return false;

        ensureGlobalStyle();

        if (!document.getElementById(HOST_ID)) {
            var container = main.querySelector(SELECTORS.mainWrap) || main;
            container.appendChild(buildHost());
        }

        var navList = first(SELECTORS.navList);
        if (navList && !document.getElementById(NAV_ID)) {
            var item = buildNavItem(navList);
            if (item) navList.appendChild(item);
            if (state.active) setNavActive(true);
        }

        var fb = document.getElementById(FALLBACK_ID);
        if (document.getElementById(NAV_ID)) {
            if (fb) fb.remove();
        } else if (!fb && Date.now() - state.startedAt > GIVE_UP_MS) {
            mountFallbackButton();
        }
        return true;
    }

    // Used only if Mainsail's sidebar can no longer be found (e.g. a major UI rewrite).
    function mountFallbackButton() {
        var btnHost = document.createElement('div');
        btnHost.id = FALLBACK_ID;
        btnHost.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483000';
        var root = btnHost.attachShadow({ mode: 'open' });
        root.innerHTML =
            '<style>button{font:600 13px system-ui,sans-serif;padding:8px 14px;border-radius:18px;' +
            'border:0;background:#2b6cb0;color:#fff;cursor:pointer}</style><button>CommunityCAD</button>';
        root.querySelector('button').addEventListener(
            'click',
            guard(function () {
                state.active ? deactivate() : activate();
            })
        );
        document.body.appendChild(btnHost);
        log('sidebar not found, using fallback button');
    }

    // Mainsail mutates the DOM constantly (temperatures, console), so coalesce to one check per frame.
    var scheduled = false;
    function scheduleCheck() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(function () {
            scheduled = false;
            onMutation();
        });
    }

    var onMutation = guard(function () {
        // Any Mainsail navigation (router-link, programmatic push, back/forward) changes the URL.
        if (state.active && location.href !== state.activeHref) deactivate();
        ensureMounted();
    });

    var onDocumentClick = guard(function (ev) {
        if (!state.active) return;
        var a = ev.target && ev.target.closest ? ev.target.closest('nav a') : null;
        // Clicking Mainsail's own item for the current route doesn't change the URL, so handle it here.
        if (a && !a.closest('#' + NAV_ID)) deactivate();
    });

    var start = guard(function () {
        if (!document.getElementById('app')) return; // not a Mainsail page (e.g. a proxied webcam page)
        ensureMounted();
        state.observer = new MutationObserver(guard(scheduleCheck));
        state.observer.observe(document.body, { childList: true, subtree: true });
        document.addEventListener('click', onDocumentClick, true);
        window.addEventListener('popstate', onMutation);
        setTimeout(scheduleCheck, GIVE_UP_MS + 500); // make sure the fallback check runs even on a quiet page
        log('loaded', VERSION);
    });

    guard(function () {
        if (window.__communitycad) return;
        window.__communitycad = { version: VERSION, activate: guard(activate), deactivate: guard(deactivate) };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
        else start();
    })();
})();
