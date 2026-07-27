---
title: '"Worse is Better", Building a CGNAT Log Ingestor in Go'
date: 2026-07-03T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["go", "SQLite", "Kafka", "Architecture", "CGNAT"]
categories: ["programming"]
---

Richard Gabriel wrote an essay with the name _The Rise of Worse is Better_. The
essay says that a simple system that does most of the necessary work is better
in operation than a complete, correct, and complex system. Startup culture
showed that this idea is correct. It is better to go to the market early with a
good idea in a partial condition, and then make a full product. It is worse to
come late with the perfect product.

At the same time, the large growth companies gave us the opposite idea. This
idea says that each system must scale without limits. From its first day, the
design must be ready for an unlimited flow of features and for horizontal
growth. For me, the result is bad software, divided across each product that a
cloud vendor can sell to you.

This article shows a CGNAT log ingestor. By the current ideas of software
design, this ingestor is "worse". With this ingestor, I want to examine the
idea that a solution for the problems of today, and not of tomorrow, is
technical debt. I also want to show how to control the problems that a simple
design causes.

## The Problem

Carrier-Grade NAT (CGNAT) is the method with which an ISP puts thousands of
subscribers behind a small group of public IPv4 addresses. Each CGNAT device
writes one log message for each event of a session: creation, periodic sustain,
and release. The operators of the network must answer one question quickly:
which subscriber was behind this public IP address and port a short time
before? The operators must have the same data in three directions: by public
address and port, by private address and port, and by subscriber.

Three properties of this workload control each subsequent design decision:

- **A very high write rate**: Tens of thousands of log messages come each
  second through syslog, continuously.
- **A very short retention**: A mapping is important only for minutes. The
  function of the system is to show the network activity in real time.
- **Most-recent reads**: Each lookup must find the most recent mapping for a
  key.

## The First Design

My first idea was a distributed system. This system receives one sequential
flow of logs and divides the work across many parallel processors.

To design the system, I followed one CGNAT record through each step of the
process:

```
 Carrier SysLog -> receiver -> parse -> storage <- query api <- user
```

For one record, I examined each part of the process, one part after the other.
I did not think about the concurrency models at this point, because
non-deterministic operation makes the analysis difficult.

Then I did the analysis again with two records, to find the common parts of the
two processes. The two records have two common points. The first point is the
receiver, because all the messages come there in sequence, at maximum speed.
The second point is the storage, because all the messages of the current
Time-To-Live (TTL) window are there at the same time.

This analysis showed me the two data structures that I had to select correctly.
The receiver must send each message forward and then go back to the socket
immediately. A datagram that comes when the receiver is not ready is a lost
datagram. Thus the first structure is a bounded queue. The queue holds the
bursts. The queue also disconnects the rate of arrival from the rate of the
parse work.

The second structure is for the storage. The number of records is larger than
the number of writes that a database can do. Thus a collection structure must
collect the records into batches.

These two structures divide the software into two main parts. The ingestor must
do the minimum work possible. The writer must parse the data and prepare the
data for the database.

## The Complex Design

During the design, the usual question came: how does the solution scale? The
receiver must receive the UDP messages in sequence. Thus the receiver is the
primary performance bottleneck. All the other work goes through queues.
Different writers can read from different parts of the queue. Thus the
serialized work becomes horizontally scalable.

The system then has this structure:

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

Each part of the system has a function. Kafka is the buffer that holds the
bursts when the store is slow. Kafka also gives replay of the messages when a
writer fails. The partitions control the scale: more partitions and more
writers give more throughput. The consumer group gives recovery after a
failure, without coordination code. At full scale, this design can receive the
full traffic of a large carrier: more than 1,000,000 messages each second.

For the storage, I selected Cassandra, because its design is for exactly this
type of workload. A distributed wide-column database divides the data by key
across the cluster. Thus the write capacity increases when you add nodes. The
storage engine is log-structured. New writes go first into a table in memory.
At intervals, the engine writes this table to the disk as sorted files that do
not change.

The reads come from those same files. Thus the writers do not change the data
that the readers use, and the reads and the writes have almost no effect on
each other. The removal of records is part of the storage layout. Each row has
a TTL. Time-window compaction puts the rows of one time window into the same
files. Thus the engine can discard the old data as full files, and not row by
row.

This design is correct. This article does not say that the design is wrong. But
during the deployment, I found the problem. I asked: "What is the true number
of messages each second from your CGNAT?" The answer was: "25,000 messages each
second, with bursts to 34,000 messages each second."

The design used five different containers for a load that was a small part of
its possible capacity. This was a waste of resources, and the solution was too
large. Each part of the system is simple when the part is alone. But the
integration, the debug work, and the maintenance of all the parts together are
very complex.

## Technical Debt

Most of the software that we use is single-core and single-thread software.
Because of this, we think that software that does not scale horizontally is
debt. This is not correct. A better design lets us use the full capacity of our
machines. The true cause of technical debt is different. Technical debt occurs
when we make software, but we do not understand its process and its specific
conditions.

When I made the first solution, I did not understand what the software had to
do. I made a general solution that was not correct for the client. A decision
is correct only for its time and its conditions. A good design decision agrees
with the current knowledge of the problem. If the problem or the behavior of
the system changes in the future, then we must refactor the code.

