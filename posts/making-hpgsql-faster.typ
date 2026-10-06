#let title = "Closing the performance gap between hpgsql (Haskell) and tokio-postgres (Rust)"
#let subtitle = "Posted on 2026-11-15"
#import "../typst-utils/ghc-core-row-decoder.typ": comparison, card, codeOf
#import "../template.typ": tip
#let body = [
#[] <hpgsql-toc-start>
This article covers how I made #link("https://github.com/mzabani/hpgsql")[hpgsql], a PostgreSQL driver library written in pure Haskell, a lot faster when decoding rows.

Benchmarks decoding 2 million rows with 17 columns, all into Haskell records, then garbage-collecting, went from _2.26s_ down to _1.139s_, a bit faster than .NET's Npgsql's _1.167s_ and \~10% slower than the _1.032s_ of Rust's tokio-postgres on the same benchmark. The exact benchmarking methodology is better #link("https://github.com/mzabani/hpgsql/blob/master/BENCHMARKS.md")[described here].

It's important to say that I think this is a reasonable benchmark, but there is another reasonable benchmark (that materializes rows into collections instead of just streaming them) where hpgsql is \~3x _slower_ than Npgsql and tokio-postgres. Keep reading to find out more.

The performance work which I cover partially here spanned \~6 months, and my hope is that this is an interesting read, but mostly that I can contribute back to the Haskell community by sharing my experience with some of my failed attempts at improving performance, and why not some of the successful ones, too.

From #link("https://github.com/mzabani/hpgsql/pull/26")[internal batching], to #link("https://github.com/mzabani/hpgsql/pull/43")[replacing dependencies] with my own implementations, to finding #link("https://github.com/mzabani/hpgsql/pull/44")[inlining opportunities], #link("https://github.com/mzabani/hpgsql/pull/61")[strictness annotations] and bigger refactors pulling a custom #link("https://github.com/mzabani/hpgsql/pull/56")[PinnedByteArray parser up the row decoding pipeline], this post will describe some of the optimizations that got us there, where we still fall short of Npgsql and tokio-postgres, and present ideas and ask questions as we go.

#outline(
  title: none,
  indent: auto,
  target: heading.where().after(<hpgsql-toc-start>).before(<hpgsql-toc-end>),
)

= Some wins first

== hpgsql's advantage to postgresql-simple, and APIs

When compared to postgresql-simple, both hpgsql and hasql have at least one advantage: their row decoders are not Monads, only Applicatives.

To understand what that means, look at the following hypothetical row decoder:

```haskell
rowDecoder :: RowDecoder (Text, Int, Bool)
rowDecoder = do
  textField <- field @Text
  intField <- field @Int
  -- This will look non-sensical, but it's on purpose
  lastField <- if intField > 10 then (== 4) <$> field @Int else field @Bool
  pure (textField, intField, lastField)
```

That last field is a query result's column, and given a single query it can only have one type. Yet, with a monadic row decoder, the code above is perfectly valid.

The way I understand this is that if row decoders are Monads, libraries are forced to do one of:
- Type-check fields for every row, instead of once per query, which is no small price to pay.
- Type-check fields once per query and assume we won't write such obviously broken monads, with risks to decoding correctness.

== Haskell libraries' advantage to Npgsql (.NET) and tokio-postgres (Rust)

The APIs for Npgsql and tokio-postgres both look something like this:

```cs
textField = reader.GetText(0);
intField = reader.GetInt32(1);
boolField = reader.GetBoolean(2);
return new { textField, intField, lastField };
```

This might look innocent, but every row returned by PostgreSQL uses variable-length encoding for its fields. That first text field can have arbitrary length, and NULLs don't take any bytes in the row (except for a four byte-long $-1$ value to indicate a `NULL` coming next).

So fetching the $n$th field is $O(n)$, and thus fetching each row is quadratic in the number of fields.

This looks like a lower-level API than directly decoding rows into user-defined types, but it actually imposes additional cost.

To be fair, I don't know how much this actually costs, but I found it interesting enough to mention.

