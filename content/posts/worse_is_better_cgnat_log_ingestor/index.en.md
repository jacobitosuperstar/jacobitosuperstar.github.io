---
title: '"Worse is Better", Building a CGNAT Log Ingestor in Go'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["go", "SQLite", "Kafka", "Architecture", "CGNAT"]
categories: ["programming"]
---

There is an old essay by Richard Gabriel, _The Rise of Worse is Better_, that
argues that the system that is simple to implement and covers most of the cases
beats the complete, correct, complex one in practice. Startup culture ended up
proving the point without meaning to: getting to market fast with a good idea
half executed, and turning it into a real product eventually, is worth more than
arriving late with the perfect one.

At the same time, in a counterintuitive and contradictory way, with the unicorns
and the growth-based companies came the opposite idea: that every system has to
be infinitely scalable, designed from day one for an endless stream of features
and for horizontal growth. What that leaves behind, as far as I am concerned, is
badly made software distributed across every product a cloud vendor is willing
to sell you.

This article presents a CGNAT log ingestor that, under the current ideas of
software, would be classified as "worse". With it I want to question the very
notion we keep being sold, that solving for today's problem instead of
tomorrow's is technical debt, while also showing how to deal with the
complications that keeping everything simple brings with it.

## The Problem

Carrier-Grade NAT (CGNAT) is how an ISP puts thousands of subscribers behind a
small pool of public IPv4 addresses. Every CGNAT device emits a log line for
every session it handles, from creation, through periodic sustains, to release,
and the people operating that network need to answer one question fast: _which
subscriber was behind this public IP and PORT a moment ago?_ The same
information is needed from three different directions: by public address and
port, by private address and port, and by subscriber.

Three properties of this workload drive every decision downstream:

- **Extremely high write rate**: tens of thousands of log lines per second
  arrive over syslog, continuously.
- **Extremely short retention**: a mapping only matters for minutes. The idea is
  to have a real-time capture of what is happening in the network.
- **Most-recent-wins reads**: every lookup requires the latest mapping for a
  key.

## The Initial Approach

The initial idea was a distributed system capable of redirecting a sequential
log-generation process into a distributed processor of those logs.

To get there, I followed a single CGNAT record through the chain of
transformations it would live through:

```
 Carrier SysLog -> receiver -> parsing -> storage <- query api <- user
```

For one record, I picked up the different parts of the process. The main idea is
to check out how each part of the process plays out in a sequential manner,
trying to distance myself from concurrency models first, as non-deterministic
execution can throw a wrench in all of my understanding.

When I am done with that, I try to analyze the system with two records and try
to find the common parts between the processes. When I see two records at the
same time, I can find two crossing points, the receiver, as all the messages
come sequentially at max speed, and in the storage, as there is where all of the
messages in the current Time To Live window will co-exist.

That told me which two data structures I had to choose well. After reception I
needed something that lets the receiver hand a message off and return to the
socket immediately, because a datagram the receiver is not ready for is a
datagram lost: a bounded queue, absorbing the bursts and decoupling the rate at
which messages arrive from the rate at which they are parsed. And for storage I
needed something that could swallow tens of thousands of writes per second.

Because the amount of records outmatches the amount of writes that a database
can handle, I had to think of another structure, like an iterable collection, to
batch all the records that come.

Those two things divide the software into two main parts: the ingestor, which
needs to be light and agile, and the writer, which needs to parse and prepare
the data for the database writing.

## Complexity Sold as Simplicity

As a question for all systems as they are being designed, _How does the solution
scale?_ was presented. That seemed simple enough: as the receiver needs to
receive the messages from the UDP sequentially, it became the main performance
bottleneck, and because I would store everything into queues, the serialized
work becomes horizontally scalable, as different writers can pick from different
parts of the queue as it fills out. And the system starts to look like this:

