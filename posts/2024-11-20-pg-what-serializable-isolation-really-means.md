# What Serializable isolation really means with PostgreSQL

Many of us are familiar with the typical transactional isolation levels in relation databases. Read-committed, Repeatable-Read and Serializable are examples. And there are many articles and sources listing the undesirable phenomena some of these isolation levels protect us from, like dirty reads, phantom reads and serialization anomalies.

One also finds phrases like serializable transactions are "guaranteed to produce the same effect as running them one at a time in some order", but what kind of strangeness might arise from not running as such? There are also Stack Overflow answers suggesting accounting and enforcing credit limits is an example where serializability is important, but what does that _really_ mean? PostgreSQL's [docs](https://www.postgresql.org/docs/current/transaction-iso.html) say that "a read-only transaction at this level may see a control record updated to show that a batch has been completed but not see one of the detail records which is logically part of the batch because it read an earlier revision of the control record", but what does that _really_ mean?

Most sources I've found lack two very important things: an intuition around the kinds of failures that might arise with isolation less than Serializable, e.g. Repeatable-Read, and examples.

So I'll show you two such examples. They're not mine, they're from the paper that introduced the current Serializable isolation's implementation in PostgreSQL [1](https://arxiv.org/pdf/1208.4179). So big thanks to Kevin Grittner and Dan Ports. In fact, this blog post is mostly a copy of their paper, it's just shortened quite a bit and focused on the examples. So all credit goes to those guys. Read the paper if you want more details.

From those examples we _hope_ to build a slightly better intuition around serialization anomalies, but I actually hope to convince you, the reader, that anything less than Serializable isolation - including Repeatable-Read - is tantamount to a level where humans cannot reason about correctness, and implications can be dire.

Before the examples, we shall take a quick closer look at Repeatable-Read.

### Repeatable-Read

Repeatable-Read ensures inside your transaction you do not see _any_ effects of other concurrent transactions, whether they've committed, aborted or are still running. You get a _snapshot_ of the database when you `BEGIN` your transaction and work with that until you commit.

Also, two concurrent transactions cannot modify the same row under Repeatable-Read.

It sounds pretty robust. How can this go wrong? Let's look at examples.

### First example: doctors on call

Suppose you manage a hospital and you you must always have at least one doctor on call at any one time. Bob, Alice and Joe are your doctors, and initially Alice and Joe are on call but Bob isn't.

```sql
CREATE TABLE doctors (id SERIAL PRIMARY KEY, name text, oncall BOOL);
INSERT INTO doctors (name, oncall) VALUES ('Alice', TRUE), ('Joe', TRUE) ('Bob', FALSE);
```

Now you write the endpoint that takes a doctor off call (in some pseudo-code):
```sql
x <- SELECT COUNT(*) FROM doctors WHERE oncall;
if x >= 2 then
  UPDATE doctors SET oncall=false WHERE name = {DOCTORNAMEHERE};
else
  RAISE 'This would leave no doctors on call';
end if
```

Before continuing, take a minute to look at the code above: it looks right. It would probably pass review in most places. It's the code I would write, but also most people I know. Or it's similar to that.

Suppose users call your endpoint twice for 'Alice' and for 'Joe', and the transactions run concurrently. Even with Repeatable-Read isolation level, both transactions will run and commit successfully, and at the end you will have 0 (zero) doctors on call. This is of course very different from what would happen if you ran two transactions _one after the other/sequentially_, so it's a perfect example of a serialization anomaly.

With Serializable isolation one of the two transactions would fail with:
```
ERROR:  could not serialize access due to read/write dependencies among transactions
```

And the hospital would be in good hands. This is the first example of where Repeatable-Read fails: when concurrent transactions read the same data but write to different places.

### Second example: receipts and batches

Also from Grittner's and Ports's paper, imagine you have a table of receipts that are each associated with a batch number, and another table with just one row storing the current batch number. Then you have 3 operations, copied verbatim from the referenced paper below:

- NEW-RECEIPT: reads the current batch number from the control table, then inserts a new entry in the receipts table tagged with that batch number
- CLOSE-BATCH: increments the current batch number in the control table
- REPORT: reads the current batch number from the control table, then reads all entries from the receipts table with the previous batch number (i.e. to display a total of the previous day's receipts)

Let's create these tables with the current batch starting as `1` and one receipt in it:
```sql
CREATE TABLE current_batch (batch INT);
INSERT INTO current_batch VALUES (1);
CREATE TABLE receipts (id SERIAL PRIMARY KEY, batch INT, amount INT);
INSERT INTO receipts (batch, amount) VALUES (1, 100);
```

Let's look at one particular transaction first, the `REPORT` one:

```sql
current_batch <- SELECT batch FROM current_batch;
SELECT SUM(amount) FROM receipts WHERE batch=current_batch-1;
```

Again I will ask you to read this and think for a minute. This looks right, doesn't it? Can you think of what problems might arise from this under Repeatable-Read isolation?

The answer is: **it can report the sum of a batch that might still have receipts added to it.** I am not kidding. Let me show you:

Suppose 3 transactions run concurrently in Repeatable-Read mode, each with one of the 3 kinds of transactions, and their execution is interleaved as such:

<table>
<tr>
   <td>Transaction 1 (REPORT)</td>
   <td>Transaction 2 (NEW-RECEIPT)</td>
   <td>Transaction 3 (CLOSE-BATCH)</td>
</tr>
<tr>
   <td></td>
   <td>
    ```
      BEGIN ISOLATION LEVEL REPEATABLE READ;
      current_batch <- SELECT batch FROM current_batch;
      ```
   </td>
   <td></td>
</tr>
<tr>
   <td></td>
   <td></td>
   <td>
    ```
      BEGIN ISOLATION LEVEL REPEATABLE READ;
      UPDATE current_batch SET batch=batch+1;
      COMMIT;
    ```
   </td>
</tr>
<tr>
   <td>
    ```
      BEGIN ISOLATION LEVEL REPEATABLE READ;
      current_batch <- SELECT batch FROM current_batch;    
      SELECT SUM(amount) FROM receipts WHERE batch=current_batch-1;    
      COMMIT;
    ```
   </td>
   <td></td>
   <td>
   </td>
</tr>
<tr>
   <td>
   </td>
   <td>
    ```
      INSERT INTO receipts (batch, amount) VALUES (current_batch, 1000);
      COMMIT;
    ```
   </td>
   <td>
   </td>
</tr>
</table>

After the execution above, the transaction in the middle will insert a receipt with amount=1000 into batch 1, but the first transaction (REPORT) will have shown a total of 100 for that batch.

Another thing that is really hard to see is that this requires all 3 transactions to run concurrently to run into this odd behaviour, and that `REPORT` is read-only. And once again, using Serializable isolation would make transactions fail to keep this from happening.

The broad picture is that serialization anomalies come to be due to a cycle of rw-conflicts (a rw-conflict is a Read by one transaction whose results would be affected by a concurrent transaction's Writes; more details in the referenced paper), but this is of course not helpful for an intuition or smaller mental model. So I have no intuition to offer the reader for this example.


### Conclusions

Hopefully I've achieved my goal: unless you're truly one of a kind (I tend to be careful with my wording, but I'm going to take the liberty of speaking plainly: you're not; I am not; no human is), you cannot reason about what might happen in a system that's not running with Serializable isolation. And very strange/bad things can happen. We covered an example with 2 transactions and another with 3, but real systems have tens, hundreds, thousands of them. Can you comfortably say no concurrent execution of transactions will have an undesirable effect?

Hopefully I'll find time to write about some limitations of PostgreSQL's current implementation of Serializable isolation next time.

### References

[1 - Kevin Grittner's and Dan Ports's paper on SSI in PostgreSQL](https://arxiv.org/pdf/1208.4179)