Hpgsql parses every row's fields in linear time in the number of fields, and I don't know how postgresql-simple and hasql are implemented, but I believe they too could do this in case they already don't.

And lastly, this has the same downside as Monadic row decoders, which is that every field must be type-checked in every row, or else there might be correctness issues.

== Trusting Postgres, to some extent

Trusting Postgres' output allows some performance optimizations in hpgsql:

- We trust Postgres to encode UTF8 correctly to avoid `decodeUtf8` when producing `Text` values (hpgsql forces client_encoding=UTF8).
- We also trust it to produce valid JSON in `PgJson` and other types/instances to avoid the cost of checking JSON validity.

As I see it, these are no different than trusting Postgres to encode any other type, including integers, booleans, characters, etc.

But we don't trust Postgres enough to do things that could lead to out-of-bounds access. That means hpgsql always checks bounds before reading from our internal buffers. It's not clear how much faster we'd be if we trusted Postgres enough to omit bounds checks, but it's not something I want for hpgsql.

= ByteStrings, `unsafePerformIO` and unnecessary boxing

At some point I implemented my own `PinnedByteArray` type instead of using `ByteString`. The need for it was only discovered by looking at GHC Core. At the time, my decoders used #tip[#link("https://hackage.haskell.org/package/base/docs/System-IO-Unsafe.html#v:unsafePerformIO")[unsafeDupablePerformIO]][unsafeDupablePerformIO :: IO a -> a] so they could #tip[#link("https://hackage.haskell.org/package/base/docs/Foreign-Storable.html#v:peek")[peek]][peek :: Storable a => Ptr a -> IO a] directly into the ByteString in pure code, and that had very surprising consequences to me.

The problem was that `unsafeDupablePerformIO` (and its variants like `unsafePerformIO`) uses the #tip[#link("https://hackage.haskell.org/package/base/docs/GHC-Base.html#v:lazy")[lazy]][lazy :: a -> a] function, which imposes an optimization fence to GHC's inliner. This fence was boxing every peeked `Word32#` into a `Word32` before decoding it into e.g. an `Int`. That is unnecessary boxing, as ideally we'd go from `Word32#` directly to `Int`.

`ByteString` is a `ForeignPtr Word8` under the hood, and I then wondered why #tip[#link("https://hackage.haskell.org/package/base/docs/Foreign-ForeignPtr.html#v:withForeignPtr")[withForeignPtr]][withForeignPtr :: ForeignPtr a -> (Ptr a -> IO b) -> IO b] needs to run in `IO` if it's just peeking into memory positions. The docs say that "The foreign object is kept alive at least during the whole action", which is maybe the reason why.

This surprised me very much since `ByteString` is an ecosystem default, and since so much code uses it to decode it into something else. So IIUC there's no way to write a byte-peeking decoder like hpgsql's without running into things like this with `ByteString`. But I hope I'm wrong about that, and I did consider one idea to keep `ByteString`, which you can see #link("https://github.com/mzabani/hpgsql/blob/3df8f34f1bbda0fa53b0ac985dc8bb58bd781342/hpgsql/src/Hpgsql/Internal/PinnedByteArray.hs#L38")[in a code comment].

My solution was to write my own `PinnedByteArray` type, using `ByteArray#` under the hood, and change networking and parsing code to use that instead. One can then use the less friendly, but pure, #tip[#link("https://hackage.haskell.org/package/base/docs/GHC-Base.html#v:indexWord8ArrayAsWord32-35-")[indexWord8ArrayAsWord32\#]][indexWord8ArrayAsWord32\# :: ByteArray\# -> Int\# -> Word32\#] and similar functions, to peek directly into buffers in pure code, and with that avoid boxing overhead.

It's not great that I had to reimplement so much code - I even had to introduce a `LazyPinnedByteArray` - and I wondered if backpack would've helped me switch from `bytestring` to a hypothetical `pinnedbytestring` module without changing my code all that much. Other libraries would've had to expose backpack support too, like `network` and `attoparsec` (I also had to create small parsing module for `PinnedByteArray`), and _even then_ I already have copies of `network`'s functions because I had to make them interruption-safe for my use, so it wouldn't work out of the box.

