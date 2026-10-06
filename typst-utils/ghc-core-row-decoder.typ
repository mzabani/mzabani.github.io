#set page(width: 34cm, height: auto, margin: 1cm, fill: white)
#set text(font: "Libertinus Serif", size: 10.5pt)

#let blurred(it) = context {
  if target() == "html" {
    html.elem("span", attrs: (style: "filter: blur(2px); opacity: 0.55;"))[#it]
  } else {
    text(fill: gray.lighten(60%))[#it]
  }
}

#let codeOf(content, sharp) = {
  show raw.line: it => {
    if sharp.contains(it.number) { it } else { blurred(it) }
  }
  raw(content, lang: "hs", block: true)
}

#let card(body, caption: none) = context {
  if target() == "html" {
    html.elem("div", attrs: (style: "flex:1; min-width:0;"))[
      #if caption != none {
        html.elem("div", attrs: (
          style: "font-size:12px; font-weight:bold; color:#666; margin-bottom:6px;"
        ))[#caption]
      }
      #html.elem("div", attrs: (
        style: "background:#fafafa; border:1px solid #ddd;" +
               "border-radius:6px; padding:10px; font-size:13px; overflow-x:auto;"
      ))[#body]
    ]
  } else {
    block(
      width: 100%,
      {
        if caption != none {
          block(text(size: 8pt, weight: "bold", fill: gray, caption))
        }
        block(
          width: 100%,
          fill: rgb("#fafafa"),
          stroke: 0.5pt + rgb("#dddddd"),
          radius: 3pt,
          inset: 8pt,
          text(size: 8.3pt, body),
        )
      },
    )
  }
}

#let comparison(left, right) = context {
  if target() == "html" {
    html.elem("div", attrs: (
      class: "breakout",
      style: "display:flex; gap:14px; font-family: ui-monospace, monospace;"
    ))[
      #left
      #right
    ]
  } else {
    grid(
      columns: (1fr, 1fr),
      gutter: 10pt,
      left,
      right,
    )
  }
}
