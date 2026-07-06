---
title: '"Worse is Better", Building a CGNAT Log Ingestor'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["go", "SQLite", "Kafka", "Architecture", "CGNAT"]
categories: ["programming"]
---

There is an old essay by Richard Gabriel, *The Rise of Worse is Better*, that
argues that the system that is simple to implement and covers most of the
cases beats the complete, correct, complex one in practice. I did not plan to
re-run that experiment at work, but it happened anyway: we designed a CGNAT
log ingestor for infinite horizontal scale, and then we shipped one Go process
in one container instead.

This article is the story of that walk-back: why the big design existed, what
made us re-evaluate it, how far the "worse" system actually goes, and why the
big one is still waiting at the end of the road. To follow along you should
have a general knowledge of Go and be familiar with how Kafka-style ingestion
pipelines are usually put together.

## The Problem Is a Cache Wearing a Database Costume

Carrier-Grade NAT (CGNAT) is how an ISP puts thousands of subscribers behind a
small pool of public IPv4 addresses. Every CGNAT device emits a log line for
every session it maps, and the people operating that network need to answer
one question fast: *which subscriber was behind this public IP and PORT a
moment ago?* The same information is needed from three different directions:
by public address and port, by private address and port, and by subscriber.

Three properties of this workload drive every decision downstream:

* **Extremely high write rate**: tens of thousands of log lines per second
  arrive over syslog, continuously.
* **Extremely short retention**: a mapping only matters for minutes. After
  that, nobody will ever ask for it again.
* **Most-recent-wins reads**: every lookup wants the single latest mapping for
  a key, never a range, never history.

Look at those three together and a reframe suggests itself: this is not a
database, it is a **self-healing lookup cache**. It regenerates itself every
few seconds from the log firehose, and if you lose it, it re-warms on its own.
Hold that thought, because it took us a whole distributed system to see it.

## Designing for Infinity

The first system was born from the requirement everybody states and nobody
interrogates: *it has to scale*. And it is the design you would sketch in any
system design interview. A receiver takes the syslog stream and produces every
raw line into Kafka. A consumer group of parsers batch-writes into a
distributed wide-column store, with one denormalized table per query axis, and
time-windowed compaction so that expired data is dropped as whole files
instead of row by row. Delivery is at-least-once, committing offsets only
after a successful write, with idempotent upserts so replays are harmless.

```
             CGNAT devices (syslog UDP/TCP)
                          │
                          ▼
                 ┌─────────────────┐
                 │    receiver     │  receive · no parse · produce
                 └────────┬────────┘
                          ▼
                 ┌─────────────────┐
                 │      Kafka      │  raw lines · N partitions
                 └────────┬────────┘
             ┌────────────┼────────────┐
             ▼            ▼            ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐
        │ parser  │  │ parser  │  │ parser  │  parse · batch · write
        └────┬────┘  └────┬────┘  └────┬────┘  (one per partition)
             └────────────┼────────────┘
                          ▼
                 ┌─────────────────┐
                 │   wide-column   │  one table per query axis
                 │      store      │  windowed compaction · TTL
                 └────────┬────────┘
                          ▼
                 ┌─────────────────┐
                 │    query API    │  the three lookup axes
                 └────────┬────────┘
                          ▼
                       clients
```

Each piece is there for a reason. Kafka is the elastic buffer that absorbs
bursts when the store lags, and it gives you replay when a parser crashes.
Partitions are the scale-out lever: add brokers, add consumers, and the
pipeline follows. The consumer group gives you crash recovery without writing
any coordination code. Scaled out, this design tracks the full firehose of a
large carrier: **one million plus messages per second**, with no single
machine being special.

This design is correct. The point of this article is not that it is wrong.

## The Bill Arrives

Then we priced it, in money and in brains.

The infinite design is five services before the first byte flows: receiver,
broker, parsers, store, and something watching all of them. The brokers need
disks, replicas and partition planning. The store needs capacity planning and
compaction tuning. Every hop is a contract to version, a dashboard to build,
a failure mode to rehearse. None of this is wasted at one million messages
per second, it is exactly what that scale costs.