So it's all a bit messy, but I do think backpack support in the ecosystem would at least have made parts of my code unnecessary, and maybe I could upstream interruption-safety support to the `network` library and get rid of lots of code duplication I had to add.

So maybe this section is more about backpack than anything else. Stack recently announced it will support it, so it might be time for library authors to pick it up? hpgsql itself could leave the choice of streaming library to users, for example.

= Why is materializing List and Vector so slow?

Here's how long the same benchmark takes, changing only whether we stream the rows and discard them immediately (i.e. consume a `Stream (Of a) IO ()`), vs. store them in a list (i.e. produce a `IO [a]`):

- Streaming and discarding rows: 1.139s
- Materializing rows to a list:  3.057s

That's a 2.7x increase. .NET's Npgsql goes from 1.167s to 1.181s, and tokio-postgres goes from 1.032s to 1.092s.

I even tried materializing to a `Vector` with a mutable size-doubling `Vector` algorithm, just in case I had something wrong with List concatenation, but times didn't improve.

I double-checked that I'm forcing each individual record returned in the query, so *I don't know how to explain this.*

One thing that did occur to me is that it'd be great if I could use allocation primitives to allocate the returned list and its elements all in a compact region, but without the cost of copying. I'm not betting that would speed this up significantly, by the way.

With the compact region, someone might rightfully complain that the GC would keep objects alive a bit longer than necessary in some cases, but the functions that return `Stream` help avoid that, and you'd still be able to use `Streaming.toList_ :: Stream (Of a) IO () -> IO [a]` to get the more granular GC behaviour with a list if you want. 

And this is another thing I wish we did more in the Haskell community: we have wonderful streaming abstractions but it feels like we don't use them too much. Maybe it's too much library choice, so another problem for backpack to help solve?

= An experience report on inlining, CPS parsers, boxing, and representation polymorphism

This is the section I want to spend more time on. I really want hpgsql to be as fast as tokio-postgres, and to *try* that I want to remove as many allocations from hpgsql's decoding pipeline as I can.

I should mention that I have been able to remove all boxing from row decoding by inlining a lot of code, because then GHC can really do some magical transformations. It was nice to look at GHC Core and see only unboxed values going all the way down to Record constructors with strict fields. But the end result was _slower_ than the version that boxes. Maybe I made a mistake somewhere, or maybe it's a complex CPU cache and branch prediction issue given how enormous row decoders become when it's all inlined. In any case, the size of row decoders becomes too massive, and I don't want to impose that compilation cost on users of hpgsql.

== CPS parsers aren't always so great

Let's start my experience report by looking at a small record and go through my attempts to reduce boxing:

```haskell
data BestCaseScenarioRecord = BestCaseScenarioRecord
  { bcsId :: !Int,
    bcsDate :: !Day,
    bcsText :: !(Maybe Text)
  }

instance FromPgRow BestCaseScenarioRecord where
  rowDecoder = BestCaseScenarioRecord <$> fieldRowDecoder <*> fieldRowDecoder <*> fieldRowDecoder
```

Let's look at GHC Core for its row decoder, simplified by myself with Claude's help (asking Claude to humanize binding names in GHC Core makes reading GHC Core a lot easier and has been really helpful). Hopefully my simplifications aren't omitting important details:

#card(codeOf(read("making-hpgsql-faster/row-decoder-int-cps.ghc-core"), (2,8,12,13,15,19,20,22,26,27,30,31)))

If we look at all the boxing going on, you will find:
- `ByteStringIdx`, a newtyped `Int` under the hood, is allocated/boxed once per field for the continuations.
- We have one runtime closure allocated per field. These are the parser continuations for each successfully parsed field.
- The integer for the `bcsId` field would ideally be an `Int#` because strict record fields combined with #link("https://ghc.gitlab.haskell.org/ghc/doc/users_guide/using-optimisation.html#ghc-flag-funbox-small-strict-fields")[-funbox-small-strict-fields], turned on by default with `-O1`, means we're discarding the boxed `Int` anyway. If the other fields were small values like `Int`, `Bool`, the same would apply to them.

