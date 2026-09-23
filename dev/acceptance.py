"""Browser acceptance tests for the CommunityCAD Mainsail injection spike.

Drives headless Chromium (Playwright) against the dev harness on 127.0.0.1:8088.
127.0.0.1 is a secure context, so Mainsail's service worker really installs here.

    python dev/acceptance.py            # expects harness running with Mainsail installed, plugin NOT installed
Writes evidence to dev/evidence/ and prints a PASS/FAIL line per check.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://127.0.0.1:8088")
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
EVIDENCE = HERE / "evidence"
EVIDENCE.mkdir(exist_ok=True)
TAG = os.environ.get("TAG", "run")

results = []


def check(name, ok, detail=""):
    results.append({"check": name, "pass": bool(ok), "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)


def sh(cmd):
    env_lines = subprocess.run([str(HERE / "harness.sh"), "env"], capture_output=True, text=True).stdout
    return subprocess.run(["bash", "-c", env_lines + "\n" + cmd], capture_output=True, text=True, cwd=ROOT)


def install():
    r = sh("plugin/install.sh")
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def uninstall():
    r = sh("plugin/uninstall.sh")
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def set_sw_rule(enabled):
    """Toggle the sw.js rewrite in the installed server conf (control experiment for criterion A)."""
    r = sh(
        'f="$NGINX_DIR/communitycad/mainsail-server.conf"; '
        + ("sed -i 's|^#DISABLED# ||' \"$f\"" if enabled else "sed -i 's|^sub_filter \\$ccad_sw_match|#DISABLED# &|' \"$f\"")
        + " && $NGINX_RELOAD"
    )
    assert r.returncode == 0, r.stderr
    time.sleep(0.5)


STATE_JS = """() => {
  const host = document.getElementById('ccad-root');
  const panel = host && host.shadowRoot && host.shadowRoot.querySelector('.panel');
  const pc = document.getElementById('page-container');
  return {
    loaded: !!window.__communitycad,
    navItem: !!document.getElementById('ccad-nav-item'),
    navItemIndex: [...(document.querySelector('nav .v-list')?.children || [])].findIndex(e => e.id === 'ccad-nav-item'),
    navCount: document.querySelector('nav .v-list')?.children.length || 0,
    panelVisible: !!(panel && panel.getBoundingClientRect().height > 0),
    pageContainerVisible: !!(pc && pc.getBoundingClientRect().height > 0),
    fallback: !!document.getElementById('ccad-fallback-button'),
    swControlled: !!(navigator.serviceWorker && navigator.serviceWorker.controller),
    path: location.pathname,
    version: document.querySelector('meta[name=description]') ? 'ok' : '?',
  };
}"""


def state(page):
    return page.evaluate(STATE_JS)


def wait_app(page, timeout=20000):
    page.wait_for_selector("nav .v-list a.v-list-item", timeout=timeout)
    page.wait_for_timeout(800)


def wait_sw(page, timeout=20000):
    page.wait_for_function("() => navigator.serviceWorker && navigator.serviceWorker.controller", timeout=timeout)
    page.wait_for_function(
        "() => navigator.serviceWorker.ready.then(r => r.active && r.active.state === 'activated')", timeout=timeout
    )


def new_context(p, profile=None):
    profile = profile or tempfile.mkdtemp(prefix="ccad-profile-")
    ctx = p.chromium.launch_persistent_context(profile, headless=True, viewport={"width": 1280, "height": 720})
    return ctx, profile


def attach_console(page, sink):
    page.on("console", lambda m: sink.append(f"console.{m.type}: {m.text}") if m.type in ("error", "warning") else None)
    page.on("pageerror", lambda e: sink.append(f"pageerror: {e}"))


def hard_reload(page):
    cdp = page.context.new_cdp_session(page)
    with page.expect_navigation():
        cdp.send("Page.reload", {"ignoreCache": True})
    cdp.detach()


def loads_until(page, want_injected, max_loads=6):
    """Reload until injection presence == want_injected; return number of reloads needed (or None)."""
    for i in range(1, max_loads + 1):
        resp = page.reload()
        wait_app(page)
        s = state(page)
        if s["loaded"] == want_injected:
            return i, resp.from_service_worker
    return None, None


def click_nav(page, label):
    page.locator("nav .v-list a.v-list-item", has_text=label).first.click()
    page.wait_for_timeout(700)


# ---------------------------------------------------------------------------------------------


def test_A_and_C(p):
    errors_stock, errors_injected = [], []

    # Baseline console output for stock Mainsail (plugin not installed), same load sequence as below.
    ctx, _ = new_context(p)
    page = ctx.new_page()
    attach_console(page, errors_stock)
    page.goto(BASE + "/")
    wait_app(page)
    hard_reload(page)
    wait_app(page)
    wait_sw(page)
    page.reload()
    wait_app(page)
    page.goto(BASE + "/console")
    wait_app(page)
    for label in ["G-Code Files", "History", "Machine", "Console", "Dashboard"]:
        click_nav(page, label)
    ctx.close()

    install()

    # A1: first visit
    ctx, profile = new_context(p)
    page = ctx.new_page()
    attach_console(page, errors_injected)
    resp = page.goto(BASE + "/")
    wait_app(page)
    s = state(page)
    check("A1 first visit: script loads + nav item", s["loaded"] and s["navItem"], json.dumps(s))

    # A2: hard reload
    hard_reload(page)
    wait_app(page)
    s = state(page)
    check("A2 hard reload (ignoreCache)", s["loaded"] and s["navItem"], f"loaded={s['loaded']}")

    # A3: after SW install, a normal reload is served by the SW from its precache
    wait_sw(page)
    resp = page.reload()
    wait_app(page)
    s = state(page)
    check(
        "A3 reload served by service worker still injected",
        s["loaded"] and s["swControlled"] and resp.from_service_worker,
        f"from_service_worker={resp.from_service_worker} swControlled={s['swControlled']}",
    )
    resp = page.goto(BASE + "/console")
    wait_app(page)
    check("A3b deep link /console via SW still injected", state(page)["loaded"], f"from_service_worker={resp.from_service_worker}")

    # C: navigation round trip
    page.goto(BASE + "/")
    wait_app(page)
    page.screenshot(path=str(EVIDENCE / f"{TAG}-C0-dashboard.png"))
    click_nav(page, "CommunityCAD")
    s = state(page)
    page.screenshot(path=str(EVIDENCE / f"{TAG}-C1-ccad-view.png"))
    check("C1 open our view: panel shown, Mainsail page hidden, URL unchanged",
          s["panelVisible"] and not s["pageContainerVisible"] and s["path"] == "/", json.dumps(s))

    click_nav(page, "Console")
    s = state(page)
    console_ok = page.locator("#page-container input, #page-container textarea").count() > 0
    page.screenshot(path=str(EVIDENCE / f"{TAG}-C2-console.png"))
    check("C2 leave to Console: Mainsail routes + renders, panel hidden",
          s["path"] == "/console" and s["pageContainerVisible"] and not s["panelVisible"] and console_ok, json.dumps(s))

    click_nav(page, "CommunityCAD")
    s1 = state(page)
    page.go_back()
    page.wait_for_timeout(700)
    s2 = state(page)
    check("C3 come back to our view, then browser Back leaves it",
          s1["panelVisible"] and s2["pageContainerVisible"] and not s2["panelVisible"] and s2["path"] == "/",
          f"back->path={s2['path']}")

    click_nav(page, "Dashboard")  # now on '/'
    click_nav(page, "CommunityCAD")
    click_nav(page, "Dashboard")  # same route as current: URL does not change
    s = state(page)
    check("C4 clicking Mainsail item for the current route leaves our view",
          s["pageContainerVisible"] and not s["panelVisible"], json.dumps(s))

    for label in ["G-Code Files", "History", "Machine", "Console", "Dashboard"]:
        if page.locator("nav .v-list a.v-list-item", has_text=label).count():
            click_nav(page, label)
            click_nav(page, "CommunityCAD")
    s = state(page)
    check("C5 many round trips: exactly one nav item and one panel",
          page.locator("#ccad-nav-item").count() == 1 and page.locator("#ccad-root").count() == 1 and s["panelVisible"],
          f"navItemIndex={s['navItemIndex']}/{s['navCount']}")

    # Shadow DOM isolation, both directions
    iso = page.evaluate("""() => {
      const st = document.createElement('style');
      st.textContent = 'p, h2, .panel { color: rgb(1, 2, 3) !important; font-size: 50px !important; display: none !important; }';
      document.head.appendChild(st);
      const sr = document.getElementById('ccad-root').shadowRoot;
      const ours = getComputedStyle(sr.querySelector('p'));
      const r = { panelInset: Math.round(sr.querySelector('.panel').getBoundingClientRect().left - document.getElementById('ccad-root').getBoundingClientRect().left), ourFontSize: ours.fontSize, ourDisplay: ours.display, ourPanelDisplay: getComputedStyle(sr.querySelector('.panel')).display };
      st.remove();
      // our shadow stylesheet sets p{opacity:.85} and h2 margins; Mainsail's elements must not get them
      const theirs = [...document.querySelectorAll('p')].filter(x => !sr.contains(x));
      r.mainsailPOpacities = [...new Set(theirs.map(x => getComputedStyle(x).opacity))];
      return r;
    }""")
    check("C6 Shadow DOM isolation (page CSS doesn't reach panel; panel CSS doesn't reach page)",
          iso["ourFontSize"] == "14px" and iso["panelInset"] == 24 and iso["ourDisplay"] == "block" and "0.85" not in iso["mainsailPOpacities"],
          json.dumps(iso))

    ctx.close()

    def errs(lst):
        return [e for e in lst if not e.startswith("console.warning")]
    new_err = [e for e in errs(errors_injected) if e not in errs(errors_stock)]
    ours = [e for e in errors_injected if "communitycad" in e.lower()]
    warn_s = len(errors_stock) - len(errs(errors_stock))
    warn_i = len(errors_injected) - len(errs(errors_injected))
    check("C7 no new console errors vs stock Mainsail (same load sequence)", not new_err and not ours,
          f"errors stock={len(errs(errors_stock))} injected={len(errs(errors_injected))}; "
          f"warnings stock={warn_s} injected={warn_i} (see console.json); new={new_err[:3]} ours={ours[:3]}")
    (EVIDENCE / f"{TAG}-console.json").write_text(json.dumps({"stock": errors_stock, "injected": errors_injected}, indent=1))

    return profile


def test_A_service_worker_staleness(p):
    """The key PWA risk: a browser whose SW precached index.html BEFORE install/uninstall."""
    uninstall()

    # Control experiment: plugin installed WITHOUT the sw.js rewrite.
    ctx, _ = new_context(p)
    page = ctx.new_page()
    page.goto(BASE + "/")
    wait_app(page)
    wait_sw(page)
    install()
    set_sw_rule(False)
    n, from_sw = loads_until(page, True, max_loads=5)
    check("A4 control: WITHOUT sw.js rule, SW keeps serving stale stock index.html (expected to reproduce the bug)",
          n is None, f"injection appeared after {n} reloads" if n else "still stock after 5 reloads (bug reproduced)")
    set_sw_rule(True)
    n, from_sw = loads_until(page, True, max_loads=5)
    check("A5 WITH sw.js rule: pre-existing PWA picks up injection", n is not None and n <= 2,
          f"injected after {n} reload(s), served_from_sw={from_sw}")
    ctx.close()

    # Reverse: SW has cached the injected page, then uninstall.
    ctx, _ = new_context(p)
    page = ctx.new_page()
    page.goto(BASE + "/")
    wait_app(page)
    wait_sw(page)
    page.reload()
    wait_app(page)
    assert state(page)["loaded"]
    uninstall()
    n, from_sw = loads_until(page, False, max_loads=5)
    check("A6 after uninstall, pre-existing PWA returns to stock", n is not None and n <= 2,
          f"stock after {n} reload(s), served_from_sw={from_sw}")
    ctx.close()


def test_mobile(p):
    """Phone viewport: temporary drawer, extra logo item at the top of the nav list."""
    install()
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
    errs = []
    attach_console(page, errs)
    page.goto(BASE + "/")
    page.wait_for_timeout(3000)
    drawer_open = "() => document.querySelector('nav.v-navigation-drawer').classList.contains('v-navigation-drawer--open')"
    page.locator("header button.v-app-bar__nav-icon").click()
    page.wait_for_timeout(800)
    item = page.locator("#ccad-nav-item a")
    visible = item.is_visible() and "CommunityCAD" in item.text_content()
    item.click()
    page.wait_for_timeout(800)
    s = state(page)
    closed = not page.evaluate(drawer_open)
    page.screenshot(path=str(EVIDENCE / f"{TAG}-mobile-ccad-view.png"))
    page.locator("header button.v-app-bar__nav-icon").click()
    page.wait_for_timeout(800)
    click_nav(page, "Console")
    s2 = state(page)
    check("C8 phone viewport: item visible in drawer, opens panel, closes drawer, leaving works",
          visible and s["panelVisible"] and closed and s2["path"] == "/console" and not s2["panelVisible"] and not errs,
          f"itemVisible={visible} drawerClosed={closed} errors={errs[:2]}")
    b.close()


def test_failure_modes(p):
    """inject.js failures must never break Mainsail."""
    install()
    cases = {
        "syntax error": "this is not javascript (",
        "throws at top level": "throw new Error('boom from communitycad test');",
        "404": None,
        "selectors broken (sidebar gone)": "BROKEN_SELECTORS",
    }
    src = (ROOT / "plugin/web/inject.js").read_text()
    for name, body in cases.items():
        ctx, _ = new_context(p)
        page = ctx.new_page()
        errs = []
        attach_console(page, errs)
        if body is None:
            page.route("**/communitycad/inject.js", lambda r, *_: r.fulfill(status=404, body="nope"))
        elif body == "BROKEN_SELECTORS":
            b = src.replace("'nav.v-navigation-drawer .v-list', 'nav .v-list'", "'nav .does-not-exist'").replace(
                "GIVE_UP_MS = 20000", "GIVE_UP_MS = 1000")
            page.route("**/communitycad/inject.js", lambda r, *_, b=b: r.fulfill(status=200, content_type="application/javascript", body=b))
        else:
            page.route("**/communitycad/inject.js", lambda r, *_, body=body: r.fulfill(status=200, content_type="application/javascript", body=body))
        page.goto(BASE + "/")
        wait_app(page)
        page.wait_for_timeout(2500)
        click_nav(page, "Console")
        ok = page.url.endswith("/console") and page.locator("#page-container input, #page-container textarea").count() > 0
        s = state(page)
        extra = f"fallback_button={s['fallback']}" if body == "BROKEN_SELECTORS" else ""
        if body == "BROKEN_SELECTORS":
            page.screenshot(path=str(EVIDENCE / f"{TAG}-fallback.png"))
        check(f"F-mode inject.js {name}: Mainsail still navigates", ok and (s["fallback"] if body == "BROKEN_SELECTORS" else True),
              f"{extra} errors={[e[:80] for e in errs][:2]}")
        ctx.close()


def test_D_update(p, new_zip):
    """Mainsail update: replace release files, keep nginx config, with a PWA profile from the old version."""
    install()
    ctx, _ = new_context(p)
    page = ctx.new_page()
    page.goto(BASE + "/")
    wait_app(page)
    wait_sw(page)
    page.reload()
    wait_app(page)
    before = page.evaluate("() => fetch('/.version', {cache: 'no-store'}).then(r => r.text())")
    r = subprocess.run([str(HERE / "harness.sh"), "swap-mainsail", new_zip], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    import urllib.request
    html = urllib.request.urlopen(BASE + "/").read().decode()
    sw = urllib.request.urlopen(BASE + "/sw.js").read().decode()
    check("D1 after file swap (nginx untouched): served index.html + sw.js still rewritten",
          "/communitycad/inject.js" in html and 'revision:"ccad1-' in sw)
    n, _ = loads_until(page, True, max_loads=1)  # first reload may still be the old SW's copy
    for _ in range(3):
        page.reload()
        wait_app(page)
    after = page.evaluate("() => fetch('/.version', {cache: 'no-store'}).then(r => r.text())")
    s = state(page)
    click_nav(page, "CommunityCAD")
    s2 = state(page)
    click_nav(page, "Console")
    s3 = state(page)
    check("D2 existing PWA profile moves to new Mainsail version, injection + round trip work",
          before != after and s["loaded"] and s2["panelVisible"] and s3["pageContainerVisible"] and s3["path"] == "/console",
          f"{before.strip()} -> {after.strip()}")
    ctx.close()


def test_selectors(p):
    ctx, _ = new_context(p)
    page = ctx.new_page()
    page.goto(BASE + "/")
    wait_app(page)
    sel = page.evaluate("""() => {
      const q = s => !!document.querySelector(s);
      return {
        'nav.v-navigation-drawer .v-list': q('nav.v-navigation-drawer .v-list'),
        'nav .v-list': q('nav .v-list'),
        'nav a.v-list-item[href]': document.querySelectorAll('nav a.v-list-item[href]').length,
        '.v-list-item__title': q('nav .v-list-item__title'),
        'main#content': q('main#content'),
        'main .v-main__wrap': q('main .v-main__wrap'),
        '#page-container': q('#page-container'),
        '#app': q('#app'),
        vue2: !!(document.querySelector('#app') || {}).__vue__,
        vue3: !!(document.querySelector('#app') || {}).__vue_app__,
      };
    }""")
    check("G selectors present", all(sel[k] for k in ["nav.v-navigation-drawer .v-list", "main#content", "#page-container"]),
          json.dumps(sel))
    ctx.close()


if __name__ == "__main__":
    which = sys.argv[1:] or ["A", "C", "SW", "FAIL", "G"]
    with sync_playwright() as p:
        if "G" in which:
            test_selectors(p)
        if "A" in which or "C" in which:
            test_A_and_C(p)
        if "C" in which:
            test_mobile(p)
        if "SW" in which:
            test_A_service_worker_staleness(p)
        if "FAIL" in which:
            test_failure_modes(p)
        if "D" in which:
            test_D_update(p, os.environ["NEW_ZIP"])
    uninstall()
    (EVIDENCE / f"{TAG}-results.json").write_text(json.dumps(results, indent=1))
    print(f"\n{sum(r['pass'] for r in results)}/{len(results)} passed")
    sys.exit(0 if all(r["pass"] for r in results) else 1)
