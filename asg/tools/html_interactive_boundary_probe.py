# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Measure the limits of a browser-only HTML boundary with fixed local fixtures."""

import argparse
import json
import platform
import re
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

CANDIDATE_POLICY = (
    "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; "
    "connect-src 'none'; form-action 'none'; base-uri 'none'; "
    "frame-ancestors 'self'"
)

HOST = r"""<!doctype html>
<meta charset="utf-8">
<pre id="result"></pre>
<script>
const observations = {};
const result = document.querySelector('#result');
const record = (key, value) => {
  observations[key] = value;
  result.textContent = JSON.stringify(observations);
};
const frames = {};
const variant = new URL(location.href).searchParams.get('variant');
for (const name of ['apis', 'navigate', 'stop', 'keep']) {
  const frame = document.createElement('iframe');
  if (variant === 'candidate') frame.setAttribute('sandbox', 'allow-scripts');
  frame.src = '/child/' + variant + '/' + name;
  frames[name] = frame;
  document.body.appendChild(frame);
}
addEventListener('message', event => {
  const {name, phase, values} = event.data;
  if (!Object.hasOwn(frames, name) || event.source !== frames[name].contentWindow) return;
  record(name + '-' + phase, {origin: event.origin, values});
  if (name === 'stop' && phase === 'ready') {
    frames.stop.remove();
    record('stop-detached', !frames.stop.isConnected && frames.stop.contentWindow === null);
  }
});
</script>
"""

CHILD = r"""<!doctype html>
<meta charset="utf-8">
<button id="interaction">Increment</button>
<form action="__CANARY__/form" target="_blank" method="post"></form>
<script>
const name = location.pathname.split('/').pop();
const target = '__CANARY__';
const send = (phase, values) => parent.postMessage({name, phase, values}, '*');
const attempt = fn => {
  try { return fn(); } catch (error) { return error.name; }
};
if (name === 'apis') {
  let count = 0;
  const button = document.querySelector('button');
  button.onclick = () => { button.textContent = String(++count); };
  button.click();
  const values = {
    count: button.textContent,
    parent: attempt(() => Boolean(parent.document.querySelector('#result'))),
    localStorage: attempt(() => { localStorage.setItem('probe', '1'); return true; }),
    cookies: attempt(() => typeof document.cookie),
    indexedDB: attempt(() => { indexedDB.open('synthetic-probe'); return true; }),
    popup: Boolean(window.open(target + '/popup')),
    top: attempt(() => { top.location = target + '/top'; return 'requested'; })
  };
  // Target a popup so the permissive control can submit without losing this child.
  document.querySelector('form').submit();
  const img = new Image();
  img.src = target + '/image';
  fetch(target + '/fetch', {mode: 'no-cors'}).then(
    () => send('result', {...values, fetch: 'fulfilled'}),
    () => send('result', {...values, fetch: 'rejected'})
  );
}
if (name === 'navigate') {
  send('ready', {});
  location.href = target + '/self-navigation';
}
if (name === 'stop' || name === 'keep') {
  send('ready', {});
  setTimeout(() => {
    send('late', {});
    // With CSP this would be blocked anyway. The permissive run tests whether
    // detaching the child prevents a delayed observable request in this fixture.
    fetch(target + '/timer-' + name, {mode: 'no-cors'}).catch(() => {});
  }, 400);
}
</script>
"""