It took me a few months to realize that, well, CPS style is not so great unless code is sufficiently inlined. #link("https://github.com/mzabani/hpgsql/pull/63")[I changed my parser definition to return a strict equivalent of `Either String a` instead of being CPS], and *reduced total allocations in my benchmark from 9615MB to 5140MB*, gaining a \~4.7% speedup with it. Looking at GHC Core, it's easy to see it's not allocating closures anymore, replacing those allocations with the new `data ParseResult a = ParseFail !String | ParseOk !a !ByteStringIdx` objects. It doesn't seem to be an equivalent replacement, however, with CPS being not just more complicated code, but also slower.

Compare the GHC Core:
#comparison(
  card(codeOf(read("making-hpgsql-faster/row-decoder-int-cps.ghc-core"), (2,8,12,13,15,19,20,22,26,27,30,31)), caption: "CPS style"),
  card(codeOf(read("making-hpgsql-faster/row-decoder-int.ghc-core"), (1,2,5,6,7,9,10,11,13,14,15,16)), caption: "Direct style (no CPS)"),
)

It's much smaller without CPS, and maybe we did reduce some `I#` allocations due to `ParseOk !a !ByteStringIdx` having the `ByteStringIdx` unboxed+unpacked into the `ParseOk` value, but we can still see some `I#` allocations for the array offset, which is what we'll look at next.

Always good to benchmark.

== Trying (and failing?) to turn the array offset into an unboxed `Int#`

Next, I couldn't think how to avoid boxing the values of the record's fields, but I was adamant `ByteStringIdx` could just be an unboxed integer. If the decoder decodes an `int4`, it would call the next field parser with `(idx + 4)`, passed in the call stack.

But changing `newtype ByteStringIdx = ByteStringIdx Int` to `type ByteStringIdx = Int#` proved very invasive and difficult, at least with my Haskell skills. This was one of my first real experiences with representation polymorphism in GHC. I learned that I can make function arguments representation-polymorphic, but not data constructors' arguments. I wonder if that's because GHC doesn't monomorphize completely, but I thought why not monomorphize completely based on call sites in such cases? I imagine with class dictionaries and public functions with unknown call sites things might get more complicated, but compilers aren't my forte.

But also, even number functions like `+` and `-` don't work with unboxed integers because they're not representation-polymorphic. `Ord`'s comparison operators are the same. Number literals require a hash at the end, e.g. `4#` instead of `4`. Equality is #tip[#link("https://hackage.haskell.org/package/base/docs/GHC-Base.html#v:-61--61--35-")[==\#]][(==\#) :: Int\# -> Int\# -> Int\#] and it doesn't return a `Bool`, but rather an `Int#`.

In the end, that means switching between `Int` and `Int#` is not a quick experiment where you change a few lines of code; it's actually a bigger refactor.

Anyway, after replacing `Int` with `Int#` and being somewhat careful to avoid reboxing, performance improved \~4%, but a big surprise: total memory allocation _went up_ from 5140MB to 5900MB in benchmarks. I saw Richard Eisenberg mention this phenomenon in a video, but confusingly to me, GHC Core with the unboxed integer looks strictly better everywhere I looked.

Let's compare the row decoder with boxed and unboxed array offsets first:
#comparison(
  card(codeOf(read("making-hpgsql-faster/row-decoder-int.ghc-core"), (1,6,10)), caption: "Boxed Int"),
  card(codeOf(read("making-hpgsql-faster/row-decoder-int#.ghc-core"), (1,6,10)), caption: "Unboxed Int#"),
)

Look at all the `I#` constructions in the Boxed Int (left) version. Everything else is the same, so the Unboxed Int\# version should allocate strictly less.

Now let's pick a field decoder, as maybe those got worse. Let's look at the `Bool` decoder:

