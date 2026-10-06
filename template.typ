// Shared page template for the Typst-generated HTML site.
// Styling lives entirely here (in the <style> block) rather than in
// external CSS files - this replaces css/default.css and css/syntax.css.

#let style = "
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --fg: #1a1a1a;
  --muted: #666666;
  --border: #dddddd;
  --code-bg: #f5f5f5;
  --link: #0056b3;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c;
    --fg: #e6e6e6;
    --muted: #9a9a9a;
    --border: #3a3d42;
    --code-bg: #1f2226;
    --link: #6cb2ff;
  }
}
* { box-sizing: border-box; }
body {
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif;
  line-height: 1.6;
  max-width: 720px;
  margin: 0 auto;
  padding: 0 1.25rem;
}
a { color: var(--link); }
header {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  border-bottom: 2px solid var(--fg);
  margin-bottom: 2rem;
  padding: 1rem 0;
}
header .logo a { font-weight: bold; font-size: 1.1rem; text-decoration: none; color: var(--fg); }
header nav a { margin-left: 1rem; text-decoration: none; font-weight: bold; text-transform: uppercase; font-size: 0.9rem; color: var(--fg); }
h1 { font-size: 2rem; margin-bottom: 0.25rem; }
h2 { font-size: 1.6rem; margin-top: 2rem; }
h3 { font-size: 1.3rem; }
.info { color: var(--muted); font-size: 0.85rem; font-style: italic; margin-bottom: 1.5rem; }
pre {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.75rem 1rem;
  overflow-x: auto;
  font-size: 0.85rem;
}
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
p code, li code { background: var(--code-bg); padding: 0.1em 0.3em; border-radius: 4px; }
table { border-collapse: collapse; margin: 1.5rem 0; width: 100%; }
table, th, td { border: 1px solid var(--border); }
th, td { padding: 0.5rem 0.75rem; text-align: left; vertical-align: top; }
ul#post-list li { margin-bottom: 0.5rem; }
footer {
  border-top: 2px solid var(--border);
  color: var(--muted);
  font-size: 0.8rem;
  margin-top: 3rem;
  padding: 1rem 0;
  text-align: right;
}
section[role=\"doc-endnotes\"] { border-top: 1px solid var(--border); margin-top: 2rem; padding-top: 0.5rem; font-size: 0.9rem; color: var(--muted); }
.breakout {
  box-sizing: border-box;
  width: 100vw;
  max-width: 1200px;
  padding: 0 1.25rem;
  position: relative;
  left: 50%;
  transform: translateX(-50%);
}
@media (max-width: 768px) {
  .breakout {
    width: 100%;
    max-width: 100%;
    position: static;
    left: auto;
    transform: none;
  }
}
nav[role=\"doc-toc\"] {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.75rem 1.25rem;
  margin: 1.5rem 0;
}
nav[role=\"doc-toc\"] ol { margin: 0.25rem 0; padding-left: 1.25rem; }
nav[role=\"doc-toc\"] > ol { padding-left: 0; }
nav[role=\"doc-toc\"] li { margin: 0.25rem 0; }
nav[role=\"doc-toc\"] a { text-decoration: none; }
nav[role=\"doc-toc\"] a:hover { text-decoration: underline; }
.hover-tip { position: relative; }
.hover-tip .tip-trigger {
  border-bottom: 1px dotted var(--muted);
  cursor: help;
}
.hover-tip .tip-popup {
  display: none;
  position: absolute;
  left: 0;
  bottom: 125%;
  background: var(--bg);
  color: var(--fg);
  border: 1px solid var(--border);
  padding: 0.35rem 0.6rem;
  border-radius: 4px;
  font-size: 0.85rem;
  line-height: 1.4;
  white-space: normal;
  width: max-content;
  max-width: 320px;
  box-shadow: 0 2px 6px rgba(0, 0, 0, 0.15);
  z-index: 10;
}
.hover-tip:hover .tip-popup { display: block; }
"

// tip() attaches a hover tooltip to a piece of text. sig is rendered as
// a hidden sibling element shown on hover, so it can be arbitrary content
// (styled code, links, multiple lines) rather than just a plain string.
#let tip(body, sig) = context {
  if target() == "html" {
    html.elem("span", attrs: ("class": "hover-tip"))[
      #html.elem("span", attrs: ("class": "tip-trigger"))[#body]
      #html.elem("span", attrs: ("class": "tip-popup"))[#sig]
    ]
  } else {
    body
  }
}

// <index> is the label attached to the home page's #document(..) call in
// bundle.typ - linking through it (instead of a literal "../" path) lets
// Typst resolve the right relative href from any page's depth.
#let page(title: "", subtitle: none, body) = {
  set raw(theme: "/code-theme.tmTheme")
  html.elem("style", style)
  html.elem("header")[
    #html.elem("span", attrs: (class: "logo"))[#link(<index>)[Marcelo Zabani's Blog]]
    #html.elem("nav")[#link(<index>)[Home]]
  ]
  html.elem("main")[
    #html.elem("h1")[#title]
    #if subtitle != none [
      #html.elem("div", attrs: (class: "info"))[#subtitle]
    ]
    #body
  ]
}