A subscriber session sends one message at its creation, one message at
intervals of some minutes, and one message at its release. Thus each user makes
less than one message each second. We measured 25,000 messages each second,
with bursts to 34,000 messages in the busy hour. To make this number two times
larger, millions of new subscribers must come to the client in one night.

The deployed infrastructure had a capacity of more than 1,000,000 messages each
second. This is approximately 30 times the load of the busy hour. Growth of the
number of users was not the correct design target. Millions of new subscribers
do not come to a carrier without warning.

## Simplicity

I started again. This time I started from the workload, not from the
architecture. I asked: what is necessary for the workload now?

- **The retention is minutes.** "Durability" means that the data stays
  available for one storage window.
- **The source is UDP syslog.** The transport loses messages before the
  messages come to the software. Thus the best pipeline is a pipeline that adds
  no loss of its own.
- **The first deployment unit is one machine.** All the parts of the pipeline
  go together in one deployment. Thus "distributed" does not go across a
  machine boundary, but it goes across a software boundary. If the performance
  is not sufficient, we can divide the solution again, part by part.

## One Shard for Each Core

I then made a simpler solution. The solution keeps the idea of partitions for
the writes. But each partition is now a goroutine, not a broker partition. The
number of shards comes from `runtime.GOMAXPROCS(0)`, which gives the number of
processors of the container. More shards do not increase the performance,
because the write path is CPU-bound.

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

Each core has one store worker, one SQLite window in memory, and its own set of
live key maps. The name of each sealed file contains the shard ID and a
timestamp. A read examines the files from the newest to the oldest, and stops
when it finds the record. Thus no coordination between the shards is necessary.
To increase the throughput, you change one line in the deployment
specification: the CPU limit.

## SQLite Windows and the Seal Procedure

The write path is a SQLite database in memory, with **zero indexes**, and with
the durability pragmas set to off. This is not a risk, because the database is
in RAM. The durable copy is the copy on the disk. An insert is an append in a
batched transaction, and the engine does not adjust a B-tree index for each
row. Thus this write path has the lowest possible cost.

The window "seals" at intervals of some seconds, or when the window comes to
its row limit:

1. The worker writes the window to a temporary file on the disk with
   `VACUUM INTO`.
2. The worker makes the three query indexes on that copy, one time, for all the
   rows.
3. The worker renames the file to its final name in one atomic operation.

The rename operation is the seal protocol. The readers find only the completed
files. Thus the readers cannot see a partially written seal. The timestamp in
each filename shows the age of the data. Thus "newest first" is only a sort of
the filenames.

The seal operation occurs in its own goroutine. At the same time, the worker
opens a new window and continues the intake. Thus the disk I/O does not stop
the intake.

The TTL procedure uses the same principle as the time-window compaction of the
wide-column store, but with files only. The cleaner removes old data when it
deletes full files. The cleaner never deletes data row by row. The cleaner
keeps a safety margin after the nominal TTL. The cleaner also keeps a minimum
number of files, which comes from the TTL, the window length, and the shard
count. Thus, if there is an error, the cleaner keeps too much data, not too
little.

The sealed files are only files. Thus, after a restart, the system loads all
the files that are not expired. A warm start uses zero recovery code, because
the files on the disk _are_ the metadata. After a restart, the loss is only the
current storage window, plus the time that the container uses to start.

## Real-Time Data

A new record does not go to the disk immediately. The record can stay in the
open window for a maximum of one window length. Thus each shard also keeps live
maps in memory for its open window. There is one map for each query axis, and
all the maps refer to the same record. The overwrite operation of a map keeps
the most recent mapping. No order structure is necessary.

The change from one window to the next must be exact. The system registers the
maps of the new window _before_ the new window receives traffic. The system
removes the old maps only _after_ the seal of the old window is complete on the
disk. Thus each record is available in one location or more, at all times. If
the seals become slow and the registry becomes full, the window changes to
disk-only mode and gives a warning. The intake does not stop, because the
availability of the write path is more important than the most recent query
data.

## The UDP Socket Buffer

During a seal, a pod with one core stops the intake for a short time. Kafka is
not in this design. Thus the only buffer between that stop and the network is
the UDP receive buffer of the kernel. The default size of this buffer in the OS
is approximately 208 KB. When this buffer is full, the kernel drops the
overflow before the data comes to our software, and gives no indication. Thus
our counters showed zero drops while the kernel dropped packets.

The correction was simple. We set a receive buffer that is sufficiently large
for the datagrams of one full seal, with the `SO_RCVBUFFORCE` option.

## The Vertical Margin

With the current design, each added core (3.6 GHz) adds capacity for
approximately 45,000 messages each second. Each added core uses approximately
1.4 GB of RAM and 2.5 GB of storage. The live queries continue to give answers
in approximately 20 ms.

To calculate the machine size, I started from the failure point: what must
occur to make this design too small? A pod with 4 cores can receive and store
approximately 180,000 messages each second. This is more than five times the
load of the busy hour. Each user adds less than one message each second. Thus
an increase of that size is possible only if millions of new subscribers come
without warning.

## End Note

The most important point is this: start small, and keep the system in one unit.
First, understand a system that is sufficiently simple to be clearly correct.
Find the processes that must be sequential and the processes that can be
concurrent. Design the system, measure the system, and give the system a margin
of capacity. Keep the infinite infrastructure as a possible subsequent step.
Worse is better, until it is not.

Do you want to speak about these subjects? Do you think that I am wrong? Do you
have something new to show me? Please contact me. I will reply.