```
             CGNAT devices (syslog UDP)
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
        │ writer  │  │ writer  │  │ writer  │  parse · batch · write
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
bursts when the store lags, and it gives you replay when a writer crashes.
Partitions are the scale-out lever: add partitions and writers, and the pipeline
follows. The consumer group gives you crash recovery without writing any
coordination code. Scaled out, this design tracks the full firehose of a large
carrier: **one million plus messages per second**.

For storage, I picked Cassandra, because it is built for exactly this shape of
workload. A distributed wide-column database partitions the data by key across
the cluster, so write capacity scales horizontally by adding nodes. Its storage
engine is log-structured: incoming writes land in an in-memory table that is
periodically flushed into immutable, sorted files on disk, and reads are served
from those same immutable files, so writers never rewrite what readers are using
and concurrent reads and writes barely touch each other. Record removal is in
the storage layout: rows carry a TTL, and with time-windowed compaction the rows
of a time window end up in the same files, so expired data is dropped as whole
files instead of row by row.

This design is correct. The point of this article is not that it is wrong. But
it wasn't until we started the deployment of it that it began to dawn on me.
_"Could you tell me what are the actual numbers of the messages per second that
their CGNAT is producing?"_, I asked. _"**25k** messages that can burst into 34k
messages per second"_, I was told.

5 different containers, for a number that was a fraction of what the design is
possibly capable of, was not only a waste of resources, it felt like I had
overbuilt the solution. The parts of the system are simple on their own, but
extremely complex to integrate, debug and maintain.

## What Technical Debt Really Is

Because of the notion that most software that we run is single core and single
threaded, we tend to associate non-horizontal scalability with debt, but that is
not the reality at all; we just have to create a more robust design for us to be
able to use the full capabilities of the machines that we work with. The main
point of technical debt is the creation of software whose process and specific
requirements we don't understand.

When creating the first solution, I feel that I really didn't understand the
requirements of the software, as I created a general solution that didn't really
quite fit the necessities of the client. Decisions have a time and a place.
Current design decisions, if made properly, respond to the current understanding
of the problem, and if in the future the requirements, problems or behaviour
characteristics change, we shouldn't be afraid to refactor our code.

A subscriber session produces one message when it is created, one every few
minutes while it stays alive, and one when it is released, giving us a fraction
of a message per second per user. Flip the relation around, and for the 25k
messages per second we measure, bursting into 34k at rush hour, to merely
double, the client would need to gain millions of subscribers overnight. Against
that, the infrastructure we deployed was rated at more than a million messages
per second, roughly thirty times the rush hour. User growth was never the thing
to design for here; no carrier gains millions of subscribers unannounced.

## Simplicity

Starting over, this time from the requirements instead of from the architecture,
I asked what the workload actually demands now:

- **Retention is minutes.** "Durability" means surviving one storage window.
- **The source is UDP syslog.** The transport is lossy before the message ever
  reaches the software, so the best any pipeline can do is not add loss of its
  own.
- **We are targeting first a single machine as the deploy unit.** The whole
  pipeline ships together, so "distributed" never actually crosses a machine
  boundary, but it does cross a software one. If the performance is not there we
  can start separating the solution again, but by parts.

## Cores as Shards, the One Scaling Knob

A simpler solution was created. It keeps the idea of using partitions for the
writes, where what I wanted to offload was the storage process, but the
partition becomes a goroutine instead of a broker partition. The shard count is
derived from `runtime.GOMAXPROCS(0)`, which represents the number of processors
the container has, as more shards buy nothing on a CPU-bound path, which in this
case is the write path.

```
    syslog (UDP)
         │
         ▼
    listener ──► parse queue ──► parse workers ──► store queue ──► store
                   (chan)                            (chan)       workers
                                                                 (1 per core)
                                                          ┌───────────┘
                                                          ▼
                            in-memory map  +  in-memory SQLite window
                                  │                        │ seal
                                  ▼                        ▼
        query API  ◄──────── live map first, then sealed, indexed,
                             read-only files · dropped after TTL
```

Each core owns a store worker, its own in-memory SQLite window, and its own live
key maps. Sealed files embed the shard ID and a timestamp in the filename, and
reads walk the files newest-first until the first hit, so there is no
cross-shard coordination anywhere. Throughput scales by editing one line in the
deployment spec: the CPU limit.

## Windowed SQLite, and the Storage System as a Sealing Protocol

The write path is an in-memory SQLite database with **zero indexes** and the
durability pragmas turned off. That sounds reckless until you remember it is
RAM: the durable copy is the one on disk. An insert is an index-less append
inside a batched transaction, the cheapest possible hot path, because no B-tree
has to be maintained per row.

Every few seconds, or when the window hits its row cap, the window **seals**:

1. `VACUUM INTO` a temporary file on disk.
2. Build the three query indexes on that sealed copy, once, in bulk.
3. Atomically rename it into place.

The rename is the sealing protocol. Readers only glob completed files, so a
half-written seal is invisible to them. Recency is encoded in the timestamped
filenames, so "newest first" is a filename sort. The seal runs in its own
goroutine while the worker opens a fresh window and keeps ingesting, so disk I/O
never blocks intake.

TTL enforcement is the same trick the wide-column store was doing with
time-windowed compaction, implemented with nothing but files: expired data is
dropped by unlinking whole files, never by row deletes. The cleaner keeps a
safety margin comfortably past the nominal TTL, and a minimum file count derived
from the TTL, the window length and the shard count, so it always errs toward
keeping data. And because sealed files are just files, a restart re-loads
whatever has not expired: warm start needs zero recovery code, because the files
on disk _are_ the metadata. When the system restarts, only the current storage
window is lost, plus the time that the container needs to reset.

## Real-Time Data

A record is not sealed to disk for up to one window, so each shard also keeps
live in-memory maps over its open window, one map per query axis, all pointing
at the same record. "Most recent mapping" falls out of map-overwrite semantics,
no ordering structure at all. The handoff is the part that has to be exact: the
new window's maps are registered _before_ they take traffic, and the old ones
are removed only _after_ their seal finishes writing to disk, so every record is
findable in at least one place at every instant. And if seals ever fall behind
and the registry fills, the window degrades to disk-only with a warning instead
of blocking ingest as write-path availability outranks query freshness.

## Ports Have Buffers Too

During a seal, a one-core pod pauses ingest for a beat. With Kafka gone, the
only buffer between that pause and the wire is the kernel's UDP socket receive
buffer, and at the OS default size (about 208 KB) it silently drops the
overflow, before it reaches our software. Because of this, even though we were
dropping messages, every counter we owned read zero drops while packets were
vanishing. The fix was simple: force a receive buffer large enough to bank a
whole seal's worth of datagrams, using `SO_RCVBUFFORCE`.

## Vertical Headroom

With the current design, each added core (3.6 GHz) buys approximately 45k
messages per second and costs about 1.4 gigs of RAM and 2.5 gigs of storage,
while live queries keep answering in around 20 ms.

To size the machine I worked backwards from failure: what would have to happen
for this design to be too small? A 4-core pod handles around 180k messages per
second, more than five times the rush hour, and since every user adds only a
fraction of a message per second, a jump like that would take millions of new
subscribers arriving unannounced.

## End Note

At the end, the main takeaway is that we should always start small and
self-contained. Wrap your head around a system that is simple enough to be
obviously correct, separate which processes need to be sequential, which
processes can be concurrent, design it, measure it, create headroom for it, and
try to keep the infinite infrastructure approach in your back pocket. Worse is
better, until it is not.

If you want to discuss things of this nature, tell me that I got it wrong, or
show me something interesting, don't be afraid to contact me, I will gladly
respond to your call.
