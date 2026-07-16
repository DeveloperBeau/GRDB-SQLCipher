# SQLCipher performance and stability benchmarks

`SQLCipherProofTests/SQLCipherBenchmarks.swift` measures SQLCipher (Community
Edition, the build this fork vendors) against an unencrypted SQLite database in
the same process, so every delta is the cost of encryption alone. It answers one
question: where does encryption hurt, and what do we do about it.

## Running

```
# Light tier (100k rows), a few minutes:
swift test -c release --filter SQLCipherBenchmarks

# Heavy tier (1M rows / 200k ops), ~5 minutes:
RUN_HEAVY_BENCH=1 swift test -c release --filter SQLCipherBenchmarks
```

Results print as `BENCH| ...` lines. Numbers below are from an Apple-silicon
Mac, release build, `cipher_page_size = 8192` (the size the app ships). Absolute
times vary by machine; the encrypted-vs-plain ratios are what matter.

## Results

Encrypted mode is a passphrase key (SQLCipher's default) unless the row names a
raw key.

| Workload | Plain | Encrypted | Overhead |
|---|---|---|---|
| Bulk import, batched 10k, 100k rows | 1.04s | 1.10s | +6% |
| Bulk import, batched 10k, 1M rows | 15.3s | 28.5s | +86% |
| Bulk import, one txn per row, 8k rows | 0.27s | 0.62s | +134% |
| Full-table update, 1M rows | 2.97s | 4.52s | +52% |
| Indexed update (~1/1000 rows), 1M rows | 0.03s | 0.05s | +107% |
| Rapid interleaved CRUD, 200k ops | 4.49s | 9.36s | +109% |
| **Cold open + first query, 1M rows, passphrase** | 0.001s | **0.086s** | **+10276%** |
| **Cold open + first query, 1M rows, raw key** | 0.001s | **0.001s** | **+0.5%** |

Stability, all encrypted, all passed:

- **Concurrency** (6 readers + 1 writer, 40k writes under WAL): 0 lock/timeout
  errors, `integrity_check = ok`. Peak WAL 183MB, dropped to 0 after a TRUNCATE
  checkpoint.
- **Abuse** (error injected mid-transaction, oversized and single-row
  transactions): every transaction rolled back cleanly, `integrity_check = ok`.
- **WAL growth**: one 1M-row transaction grows the WAL to 750MB before commit
  and holds it there. The same import in 5k-row batches keeps the WAL at 17MB
  because autocheckpoint reclaims it between batches.

## Verdict

For the app's real workloads, encryption is not a problem — provided three
things hold. Each maps to a safeguard already in place or applied.

### 1. Open with a raw key, never a passphrase

This is the one finding that changes correctness-of-approach, not just a
constant factor. A passphrase makes SQLCipher run PBKDF2 (256,000 iterations) on
**every open**, a fixed ~80ms that does not shrink with a smaller database. That
cost buys nothing when the key is already 32 uniformly random bytes: the KDF
exists to stretch a weak human passphrase, and a full-entropy key has nothing to
stretch. Supplied as a raw key (`PRAGMA key = "x'<64 hex>'"`), the same key opens
a 1M-record encrypted database in 1ms, within noise of an unencrypted open.

Applied in the app: the database key is minted as 32 `SecRandomCopyBytes` bytes
and handed to SQLCipher as a raw key. A repeated open, a cold launch, and a
widget or extension touching the database all skip the derivation.

### 2. Batch large writes

Encryption roughly doubles per-transaction write cost, so the penalty for a
pathological write shape is doubled too. One-transaction-per-row import is +134%;
the same rows in 10k batches are +6% at 100k rows. Batching also bounds WAL
growth (17MB vs 750MB on a 1M-row import), which keeps peak disk and checkpoint
latency predictable.

Applied in the app: bulk paths (sync ingest, backfill) write in batches inside a
single transaction, not row by row.

### 3. Expect ~2x on sustained per-row write churn, and keep a long-lived pool

Rapid interleaved CRUD is +109% encrypted. There is no trick that removes this;
it is the cost of encrypting each page as it is written. It is not a problem at
the app's volumes (thousands of ops, not hundreds of thousands per burst), and a
long-lived `DatabasePool` means the raw-key open cost is paid once, not per
operation.

## Background suspension and durability

The concurrency and abuse tests confirm the ACID guarantee holds under
contention and mid-transaction failure: a rolled-back transaction leaves
`integrity_check = ok`, and a committed transaction is durable in the WAL. Being
suspended is, to SQLite, indistinguishable from the process pausing between two
statements: a transaction that has committed is on disk, and one that has not is
rolled back whole on the next open. SQLite never leaves a half-applied
transaction. The remaining risk is the OS sealing the file under a strict file
protection class while a write is in flight; the app keeps the database at
`.completeUntilFirstUserAuthentication` (readable while the device is locked
after first unlock) so a backgrounded write is never interrupted by the file
sealing. Verifying the seal-vs-write timing on a physical locked device is a
device-authoritative check the simulator cannot stand in for.

## Caveat

The RSS-over-baseline figure reads 0MB in these runs; the mach task-info delta
used to sample it is unreliable here and the number should be ignored. WAL sizes
(measured from the file on disk) are accurate.
