In the [previous article](/posts/2024-11-20-pg-what-serializable-isolation-really-means.md) I covered why Serializable transactions are great for a more worry-free development of concurrent applications. Now we're going to cover some details of how it's implemented in postgresql so we understand some of its limitations. Essentially this post is about false-positive detection of serialization anomalies.

Let's create a test table with a large number of rows first, the smallest Id being 1000 and the largest being 1000000:

```sql
CREATE TABLE test_table (id SERIAL PRIMARY KEY, name TEXT);
WITH q(num) AS (SELECT * FROM generate_series(1000,1000000)) INSERT INTO test_table (id, name) SELECT num, 'anything' FROM q;
SELECT min(id), max(id) FROM test_table;
```

Let's start with two concurrent transactions whose concurrent execution is serializable, so postgres should let them commit. Scroll further down below to look at the SQL we will execute as you read the bullet points below:  
- The transaction to the left (henceforth called left-txn) looks for a row with id=5 and right-txn doesn't insert such a row.  
- Right-txn looks for a row with id=1000001 and doesn't find one, but left-txn does insert a row with that Id.  
- Right-txn inserts a row with Id 1000002, but left-txn is not / would not be affected by that in the slightest.  

The execution is serializable because the final results are the same as if right-txn had committed before left-txn started (but postgres will let you commit any one of them before the other).

To try this experiment, open two separate `psql` instances, and run each command in the order they're laid out vertically below in each separate instance:

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;

                                                                        BEGIN ISOLATION LEVEL SERIALIZABLE;

SELECT * FROM test_table WHERE id=5;
-- 0 results

                                                                        SELECT * FROM test_table WHERE id=1000001;
                                                                        -- 0 results

INSERT INTO test_table (id, name) VALUES (1000001, 'something');
-- INSERT 0 1

                                                                        INSERT INTO test_table (id, name) VALUES (1000002, 'something');
                                                                        -- INSERT 0 1

                                                                        COMMIT; -- all good

COMMIT; -- all good, and you could've committed this first as well
```

For postgres to detect a serialization anomaly, there needs to be a cycle* in rw-antidependencies (a rw-antidependency is when one transaction reads something whose results would be different due to another concurrent transaction modifying data).
Since there are only two concurrent transactions and left-txn doesn't read any data modified by right-txn, there can be no such cycle (notice there is a rw-antidependency from _right-txn -> left-txn_ due to reading 0 results with `id=1000001`).
What if repeat the transactions above but change the Ids so they're closer to each other? Instead of 5, 1000001 and 1000002 let's use 5, 4 and 200.

```sql
DELETE FROM test_table WHERE id>1000000; -- clean up
BEGIN ISOLATION LEVEL SERIALIZABLE;

                                                                        BEGIN ISOLATION LEVEL SERIALIZABLE;

SELECT * FROM test_table WHERE id=5;                                                 
-- 0 results
                                                                         
                                                                        SELECT * FROM test_table WHERE id=4;
                                                                        -- 0 results

INSERT INTO test_table (id, name) VALUES (4, 'something');
-- INSERT 0 1

                                                                        INSERT INTO test_table (id, name) VALUES (200, 'something');
                                                                        -- INSERT 0 1

                                                                        COMMIT; -- all good

COMMIT;
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
```

We just replaced some Ids but it is still true that left-txn does not read any data modified by right-txn. So why does this fail? The answer is that postgres checks aren't perfectly precise. There is a matter of granularity. Let's look in more detail.


### Predicate locks

Every time you read data from a table inside a serializable transaction, postgres creates one or more predicate locks internally. "Lock" is a bit of a misnomer because unlike locks we're familiar with, these don't block other transactions from reading nor writing to the same data. Let's see what that means:

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT COUNT(*) FROM test_table;
SELECT locktype, mode, relname, page, tuple FROM pg_locks LEFT JOIN pg_class ON relation=pg_class.oid WHERE mode='SIReadLock';
 locktype |    mode    |  relname   | page | tuple
----------+------------+------------+------+-------
 relation | SIReadLock | test_table |      |
(1 row)
```