But the first real networks we had to serve were emitting tens of thousands
of messages per second, not a million. We were about to operate a particle
accelerator to crack a walnut. So we audited what the workload actually
demands:

* **Retention is minutes.** A durable log is a machine for not losing data,
  but here the data expires before durability can pay for itself.
  "Durability" means surviving one storage window, not surviving a
  datacenter.
* **The source is UDP syslog.** The transport is lossy before we ever touch
  the message, so exactly-once was never on the table. The best any pipeline
  can do is not add loss of its own.
* **The deployment unit is one machine anyway.** For these deployments the
  whole pipeline runs together, so "distributed" never actually crossed a
  machine boundary. We were paying coordination costs between processes that
  did not need to be separate processes.

What survived the audit was the **contract**: three lookup axes, short TTL,
per-source parsing rules, most-recent-wins. What did not survive was the
**topology**. So we built the worse system: the whole pipeline, receive,
parse, store, query, as **one Go process in one container**, with two bounded
channels where Kafka used to be and windowed SQLite where the distributed
store used to be.

## Cores as Shards, the One Scaling Knob

The small edition keeps the sharding idea from Kafka partitions, but the
shard becomes a goroutine instead of a broker partition. The shard count is
derived from `runtime.GOMAXPROCS(0)`, which in modern Go is cgroup-aware, so
it tracks the CPU limit of the container. It is deliberately not a
configuration knob: more shards than cores buys nothing on a CPU-bound path,
so there is nothing for an operator to get wrong.

```
    syslog (UDP/TCP)
         │
         ▼
    listener ──► parse queue ──► parse workers ──► store queue ──► store
                   (chan)                            (chan)       workers
                                                                 (1 per core)
                                                                      │
                                        in-memory SQLite window  ◄────┘
                                                 │ seal
                                                 ▼
        query API  ◄────  sealed, indexed, read-only files · dropped
                          after TTL
```

Each core owns a parse worker, a store worker, its own in-memory SQLite
window, and its own live key maps. Sealed files embed the shard ID and a
timestamp in the filename, and reads walk the files newest-first until the
first hit, so there is no cross-shard coordination anywhere. Throughput
scales by editing one line in the deployment spec: the CPU limit.
Rebalancing is replaced by there being nothing to rebalance.

## Windowed SQLite, and the Filesystem as a Commit Protocol

The write path is an in-memory SQLite database with **zero indexes** and the
durability pragmas turned off. That sounds reckless until you remember it is
RAM: the durable copy is the one on disk, so `synchronous = OFF` costs
nothing. An insert is an index-less append inside a batched transaction, the
cheapest possible hot path, because no B-tree has to be maintained per row.

Every few seconds, or when the window hits its row cap, the window **seals**:

1. `VACUUM INTO` a temporary file on disk.
2. Build the three query indexes on that sealed copy, once, in bulk.
3. Atomically rename it into place.

The rename is the commit protocol. Readers only glob completed files, so a
half-written seal is invisible to them. Recency is encoded in the timestamped
filenames, so "newest first" is a filename sort with no manifest and no
catalog. The seal runs in its own goroutine while the worker opens a fresh
window and keeps ingesting, so disk I/O never blocks intake.

TTL enforcement is the same trick the wide-column store was doing with
time-windowed compaction, implemented with nothing but files: expired data is
dropped by unlinking whole files, never by row deletes. The cleaner keeps a
safety margin comfortably past the nominal TTL, and a minimum file count
derived from the TTL, the window length and the shard count, so it always
errs toward keeping data. And because sealed files are just files, a restart
re-loads whatever has not expired: warm start needs zero recovery code,
because the on-disk layout *is* the metadata.

## The Freshness Gap, and Backpressure Without a Broker

Two guarantees from the distributed version had to be consciously re-earned.

