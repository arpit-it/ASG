// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../../models/html/html_site_input.dart';

/// Fixed editable web sources only. No filesystem writes, model code, tool
/// execution, readiness or creation permission. Host integration is pending.
class HtmlSiteTemplate {
  static const adapterId = 'asg-static-html-v1';

  Map<String, String> generate(HtmlSiteInput input) {
    const escape = HtmlEscape(HtmlEscapeMode.element);
    final title = escape.convert(input.title);
    final description = escape.convert(input.description);
    return Map.unmodifiable({
      'index.html':
          '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title</title>
  <link rel="icon" href="assets/mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="styles.css">
  <script src="app.js" defer></script>
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header">
    <a class="brand" href="#main"><img src="assets/mark.svg" width="32" height="32" alt="">$title</a>
    <nav aria-label="Main navigation"><a href="#overview">Overview</a><a href="#details">Details</a></nav>
  </header>
  <main id="main" tabindex="-1">
    <section class="hero" aria-labelledby="site-title">
      <p class="eyebrow">Your independent web project</p>
      <h1 id="site-title">$title</h1>
      <p class="description">$description</p>
      <a class="primary-link" href="#overview">Explore this project <span aria-hidden="true">→</span></a>
    </section>
    <section id="overview" class="section" aria-labelledby="overview-title">
      <h2 id="overview-title">A place to start</h2>
      <div class="cards">
        <article><span class="number" aria-hidden="true">01</span><h3>Make it yours</h3><p>Edit the semantic content in index.html to describe your project.</p></article>
        <article><span class="number" aria-hidden="true">02</span><h3>Shape the experience</h3><p>Adjust the shared colors, spacing and responsive layout in styles.css.</p></article>
        <article><span class="number" aria-hidden="true">03</span><h3>Keep it local</h3><p>The included artwork and script are local files. No hosted fonts or frameworks are required.</p></article>
      </div>
    </section>
    <section id="details" class="section details" aria-labelledby="details-title">
      <h2 id="details-title">Project details</h2>
      <details><summary>How do I edit this site?</summary><p>Open the source files in an editor. Serve this folder locally to preview changes in a browser. See README.md for the template boundary.</p></details>
      <button id="theme-toggle" type="button" aria-pressed="false" hidden>Use dark theme</button>
      <p id="theme-status" role="status" aria-live="polite"></p>
      <noscript><p>The site works without JavaScript; the optional theme control requires it.</p></noscript>
    </section>
  </main>
  <footer><p>Independent HTML, CSS and JavaScript source.</p><a href="#main">Back to top</a></footer>
</body>
</html>
''',
      'styles.css': _styles,
      'app.js': _script,
      'assets/mark.svg': _mark,
      'README.md':
          '''# Static HTML starter

Adapter: $adapterId. Fixed template, not arbitrary source synthesis.

Edit index.html, styles.css, app.js and assets/mark.svg directly. There are no
package dependencies, build step, remote assets or hosted fonts. Serve the
folder with a local static HTTP server and open its loopback URL. Do not use
this template as permission to execute unknown source or expose a public server.

The title and description are plain text. Navigation, native expandable details
and the optional theme button are examples, not user-specific functionality.
No form submits data, no analytics run and no network API is contacted.

This source-template prerequisite does not enable ASG project creation,
approval-bound execution, export, preview lifecycle or repair for HTML. Those
integrations remain pending; HTML stays Planned in the creation wizard.
''',
    });
  }
}

const _styles = '''/* Local, dependency-free responsive theme. */
:root { color-scheme: light; --bg: #f6f5f0; --panel: #ffffff; --ink: #192c30; --muted: #425b60; --accent: #075e54; --line: #bccac7; }
:root[data-theme="dark"] { color-scheme: dark; --bg: #102327; --panel: #19353a; --ink: #f0f7f4; --muted: #c0d2ce; --accent: #89e3ca; --line: #536e71; }
* { box-sizing: border-box; }
html { scroll-padding-top: 1rem; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 1rem/1.65 system-ui, sans-serif; }
a { color: var(--accent); text-underline-offset: .25em; }
a:hover { text-decoration-thickness: .15em; }
a:focus-visible, button:focus-visible, summary:focus-visible { outline: 3px solid var(--accent); outline-offset: 5px; }
.site-header, main, footer { width: min(100% - 2rem, 72rem); margin-inline: auto; }
.site-header { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 1rem; padding-block: 1.5rem; border-bottom: 1px solid var(--line); }
.brand { display: flex; align-items: center; gap: .75rem; font-weight: 750; text-decoration: none; max-width: 100%; overflow-wrap: anywhere; }
.brand img { flex-shrink: 0; }
nav { display: flex; flex-wrap: wrap; gap: 1.5rem; }
nav a, button, summary, .primary-link { min-height: 44px; display: inline-flex; align-items: center; }
.hero { padding-block: clamp(3rem, 8vw, 7rem); max-width: 56rem; }
.eyebrow { text-transform: uppercase; font-size: .8rem; letter-spacing: .12em; font-weight: 750; color: var(--muted); }
h1, h2, h3 { line-height: 1.15; overflow-wrap: anywhere; }
h1 { font-size: clamp(2.25rem, 7vw, 5rem); letter-spacing: -.04em; margin-block: .75rem 1.5rem; }
h2 { font-size: clamp(1.6rem, 4vw, 2.4rem); }
h3 { font-size: 1.3rem; }
.description { font-size: 1.2rem; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; }
.primary-link { gap: 1rem; font-weight: 700; margin-top: 1rem; }
.section { padding-block: 2.5rem; border-top: 1px solid var(--line); }
.cards { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 1.25rem; }
article { padding: 1.5rem; background: var(--panel); border: 1px solid var(--line); border-radius: 1rem; overflow-wrap: anywhere; }
.number { color: var(--accent); font-weight: 750; }
article p { color: var(--muted); }
.details { max-width: 54rem; }
summary { cursor: pointer; font-weight: 700; display: list-item; padding-block: .75rem; }
button { cursor: pointer; border: 2px solid var(--accent); border-radius: .5rem; background: var(--panel); color: var(--ink); padding: .6rem 1rem; font: inherit; margin-top: 1rem; }
[hidden] { display: none !important; }
footer { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 1rem; padding-block: 2rem; border-top: 1px solid var(--line); color: var(--muted); }
.skip-link { position: absolute; left: 1rem; top: -10rem; background: var(--panel); padding: 1rem; z-index: 1; }
.skip-link:focus { top: 1rem; }
@media (max-width: 48rem) { .cards { grid-template-columns: 1fr; } .hero { padding-block: 3rem; } }
@media (prefers-reduced-motion: no-preference) { a, button { transition: background-color .15s ease; } }
''';

const _script = ''''use strict';
// Fixed local interaction. User text is never interpolated into script.
const toggle = document.getElementById('theme-toggle');
const status = document.getElementById('theme-status');
if (toggle && status) {
  toggle.hidden = false;
  toggle.addEventListener('click', () => {
    const dark = toggle.getAttribute('aria-pressed') !== 'true';
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    toggle.setAttribute('aria-pressed', String(dark));
    toggle.textContent = dark ? 'Use light theme' : 'Use dark theme';
    status.textContent = dark ? 'Dark theme selected.' : 'Light theme selected.';
  });
}
''';

const _mark = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#075e54"/><path d="M8 23 16 8l8 15h-5l-3-6-3 6Z" fill="#fff"/></svg>
''';
