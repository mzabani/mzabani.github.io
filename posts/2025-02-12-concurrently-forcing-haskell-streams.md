## Concurrently processing streams in Haskell

This article covers how I made [codd](https://github.com/mzabani/codd), a PostgreSQL migration application tool written by me in Haskell, speed up the application of a `COPY` statement with 5.65 million lines from 12.1s to 9.8s (on my machine), a 19% reduction in time, bringing it much closer to the time the official `psql` tool takes to apply the same migration - 9.4s.

The nice thing is that the abstraction used here is hopefully reusable across a wider range of applications and is easy to apply.

## The actual problem and the benchmark's baseline

Codd reads SQL migrations from disk in streaming fashion. It then parses the text stream into separate SQL statements, keeping one SQL statement in memory at a time so arbitrarily large migrations can be added without blowing up memory usage. For `COPY` statements it uses a fixed size buffer for the body of the `COPY` statement and therefore also reads it (and sends it to postgres) in chunks. We use the [streaming](https://hackage.haskell.org/package/streaming) library.

Basically, codd has a parsing function that takes in a .sql's file as a Stream of Text and returns a Stream of SQL statements, as such:

```haskell
parseSqlPiecesStreaming ::
  Monad m =>
  Stream (Of Text) m () ->
  Stream (Of SqlPiece) m ()
```

For our purposes you can think of `SqlPiece` as one single/whole individual SQL statement or as a chunk of a `COPY` statement's body. Postgres doesn't receive statements in incomplete chunks so codd needs to separate statement boundaries to send them to the server one at a time (there's a bit more to this, but it doesn't matter for our purposes).

Then there is of course a function in codd that consumes the `Stream` of `SqlPiece` and applies them one at a time. For a 116MB sql migration with a single COPY statement with approximately 5.65 million lines, codd currently takes `12.1s ± 0.27s` to apply it (it's actually doing a bit more than just applying the migration, but not much). For comparison, `psql` takes `9.4s ± 0.06s`, ~22.5% less.

Profiling and optimizing codd's sql parser should be fun, but I wanted to explore a different idea: what if we keep reading from disk and running the parser while we wait for postgres to process statements we apply¹? Codd isn't currently doing anything while it waits for postgres, after all.

## Forcing Streams concurrently

In order to read and parse the next `SqlPiece` from disk while postgresql is applying a statement, I thought I could just force the Stream's next element concurrently ahead of time. I couldn't find such a function in the [streaming](https://hackage.haskell.org/package/streaming) library so I wrote one - I'll link to it later in this post.

To clarify, this is not some kind of `mapConcurrently` function because we still have to send each statement to postgresql sequentially, and such ordering seems difficult to implement on top of `mapConcurrently`, at least at a glance.

This is about forcing the Stream of `SqlPiece` concurrently to what the consumer of said Stream is doing, so that the next element of the Stream has higher chance of already having been computed/fetched when it's demanded. The signature of this function would thus be similar to an identity function:

```haskell
forceStreamConcurrently ::
  Monad m =>
  Stream (Of a) m r ->
  Stream (Of a) m r
```

The "simple" implementation with a blocking bounded queue made total time go from 12.s to 11.4s even with `+RTS -N1`. Here's some pseudo-code of the application loop with such an implementation (pseudo-code ended up being clearer than Haskell here to better convey the idea):


```python
queue = new_queue { size = 1 }
# A background thread keeps on parsing and pushing to the queue
forkBackgroundThread {
  while (sqlPiece = parse_next_SqlPiece())
    queue.append(sqlPiece) # Will block when adding to a full queue
}

# Meanwhile we keep on applying parsed statements/chunks
while (sqlPiece = dequeue(queue))
  send_to_postgres(sqlPiece)
```

## Forcing more elements ahead of time

Why force only one future statement concurrently? By forcing _two_ future elements of the stream ahead of time concurrently, total time went from 12.1s to 10s, a better improvement. The forcing function now has the following type:

```haskell
forceStreamConcurrently ::
  Monad m =>
  Natural ->
  Stream (Of a) m r ->
  Stream (Of a) m r
```

But then I tried increasing the number of Stream elements forced concurrently, things didn't always get better. Here are some times collected in terms of how many elements we force concurrently ahead of time:

|      | 0              | 1              | 2              | 3              | 4              |
|------|----------------|----------------|----------------|----------------|----------------|
| Time | 11.60s ± 0.19s | 10.02s ± 0.17s | 11.23s ± 0.66s | 10.10s ± 0.10s | 10.01s ± 0.18s |

Note that `n=0` means the queue of elements has size 1, meaning _it is concurrent_: when we remove a `SqlPiece` from the queue and send it to postgres, there is available work to be done by parsing the next `SqlPiece`. In fact with `n=0` the code will always force **two** elements at a time, only it'll block when trying to add the second element to the queue (look at the pseudo-code from earlier to see how). Remember this as it's relevant for one kind of risk assessment that we'll discuss in the next section. 

It seems that n=0 is a modest improvement and n=2 is quite bad. n=1, 3 or 4 are all quite good. I reran some of these to make sure this wasn't noise, so why is 2 worse than the others?

## Why is n=2 slow?

Honestly, I don't know. But with `+RTS -N1` there is a single runtime capability that must alternate between parsing and sending SQL chunks to postgres. Ideally this capability would switch to sending SQL chunks to postgres immediately when postgres is ready for more and at least one chunk is already parsed. Any elapsed time with postgres waiting and one parsed SQL chunk in the queue is wasted time.

But of course we have no control of the runtime's scheduler. And so my immediate feeling is that choosing a queue size is a gamble, and that we might be relying on such complex runtime scheduling characteristics that maybe the best values for `n` would be different on a different computer, or with a different SSD, or with different networking.

And since we're talking about risks, remember that even with `n=0` our code will always try to force _two_ elements of the Stream concurrently. Of course the same risks exist for any queue size, but the point is that not even `n=0` is a safe value, one that'd "force" the scheduler to not let postgres idle.

Unless of course we use STM (Software Transactional Memory) to _block_ immediately after the queue is full. That would make n=0 safe. So I added this to the code that forces the stream in a forked thread:

```haskell
STM.atomically $ do
  -- Don't do work until the element is removed from the queue
  l <- STM.lengthTBQueue evaluatedElements
  when (l == futureElementsQueueSize + 1) STM.retrySTM
```

But now `n=0` went from 11.60s to 12.48s, so I'm guessing STM related costs made this attempt not worthwhile.

## "Giving up"

Despite the real problem not having been pinned down, my bets are still that to make this work we'd need finer control of runtime scheduling. And of course I don't want to or even know how to go there. I wonder how much it matters that [postgresql-libpq](https://github.com/haskellari/postgresql-libpq) makes FFI calls to libpq under the hood, as opposed to being a pure Haskell implementation. If you know GHC's runtime well, please comment!

So one "easy" alternative is instead to use two capabilities, i.e. `+RTS -N2`, at which point it's almost as if we'll have one CPU core working on reading and parsing SQL chunks from disk and another CPU core ready to send them to postgres.
It feels a bit wasteful since sending SQL chunks to postgres is just a network call, but let's see how times change with 2 capabilities:

|      | 0              | 1              | 2              | 3              | 4              |
|------|----------------|----------------|----------------|----------------|----------------|
| -N1  | 11.60s ± 0.19s | 10.02s ± 0.17s | 11.23s ± 0.66s | 10.10s ± 0.10s | 10.01s ± 0.18s |
| -N2  | 10.94s ± 0.20s |  9.87s ± 0.15s | 10.29s ± 0.17s |  9.80s ± 0.19s |  9.86s ± 0.13s |

This is not only faster in all cases, it also feels more protected against diverse disk+network+CPU combinations by affording us the possibility of choosing higher values of `n` bounded only by maximum memory usage (given this will keep more SQL chunks in memory at any given time). But the typical SQL chunk or statement is at most a few KB long (and codd limits chunks of `COPY` body to 64KB) so it's not super concerning.

The sad bit is that `-N2` makes the app's peak memory double. But that's still going from 6MB to 12MB in my benchmarks, so I think it's worth the speed-up we get with e.g. `n=3`.

## Making this function a less leaky abstraction

There are cases where even a well implemented `forceStreamConcurrently` function can change program behaviour:

### 1 - Not consuming the returned stream completely

Take this code that launches 2 missiles:

```haskell
S.take 2 $ S.repeat launchMissile
```

If you use `forceStreamConcurrently` with e.g. 3 elements forced ahead of time concurrently, you will actually fire more than 2 missiles.

```haskell
-- This fires more than just 2 missiles
S.take 2 $ forceStreamConcurrently $ S.repeat launchMissile
```

You could also miss an exception thrown by an effect fired later in the Stream.

The linear-base package has [linear streams](https://hackage.haskell.org/package/linear-base-0.4.0/docs/Streaming-Linear.html) which could be used to mostly fix² this issue, IIUC. I didn't do so with codd because I'm not yet familiarized with Linear Types and this function is only used in one place, but you may want to depending on how exposed this function will be in your codebase.

### 2 - Stream's side-effects change the world in time-sensitive ways

If you're querying an external endpoint for each stream element like this:

```haskell
-- Wait 5s before yielding each element in the stream to avoid being rate-limited
S.delays 5 streamWithHttpRequestsToThirdPartyService
```

Then you might be rate-limited by the third party service if you do this:

```haskell
S.delays 5 $ forceStreamConcurrently streamWithHttpRequestsToThirdPartyService
```

### 3 - The side-effects of downstream consumers interfere with the side-effects of the forced stream

The effect of the code below is to append alternating lines to a file:

```haskell
-- This might not be valid Haskell nor a terminating program, but you get the point
withFile "some-file.txt" $ \f -> S.mapM (const $ appendLine "A" f) $ S.repeat (const $ appendLine "B" f)
```

Imagine `forceStreamConcurrently` somewhere there and you will see that _some-file.txt_ can look different.
This example in particular is why `forceStreamConcurrently` can't be used carelessly at scale, IMO.

## The code

Without further ado, the code. Most of the complexity has to do with cleaning up the background thread when the returned Stream is not consumed completely and with doing "the right thing" w.r.t. exceptions, but also making it possible to write a test for such behaviors. You could simplify this a bit if you don't need to test proper thread cleanup.

Do notice many of the imports here are from the [unliftio](https://hackage.haskell.org/package/unliftio) library, not `base`.

Feel free to copy it and use and/or modify it however you want, no need to mention this. I hope you find it useful.

```haskell
forceStreamConcurrently :: forall m a r. (MonadUnliftIO m) => Natural -> Stream (Of a) m r -> Stream (Of a) m r
forceStreamConcurrently = forceStreamConcurrentlyInspect Nothing

data NoMoreConsumersOfTheReturnedStreamException = NoMoreConsumersOfTheReturnedStreamException
  deriving stock (Show)

instance Exception NoMoreConsumersOfTheReturnedStreamException

forceStreamConcurrentlyInspect ::
  forall m a r.
  (MonadUnliftIO m) =>
  -- | Supply an empty MVar that will be written to iff the stream returned by this function is not consumed linearly
  Maybe (MVar ()) ->
  Natural ->
  Stream (Of a) m r ->
  Stream (Of a) m r
forceStreamConcurrentlyInspect returnedStreamNotConsumedLinearly futureElementsQueueSize stream = S.Effect $ do
  case returnedStreamNotConsumedLinearly of
    Nothing -> pure ()
    Just mv -> unlessM (isEmptyMVar mv) $ error "Please supply an empty MVar to store the background thread's exit state"
  evaluatedElements :: STM.TBQueue (Either SomeException (Either r a)) <- STM.newTBQueueIO (futureElementsQueueSize + 1)
  void $ forkIO $ do
    streamReturnOrException <-
      try $
        S.mapsM_
          ( \(el :> eff) -> do
              -- If the stream returned by this function isn't linearly consumed, garbage collection will make
              -- writing to the TBQueue eventually throw a `BlockedIndefinitelyOnSTM` exception as this background thread
              -- will be the only one still holding on to the associated TVars.
              -- When that happens we don't want to try and write to the TBQueue again as it'd block forever. We just want to
              -- exit gracefully.
              handleJust (\(_ :: BlockedIndefinitelyOnSTM) -> Just ()) (\() -> throwIO NoMoreConsumersOfTheReturnedStreamException) $ STM.atomically $ STM.writeTBQueue evaluatedElements (Right $ Right el)
              pure eff
          )
          stream
    case streamReturnOrException of
      Left (ex :: SomeException) -> do
        case fromException ex of
          Just (_ :: NoMoreConsumersOfTheReturnedStreamException) ->
            -- We don't rethrow to avoid top-level exception handlers from detecting this, which is handled behavior after all
            case returnedStreamNotConsumedLinearly of
              Nothing -> pure ()
              Just mv ->
                putMVar mv ()
          Nothing ->
            STM.atomically $ STM.writeTBQueue evaluatedElements (Left ex)
      Right streamReturn ->
        STM.atomically $ STM.writeTBQueue evaluatedElements (Right $ Left streamReturn)

  pure $ go evaluatedElements
  where
    unlessM f g =
      f >>= \case
        True -> pure ()
        False -> g
    go :: STM.TBQueue (Either SomeException (Either r a)) -> Stream (Of a) m r
    go evaluatedElements = S.Effect $ do
      nextEl <- STM.atomically $ STM.readTBQueue evaluatedElements
      pure $ case nextEl of
        Right (Right el) -> S.Step (el :> go evaluatedElements)
        Right (Left r) -> S.Return r
        Left ex -> S.Effect $ throwIO ex
```

## Footnotes

1) There is a postgres setting called `standard_conforming_strings` which can change the behaviour of the parser, so to correctly parse SQL we'd have to wait for postgres to return before parsing the next statement given that users can run `SET standard_conforming_strings TO on/off`. For now codd does not support the (non-default) value of `off`, though it could apply this optimization only to chunks of `COPY` in the future where it matters more and support the setting fully.

2) A linear stream might ensure all side-effects run the same way they would without `forceStreamConcurrently`, but I'm not sure if it's stronger than necessary because we only need all stream elements to be _yielded_, not that each such element is also consumed linearly, which I think is what a linear stream is? Corrections welcome.
