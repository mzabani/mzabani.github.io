#let title = "Home"
#let body = [
= Welcome

This is just one more software development blog, with a bit more Haskell than other things.

Older posts are on my Wordpress at #link("https://mzabani.wordpress.com/")[#"https://mzabani.wordpress.com/"]

= Posts

#html.elem("ul", attrs: (id: "post-list"))[
  #html.elem("li")[#link("./posts/2025-02-12-concurrently-forcing-haskell-streams.html")[Concurrently processing streams in Haskell] - February 12, 2025]
  #html.elem("li")[#link("./posts/2024-12-08-pg-ssi-limitations.html")[Limitations of SSI's implementation in PostgreSQL] - December 8, 2024]
  #html.elem("li")[#link("./posts/2024-11-20-pg-what-serializable-isolation-really-means.html")[What Serializable isolation really means in PostgreSQL] - November 20, 2024]
  #html.elem("li")[#link("./posts/2024-02-04-splitting-expenses.html")[Algorithms to split group expenses] - February 4, 2024]
  #html.elem("li")[#link("./posts/2018-08-13.html")[Typeclass induction and developing a QuickCheck-like library] - August 13, 2018]
  #html.elem("li")[#link("./posts/2018-02-27.html")[Investment strategies, lazy evaluation and memoization] - February 27, 2018]
  #html.elem("li")[#link("./posts/2018-01-02.html")[One equality operator to rule them all] - January 2, 2018]
  #html.elem("li")[#link("./posts/2017-06-22.html")[Interfaces and typeclasses: Number APIs in C\# and Haskell] - June 22, 2017]
]
]