#comparison(
  card(codeOf(read("making-hpgsql-faster/bool-field-decoder-int.ghc-core"), (1,2,3,4,5,6,7,8,9,29,30,31,36,37,38)), caption: "Boxed Int"),
  card(codeOf(read("making-hpgsql-faster/bool-field-decoder-int#.ghc-core"), (1,7,8,9,29,30,31,36)), caption: "Unboxed Int#"),
)

I've emphasized the more interesting parts. First look at the top lines of the left version (boxed). There, `offset` is an `Int` that needs to be unboxed, and naturally callers of this must box an `Int`. The unboxed version also receives a `decodeBool` function that it uses to invoke parsing failure on a `NULL` value. The right version (unboxed) is a bit more direct.

It looks to me that the Unboxed Int\# version is strictly better.

So if both the row decoder and field decoders do strictly less boxing and are otherwise identical, how come the unboxed version allocates so much more? Maybe the field decoders for other types got worse; but an exhaustive comparison requires more effort than I want to put in right now.

Also, when I tried this with the CPS parser (instead of the simple parser), it's not just total allocated memory that got worse; performance got significantly worse, too.

#link("https://github.com/mzabani/hpgsql/pull/65")[I have not merged this change into hpgsql] as I'd rather wait until I better understand what's happening. This was tested with GHC 9.10.3 and -O1.

I was sadly unable to run with profiling on with my nixpkgs tooling. The next step is to analyze a heap profile.

== The dream optimizations working together

Lastly, after looking at GHC Core enough, I wondered if we could unbox at least the small fields, like `Int`. I considered extravagant ideas, but finally wondered about worker-wrapper transformations.

Let's look at the GHC Core for the row decoder for #tip[BestCaseScenarioRecord][
data BestCaseScenarioRecord = BestCaseScenarioRecord
  { bcsId :: !Int,
    bcsDate :: !Day,
    bcsText :: !(Maybe Text)
  }] one more time:

#raw(read("making-hpgsql-faster/row-decoder-int.ghc-core"), lang: "haskell", block: true)

Here's the dream, but do forgive me for possibly making assumptions about what a compiler might be able to do: worker-wrapper transformations produce unboxed equivalents of parsers, i.e. `Parser Int#` instead of `Parser Int`, and those get picked up by the compiler in the code above because they end up in a record with strict fields (so we'd see an `idValue# :: Int#` instead of `idValue :: Int` in the GHC Core above), at least when #link("https://ghc.gitlab.haskell.org/ghc/doc/users_guide/using-optimisation.html#ghc-flag-funbox-small-strict-fields")[-funbox-small-strict-fields] is on.

I imagine that might require quite a bit of work in representation polymorphism, and even then I won't be surprised if people tell me it's infeasible.

But it occurred to me. And if the dream goal is too far (is it?), maybe we could at least make representation polymorphism easier little by little? I found discussions which are well beyond my level of experience and expertise to judge, but from the immense complexity (to me) of tradeoffs and proposals, I wonder if we could at least gradually make more base classes and functions levity-polymorphic or even completely representation-polymorphic, like was done to #tip[#link("https://hackage.haskell.org/package/base/docs/Prelude.html#v:-36-")[\$]][(\$) :: forall repa repb (a :: TYPE repa) (b :: TYPE repb). (a -> b) -> a -> b]? Is it "just" that it requires effort, or are there tradeoffs there, too?

= Conclusion

I'm not a Haskell type system or GHC expert, so maybe my hardships with these experiments should be taken with a grain of salt. But I believe I'm also far from a beginner, and found some of these changes genuinely difficult to make and reason about.

I thought maybe I could propose that we make representation-polymorphic all methods for `Num`, `Ord`, and `Eq`, and maybe even make numeric literals representation polymorphic? I am sort of hoping someone more experienced will tell me to do it or tell me why it wouldn't fly (special treatment of `$` in GHC?).

Also, the hpgsql repository has benchmarks that are easy to run in case people want to try out performance improvements themselves. Just clone the repo, enter the Nix shell and run `run bench-single -- --match "hpgsql Record Stream"`.
#[] <hpgsql-toc-end>
]