In `pg_locks` we can view predicate locks by checking for `mode=SIReadLock`. The one above is a `relation` predicate lock. It means our transaction read the contents of the entire table, so any concurrent transactions modifying any rows in the table will create a rw-antidependency from the writing transaction to our transaction above. Remember this is not sufficient to cancel one of the transactions: there needs to be a cycle* for a serialization anomaly to happen, not just one rw-antidependency.

Let's look at predicate locks for the two transactions we tried earlier where one of them failed. Right before the first `commit` statement, what do predicate locks look like?

```sql
DELETE FROM test_table WHERE id=200; -- Cleanup before you try again
-- Now run both transactions again, but right before the first commit run:
SELECT locktype, mode, relname, page, tuple FROM pg_locks LEFT JOIN pg_class ON relation=pg_class.oid WHERE mode='SIReadLock';
 locktype |    mode    |     relname     | page | tuple
----------+------------+-----------------+------+-------
 page     | SIReadLock | test_table_pkey |    1 |
 page     | SIReadLock | test_table_pkey |    1 |
(2 rows)
```

Notice two very important things:  
- The predicate locks are on the index, not the table.  
- `tuple` is NULL. The predicate locks are on all of page 1.  

This means postgres doesn't know left-txn only tried to read a row with `id=5` and right-txn only tried to read a row with `id=4`. Instead, it thinks any modifications to any rows that live within index page 1 could've affected the `SELECT` statements from both transactions. Because Ids 4,5, and 200 would all live in page 1, postgres thinks there are rw-antidependencies from both transactions to one another. This is clearly a false positive.

This is a problem of granularity. Sadly, while for tables there are tuple-level locks, for indexes the smallest granularity is a page. Which for a btree index of integers can include up to ~367 entries according to the [pageinspect](https://www.postgresql.org/docs/16/pageinspect.html#PAGEINSPECT-B-TREE-FUNCS) extension.

### Predicate lock promotion

Suppose you select a few rows:
```sql
VACUUM (FULL) test_table;
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT COUNT(*) FROM test_table WHERE id BETWEEN 10000 AND 10002;
```

If you query locks now, you will see 3 relation tuple-level predicate locks and one index page-level predicate lock. If you select just one more row - the one with Id 10003 - and query locks again, postgres will promote what would be 3 tuple-level locks to one page-level lock:

```sql
 locktype |    mode    |     relname     | pid  | page | tuple
----------+------------+-----------------+------+------+-------
 tuple    | SIReadLock | test_table      | 7683 | 5400 |    23
 page     | SIReadLock | test_table      | 7683 |   48 |
 page     | SIReadLock | test_table_pkey | 7683 |   26 |
(3 rows)
```

According to pageinspect, for this table (which granted, has very few columns) one page contains 187 rows. That is, the granularity of our predicate locks went from 3 to 187 rows because of one more selected row. This might be fine for your workloads, but it's not a very smooth transition.

This is configurable through the [max_pred_locks_per_page](https://www.postgresql.org/docs/current/runtime-config-locks.html#GUC-MAX-PRED-LOCKS-PER-PAGE) setting, and there are more `max_pred_*` settings worth looking at because the default might be too low for your workloads.

There are other interesting things about SSI in postgres, though I'm not sure I'll find the motivation to keep writing about them. HOT updates, predicate locks being replaced by "normal" locks on writes, and some things I still don't understand like postgres being smarter than what `pg_locks` might make you think it could be.

### References

- [README-SSI](https://github.com/postgres/postgres/blob/master/src/backend/storage/lmgr/README-SSI) in postgres's codebase discusses the implementation and also has a very interesting "Several optimizations are possible" section.
- Dan Ports's and Kevin Grittner's [SSI paper](https://arxiv.org/pdf/1208.4179).
- pg-hackers [discussion thread](https://www.postgresql.org/message-id/flat/CAEepm%3D2GK3FVdnt5V3d%2Bh9njWipCv_fNL%3DwjxyUhzsF%3D0PcbNg%40mail.gmail.com) of Thomas Munro's unmerged patches with some improvements to postgres' SSI implementation.


*: Postgresql doesn't really check for a cycle. Rather it checks for two adjacent rw-antidependencies in a directed graph where transactions are nodes and rw-antidependencies are edges, with the transaction at the end of the second edge being the first to commit. This can lead to false positives in exchange for being a cheaper check. See Chapter 3.3 in [the paper](https://arxiv.org/pdf/1208.4179).