def endpoint(respond):
    """Bind an owned ephemeral loopback port for one fixture origin."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            pass

        def do_GET(self):
            body, policy = respond(urlsplit(self.path).path)
            self.send_response(200 if body is not None else 404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            if policy:
                self.send_header("Content-Security-Policy", policy)
            self.end_headers()
            if body is not None:
                self.wfile.write(body.encode())

        do_POST = do_GET

    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def run_fixture(chrome, variant):
    traffic = set()
    lock = threading.Lock()

    def canary(path):
        with lock:
            traffic.add(path)
        return "<!doctype html><title>Local canary</title>", None

    with endpoint(canary) as observer:
        origin = f"http://127.0.0.1:{observer.server_port}"

        def fixture(path):
            if path == "/":
                return HOST, None
            if re.fullmatch(rf"/child/{variant}/(apis|navigate|stop|keep)", path):
                policy = CANDIDATE_POLICY if variant == "candidate" else None
                # A cross-origin top navigation in the permissive control would
                # replace the host and lose the structured result. Its attempt is
                # tested only under the candidate's sandbox.
                child = CHILD if policy else CHILD.replace(
                    "top.location = target + '/top'; return 'requested';",
                    "return 'control-omitted';",
                )
                return child.replace("__CANARY__", origin), policy
            return None, None

        with endpoint(fixture) as host, tempfile.TemporaryDirectory(
            prefix="asg-html-boundary-"
        ) as profile:
            servers = (observer, host)
            workers = [
                threading.Thread(target=server.serve_forever, daemon=True)
                for server in servers
            ]
            for worker in workers:
                worker.start()
            try:
                process = subprocess.run(
                    [
                        chrome,
                        "--headless",
                        "--disable-background-networking",
                        "--disable-component-update",
                        # Let the sandbox, rather than popup heuristics, deny the fixture.
                        "--disable-popup-blocking",
                        "--no-first-run",
                        "--no-default-browser-check",
                        f"--user-data-dir={profile}",
                        "--virtual-time-budget=2500",
                        "--dump-dom",
                        f"http://127.0.0.1:{host.server_port}/?variant={variant}",
                    ],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=25,
                )
            finally:
                for server in servers:
                    server.shutdown()
                for worker in workers:
                    worker.join(timeout=2)

    match = re.search(r'<pre id="result">([^<]*)</pre>', process.stdout)
    if match is None:
        raise RuntimeError(f"{variant}: Chrome did not return the host observation")
    return {"browser": json.loads(match[1]), "canary_paths": sorted(traffic)}


def assess(results):
    candidate = results["candidate"]
    control = results["permissive"]
    candidate_browser = candidate["browser"]
    control_browser = control["browser"]
    denied = candidate_browser.get("apis-result", {})
    permitted = control_browser.get("apis-result", {})
    isolated_values = denied.get("values", {})
    control_values = permitted.get("values", {})
    candidate_traffic = set(candidate["canary_paths"])
    control_traffic = set(control["canary_paths"])
    return {
        "interactive_counter": isolated_values.get("count") == "1",
        "opaque_origin_and_storage": denied.get("origin") == "null"
        and all(
            isolated_values.get(key) == "SecurityError"
            for key in ("parent", "localStorage", "cookies", "indexedDB")
        )
        and permitted.get("origin", "").startswith("http://127.0.0.1:")
        and all(control_values.get(key) is True for key in ("parent", "localStorage", "indexedDB"))
        and control_values.get("cookies") == "string",
        "fetch_image_and_form_blocked": isolated_values.get("fetch") == "rejected"
        and control_values.get("fetch") == "fulfilled"
        and {"/fetch", "/image", "/form"} <= control_traffic
        and not {"/fetch", "/image", "/form"} & candidate_traffic,
        "popup_and_top_blocked": isolated_values.get("popup") is False
        and control_values.get("popup") is True
        and isolated_values.get("top") == "SecurityError"
        and "/popup" in control_traffic
        and not {"/popup", "/top"} & candidate_traffic,
        "self_navigation_escape_reproduced": candidate_browser.get("navigate-ready", {}).get("origin") == "null"
        and "/self-navigation" in candidate_traffic,
        "stop_detach_fixture": all(
            browser.get("stop-detached") is True
            and "stop-ready" in browser
            and "stop-late" not in browser
            for browser in (candidate_browser, control_browser)
        )
        and "keep-late" in control_browser
        and "/timer-keep" in control_traffic
        and "/timer-stop" not in control_traffic,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", required=True, type=Path, help="installed Chrome executable")
    args = parser.parse_args()
    chrome = str(args.chrome.resolve(strict=True))
    version = subprocess.run(
        [chrome, "--version"], capture_output=True, text=True, timeout=5, check=True
    ).stdout.strip()
    results = {variant: run_fixture(chrome, variant) for variant in ("candidate", "permissive")}
    checks = assess(results)
    print(json.dumps({
        "browser_version": version,
        "host": platform.platform(),
        "checks": checks,
        "observations": results,
        "production_decision": "reject-browser-only-candidate",
    }, indent=2, sort_keys=True))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
