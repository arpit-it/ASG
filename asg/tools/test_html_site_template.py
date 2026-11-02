# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Actual emitted-source/Chrome acceptance for the fixed HTML prerequisite.

No model code, packages or external requests. This does not validate production
creation consent, export, preview ownership, repair or a general HTML runner.
"""
import functools
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from html.parser import HTMLParser
from urllib.parse import urlsplit


class References(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.references = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for attr in ('src', 'href'):
            if attr in attrs:
                self.references.append(attrs[attr])


def check_references(folder):
    parser = References()
    parser.feed((folder / 'index.html').read_text())
    assert len(parser.ids) == len(set(parser.ids)), 'Duplicate HTML IDs'
    for value in parser.references:
        uri = urlsplit(value)
        assert not uri.scheme and not uri.netloc, 'Nonlocal asset/link'
        assert not uri.query, 'Unexpected query'
        if uri.path:
            target = (folder / uri.path).resolve()
            assert target.is_relative_to(folder.resolve()), 'Escaping asset'
            assert target.is_file(), 'Missing local asset'
        if uri.fragment:
            assert uri.fragment in parser.ids, 'Missing anchor'


HARNESS = r'''<!doctype html><html lang="en"><title>HTML acceptance</title>
<body><pre id="result">PENDING</pre><iframe title="Generated HTML" src="/site/index.html" style="border:0;width:1280px;height:900px"></iframe>
<script>
const frame = document.querySelector('iframe');
const result = document.getElementById('result');
function assert(value, message) { if (!value) throw Error(message); }
frame.addEventListener('load', async () => {
 try {
  const doc = frame.contentDocument, win = frame.contentWindow;
  assert(doc.title === 'Community garden <local> & friends', 'Plain-text title');
  assert(doc.querySelector('h1').textContent === doc.title, 'Semantic title');
  assert(doc.querySelector('.description').textContent.includes('Grow together.\nEditable'), 'Description');
  assert(doc.styleSheets.length === 1 && doc.styleSheets[0].cssRules.length > 15, 'Local CSS loaded');
  assert(Array.from(doc.images).every(i => i.complete && i.naturalWidth > 0), 'Local artwork loaded');
  const toggle = doc.getElementById('theme-toggle');
  assert(!toggle.hidden, 'Local JS loaded');
  toggle.focus(); assert(doc.activeElement === toggle, 'Keyboard focus target');
  toggle.click(); assert(toggle.getAttribute('aria-pressed') === 'true', 'Dark toggle');
  assert(win.getComputedStyle(doc.documentElement).colorScheme === 'dark', 'Dark style');
  assert(doc.getElementById('theme-status').textContent === 'Dark theme selected.', 'Live status');
  toggle.click(); assert(toggle.getAttribute('aria-pressed') === 'false', 'Light retry');
  assert(win.getComputedStyle(doc.documentElement).colorScheme === 'light', 'Light style');
  const details = doc.querySelector('details');
  doc.querySelector('summary').click(); assert(details.open, 'Native details interaction');
  for (const width of [1280, 320]) {
   frame.style.width = width + 'px';
   // Flush the parent layout, then distinguish viewport from content width.
   // Linux classic scrollbars consume space; macOS overlay scrollbars do not.
   assert(frame.getBoundingClientRect().width === width, 'Frame size applied');
   assert(win.innerWidth === width, 'Viewport applied');
   assert(doc.documentElement.scrollWidth <= doc.documentElement.clientWidth, 'No horizontal overflow');
   const cards = doc.querySelectorAll('article');
   const a = cards[0].getBoundingClientRect(), b = cards[1].getBoundingClientRect();
   assert(width === 320 ? b.top > a.top : b.left > a.left, 'Responsive cards');
   doc.documentElement.style.fontSize = '200%';
   assert(doc.documentElement.scrollWidth <= doc.documentElement.clientWidth, 'No overflow at 2x text');
   doc.documentElement.style.fontSize = '';
  }
  frame.style.width = '320px';
  doc.querySelector('.brand').lastChild.textContent = 'W'.repeat(120);
  doc.querySelector('h1').textContent = 'W'.repeat(120);
  doc.querySelector('.description').textContent = 'W'.repeat(2000);
  doc.documentElement.style.fontSize = '200%';
  assert(frame.getBoundingClientRect().width === 320 && win.innerWidth === 320, 'Maximum input viewport applied');
  assert(doc.documentElement.scrollWidth <= doc.documentElement.clientWidth, 'Bounded maximum text has no overflow');
  doc.querySelector('nav a').click();
  assert(win.location.hash === '#overview', 'Real anchor navigation');
  result.textContent = 'PASS: emitted HTML assets, semantics, focus, details, theme, navigation, 320/1280px and 2x text';
 } catch (error) { result.textContent = 'FAIL: ' + error.message; }
});
</script></body></html>'''


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def main():
    chrome = (os.environ.get('CHROME_EXECUTABLE') or shutil.which('google-chrome')
              or shutil.which('chromium')
              or '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    assert Path(chrome).is_file(), 'Chrome required for actual HTML acceptance'
    with tempfile.TemporaryDirectory(prefix='asg-html-') as temp:
        root = Path(temp)
        subprocess.run(['dart', 'run', 'tools/export_html_fixture.dart', str(root / 'site')],
                       check=True, timeout=60)
        check_references(root / 'site')
        # Missing assets and anchors must fail the check, independently of Chrome.
        mark = root / 'site/assets/mark.svg'
        original = mark.read_text()
        mark.unlink()
        try:
            check_references(root / 'site')
        except AssertionError:
            pass
        else:
            raise AssertionError('Missing asset accepted')
        mark.write_text(original)
        (root / 'index.html').write_text(HARNESS)
        server = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(Handler, directory=temp))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            run = subprocess.run([
                chrome, '--headless', '--disable-gpu', '--no-first-run',
                '--no-default-browser-check', '--disable-background-networking',
                f'--user-data-dir={root / "chrome"}', '--dump-dom',
                '--virtual-time-budget=5000',
                f'http://127.0.0.1:{server.server_port}/'],
                capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, 'Chrome failed'
            assert '<pre id="result">PASS:' in run.stdout, run.stdout[:12000]
            assert '[ERROR:CONSOLE' not in run.stderr, run.stderr
            print('PASS: actual emitted-source/Chrome acceptance; no product support claim')
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)


if __name__ == '__main__':
    main()
