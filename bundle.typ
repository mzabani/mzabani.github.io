#import "template.typ": page

#import "index.typ" as home
#import "posts/2017-06-22.typ" as p2017_06_22
#import "posts/2018-01-02.typ" as p2018_01_02
#import "posts/2018-02-27.typ" as p2018_02_27
#import "posts/2018-08-13.typ" as p2018_08_13
#import "posts/2024-02-04-splitting-expenses.typ" as p2024_02_04
#import "posts/2024-11-20-pg-what-serializable-isolation-really-means.typ" as p2024_11_20
#import "posts/2024-12-08-pg-ssi-limitations.typ" as p2024_12_08
#import "posts/2025-02-12-concurrently-forcing-haskell-streams.typ" as p2025_02_12

#let blog-title(title) = "Marcelo Zabani's Blog - " + title

#document("index.html", title: blog-title(home.title))[
  #page(title: home.title)[#home.body]
] <index>

#document("posts/2017-06-22.html", title: blog-title(p2017_06_22.title))[
  #page(title: p2017_06_22.title, subtitle: p2017_06_22.subtitle)[#p2017_06_22.body]
]

#document("posts/2018-01-02.html", title: blog-title(p2018_01_02.title))[
  #page(title: p2018_01_02.title, subtitle: p2018_01_02.subtitle)[#p2018_01_02.body]
]

#document("posts/2018-02-27.html", title: blog-title(p2018_02_27.title))[
  #page(title: p2018_02_27.title, subtitle: p2018_02_27.subtitle)[#p2018_02_27.body]
]

#document("posts/2018-08-13.html", title: blog-title(p2018_08_13.title))[
  #page(title: p2018_08_13.title, subtitle: p2018_08_13.subtitle)[#p2018_08_13.body]
]

#document("posts/2024-02-04-splitting-expenses.html", title: blog-title(p2024_02_04.title))[
  #page(title: p2024_02_04.title, subtitle: p2024_02_04.subtitle)[#p2024_02_04.body]
]

#document("posts/2024-11-20-pg-what-serializable-isolation-really-means.html", title: blog-title(p2024_11_20.title))[
  #page(title: p2024_11_20.title, subtitle: p2024_11_20.subtitle)[#p2024_11_20.body]
] <pg-serializable-isolation>

#document("posts/2024-12-08-pg-ssi-limitations.html", title: blog-title(p2024_12_08.title))[
  #page(title: p2024_12_08.title, subtitle: p2024_12_08.subtitle)[#p2024_12_08.body]
]

#document("posts/2025-02-12-concurrently-forcing-haskell-streams.html", title: blog-title(p2025_02_12.title))[
  #page(title: p2025_02_12.title, subtitle: p2025_02_12.subtitle)[#p2025_02_12.body]
]
