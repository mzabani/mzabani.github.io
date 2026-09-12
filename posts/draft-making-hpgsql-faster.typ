#let title = "Making hpgsql a lot faster"
#let subtitle = "Posted on ???????"
#let body = [
This article covers how I made #link("https://github.com/mzabani/hpgsql")[hpgsql], a PostgreSQL driver library written in pure Haskell, a lot faster when decoding rows.

Benchmarks materializing $100000$ rows with 13 columns, 20 times over in total but with 2 parallel connections running each 10 queries, all of it into Haskell records with strict fields, then garbage-collecting, went from:

`--- Benchmark hpgsql Record Stream (100000 rows): Wall time=1.288 s, total Haskell (does not include C heap) memory allocated=10314.5 MB.`

to:

???

= From 1.xx seconds down to 1.yy seconds


= From 1.yy seconds down to 1.zz seconds

= From 1.zz seconds down to 1.uu seconds