The first is freshness. A record is not sealed to disk for up to one window,
so each shard also keeps live in-memory maps over its open window, one map
per query axis, all pointing at the same record. "Most recent mapping" falls
out of map-overwrite semantics, no ordering structure at all. The handoff is
the part that has to be exact: the new window's maps are registered *before*
they take traffic, and the old ones are removed only *after* their seal
finishes writing to disk, so every record is findable in at least one place
at every instant. And if seals ever fall behind and the registry fills, the
window degrades to disk-only with a warning instead of blocking ingest:
write-path availability outranks query freshness, and that is a decision, not
an accident.

The second is backpressure, and it turns out the transports already define
it. The UDP path does a non-blocking channel send: shed and count.

```go
select {
case parseQueue <- msg:
default:
    metrics.DroppedUDP.Add(1) // UDP is lossy by contract: shed and count
}
```

The TCP path does a plain blocking send, so the socket's own flow control
becomes the queue and the sender slows down. The semantics Kafka gave you,
re-derived from what each transport already promises.

## The Queue You Forgot You Had, the Kernel

This is the part where removing the broker sends you a bill.

During a seal, a one-core pod pauses ingest for a beat. With Kafka gone, the
only buffer between that pause and the wire is the kernel's UDP socket
receive buffer, and at the OS default size it silently drops the overflow.
The nasty part is where the loss happens: upstream of the application's read
loop. Every counter we owned read zero drops while packets were vanishing.
The per-second gauges were lying too, because a CPU-starved process reports
its own rates late. What exposed it was comparing deltas of monotonic totals
across the pipeline boundary, sender-emitted versus stored, the only numbers
that cannot lie.

The fix is a pattern, not a number. Force a receive buffer large enough to
bank a whole seal's worth of datagrams, not to smooth network jitter, using
`SO_RCVBUFFORCE` with the capability grant it requires, and fall back to the
plain `SO_RCVBUF` when the privilege is missing. Then exploit a kernel quirk
as a health check: Linux reports the doubled value when you read the buffer
size back, so if `getsockopt` returns less than twice what you asked for, the
node clamped you, and the process screams about it at startup instead of
dropping silently for weeks. When a silent failure mode exists, manufacture a
loud proxy for it at boot.

Two lessons worth keeping. First, that buffer memory is charged to the
container's cgroup, so oversizing trades packet loss for an OOM kill. Second,
and more general: when you move work off the hot path into periodic batches,
the batch's latency shadow has to be budgeted somewhere upstream. The broker
was absorbing it before. Now the kernel does, but only if you ask.

## Vertical Headroom

How far does the worse system go? On a benchmark rig with the pod pinned by
cgroup limits, **one core ingests, parses and stores 45,000 to 50,000
messages per second with zero drops**, answering live queries in about 20 ms.
Shards follow the CPU limit, so a four-core pod clears **150,000+ messages
per second**, and the scaling lever is still that one line in the deployment
spec. RAM stays bounded by the live window rather than the retained history,
and disk holds the retention, so both follow the ingest rate predictably.

For most of the networks this system serves, that is already more than the
entire firehose. The "worse" system is not a compromise at that scale, it is
simply the right amount of machine.

## When Vertical Runs Out

The infinite design did not die, it moved to the back of the queue. Both
editions answer the same contract: three lookup axes, short TTL, per-source
parsing, most-recent-wins. So when a deployment's firehose outgrows one
machine's cores, the full pipeline, Kafka, consumer groups and the
distributed store, takes over and carries **one million plus messages per
second**. Graduating is an infrastructure swap, not a product rewrite,
precisely because the contract was the invariant and the topology never was.

The honest ledger of starting small: a crashed window loses at most one
window of data that was going to expire in minutes anyway; nobody else can
tap the stream; the ceiling of one machine is real; and a windowed pile of
SQLite files is something you have to explain to your SRE. In exchange you
deploy one binary in one container, you control backpressure end to end in
channel semantics, restart recovery is a directory listing, and per-core
performance is predictable because no state is shared across shards.

Start with the system that is simple enough to be obviously correct, measure
the headroom, and keep the infinite one for the day the measurements demand
it. Worse is better, until it is not, and your metrics will tell you when.

If you want to talk about the pattern, or you think I got a trade-off wrong,
don't be afraid to contact me, I will gladly help in what I can.
