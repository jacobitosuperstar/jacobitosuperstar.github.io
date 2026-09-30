---
title: From couples to single. Microservices as Objects
date: 2026-09-27
draft: false

read_more: Read more...
tags: ["Python", "Go", "Design", "microservices", "microkernel"]
categories: ["programming"]
---

After being dumped by my girlfriend, I regained a lot of time that I had devoted
before, so I started to think about the boundaries of our relationship,
communication issues, and patterns that instead of making two distinct and
different people, made us a singular blob that just happens to be in two places
at the same time. And then it hit me, I should be using a different architecture
than microservices for systems that have similar designs.

Like many of you, I have encountered systems that go down the microservices
design path in search of distributing work, but that keep the main application
as a single point of failure, with nodes whose traffic is proportional to that
of the main process that distributes the work. In the case we are going to
analyse, the main app only does I/O, its microservices also do a bunch of I/O,
and those microservices depend solely on the traffic of the main application.
Meaning the microservice behaves as a subroutine.

As specific as that sounds, these are really common systems. The point of that
solution is to keep the single point of failure as simple as possible and
offload work to the different microservices that compose the system. So I began
to think, are microservices the answer for a system like this, is the modular
monolith the answer or are there other designs that we can look into to attack
these types of designs?

There is always a need to define what the boundaries of two domains are, to what
extent they need to be separated, and how they need to be separated. There are
cases where **microservices are the only option**, like when we need to encode
video, process images or do some other CPU-heavy task. Or when a piece of logic
needs to be used by several systems at the same time, and the boundary between a
library and a service is clearly defined, because that service requires a
different environment, language, security model, etc. **Making the network part
of the problem instead of the overhead around it**.

## THE PROBLEM

As always, me. But for everything else, the first thing that one must think of
is what you are actually trying to solve, and there are two things that I want
to tackle.

1. Networking. When we offload the work from the main program to its
   microservices, we add the latency of a round trip to every response, and we
   add the fickleness of network connections to the main processes of our
   system.

2. Efficiency and Costs. When we start spawning workers that depend directly on
   the traffic of our main service, we are adding more containers than are
   needed for the solution of a problem. Making the problem require more
   resources for its solution and, with the ever-increasing costs of renting
   infrastructure, you have to think about how many points of your profits can
   be tied to them.

## CODE CONSTRAINTS

The main idea of this implementation is to keep as much code as possible from
the microservices. Meaning, even though there may be more efficient ways to code
these types of solutions, the point of this is to do a transition, mainly,
rewrite the adapter between the main process and the microservice in a way that
we can ditch the network call without having to change the current logic of
either the microservice or the main application.

## THINKING ABOUT NEW IDEAS

The microservices in this sense give us several advantages that we have to take
into account when evaluating a solution, and those are,

1. Operational Isolation. When a microservice process fails to start, it's just
   a worker that failed to start. Not the whole application.

2. Independent Scaling when the traffic is mixed and uneven.

3. Plugin design. We can add and route different parts of the system to
   different workers. For example, if we need to have two of the same worker
   with different configurations, like a worker that sends emails to A and
   another that sends emails to B, it is just a routing conditional and we have
   two of the same worker serving different purposes.

And I thought, after all the self-reflection and self-healing that I did while
sobbing, that there is a system design that covers these things without the need
to send those workloads over the network.

Two architectures came to my mind.

**Microkernel** in the sense that we have a minimal core application that owns
transport, routing, errors and observability, plus plugins that own the domain
behaviour.

**Hexagonal Architecture** which is what we currently have, but instead of
leaving the adapters over the network, we would create the interface in the main
app that interacts with each one of the objects that we are running.

The modular monolith architecture, as it is normally understood, is a big block
with all of these components initialized together, where each of the well
defined domains has an API that the main process calls. That is not sufficient
for our implementation, so a microkernel-like approach is added to achieve
plugin design and operational isolation.

For this I thought of objects that hold the logic of the microservice, that can
carry a state (like a continued connection to a DB, authentication credentials,
and things like that) while also executing the logical steps that the
microservice did. And in case of failure, they would have their own retry logic
elsewhere and if a call from the main process is sent here, we will quickly
return a not-available error and not let the system overload or spend cycles on
processes that don't start.

## THE DESIGN

As for the migration from the distributed monolith to this, I thought of three
parts: the main application, the interface between the main application and the
objects, and the objects, each one holding the logic of one microservice. The
interface is the only thing that the main application and the objects' code have
in common. The application routes the jobs through that interface, each
registered object (the old microservice) is initialized, and then it is loaded
into that interface.

```
┌──────────────────────────────────────────────────────────┐
│                       MAIN SYSTEM                        │
│                                                          │
│  ┌─────────┐        ┌───────────┐        ┌───────────┐   │
│  │         │ calls  │           │ feeds  │   MICRO   │   │
│  │   API   │───────▶│ INTERFACE │◀───────│ SERVICES  │   │
│  │         │        │           │        │ (objects) │   │
│  └─────────┘        └───────────┘        └───────────┘   │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

For the interface, the map is the most flexible structure to hold things like
this, as we can define the key that routes to that object and as the value we
can have an optional type, so that key can return the object that represents the
microservice or NULL. And the keys are strings that we can modify, create or
change however we see fit. Those also resemble the string that holds the
microservice URL so the idea is to have this in case there are similar routing
mechanisms, mainly ones that work through string manipulation.

Two maps compose the registered objects. One holds the objects that initialized
successfully and are working. The other holds the objects that failed to
initialize, or that fail after initialization, like an object that tries to
connect to a database that is unavailable after start-up. That second map has
the logic that retries their initialization at different stages of the
application (exponential back off or any other strategy you see fit), completely
independent of their in-process calls. That way we can quickly return failed
responses without overloading the system with per-request evaluations.

Between them, those two maps hold every object that the app used to offload to
the network.

Over the network we never received an exception from a microservice, we received
a status. The interface keeps that contract, so the answer of a worker is a
value and not something thrown at us. Three outcomes are enough:

```python
from dataclasses import dataclass
from enum import Enum
from typing import Protocol

class Outcome(Enum):
    OK     = "ok"       # the work is done
    ERROR  = "error"    # this request failed, the worker is fine
    BROKEN = "broken"   # the worker cannot work, take it out of the map

@dataclass
class Answer:
    outcome: Outcome
    body:    dict | None = None
    status:  int  | None = None   # for ERROR, the status the microservice used to send
    detail:  str  | None = None

# what the core needs from any worker. Nothing about how it is done.
class Worker(Protocol):
    def start(self) -> Answer: ... # connect, authenticate, warm up
    def handle(self, operation: str, request: dict) -> Answer: ...

REGISTRY:    dict[str, Worker] = {}   # working
UNAVAILABLE: dict[str, Worker] = {}   # broken, the supervisor is retrying them
```

The map could be built from configuration, in case we may need to load different
kinds of workers for different instances, or self-adding objects, which add
themselves into the registry after their initialization code is executed. If
there is an object representing a microservice that is not being used, it is not
an issue, as the object would just sit in memory without doing anything, but
it's not hard to implement an evaluator, just to make sure that we only load the
objects that we are going to use.

```python
def build_registry(config):
    for key, spec in config["routes"].items():
        kind = KNOWN_KINDS.get(spec["kind"])
        if kind is None:
            raise SystemExit(f"unknown kind: {spec['kind']}")   # config error, stop
        worker = kind(spec["settings"])
        target = REGISTRY if worker.start().outcome is Outcome.OK else UNAVAILABLE
        target[key] = worker

    missing = config["required_keys"] - REGISTRY.keys() - UNAVAILABLE.keys()
    if missing:
        raise SystemExit(f"routes without a worker: {missing}")
```

And the route becomes a lookup and a call, the same shape it had when the worker
was a network call, which is the point:

```python
async def route(request):
    key    = key_of(request)
    worker = REGISTRY.get(key)
    if worker is None:
        return 503

    answer = await asyncio.to_thread(worker.handle, request.operation, request)

    if answer.outcome is Outcome.BROKEN:
        move(key, REGISTRY, UNAVAILABLE)   # the next request does not even try
        return 503
    if answer.outcome is Outcome.ERROR:
        return answer.status               # the worker is fine, this request is not
    return answer.body
```

Every failure that the core must act on arrives as a value that it can read. The
exceptions stay inside each object, where the libraries raise them.

Two workers of the same kind with different settings is now a second entry in
the map, not another element to deploy:

```
routes:
  "notify.a" : { kind: "email", settings: { provider: A } }
  "notify.b" : { kind: "email", settings: { provider: B } }
```

### Isolation is a property of the object, not of the process (double entendre)

If an object fails, either during initialization or in process, what we need to
add is just the failsafe mechanism where we move it to the unavailable registry
and retry its initialization from there. When the requests do the lookup, they
will get a NULL -> 503 immediately, without taking down the application.

The object is the only one that knows which of its failures are normal and which
of them mean that it cannot work any more:

```python
class Email:
    def start(self):
        try:
            self.connection = connect(self.settings)
            return Answer(Outcome.OK)
        except (ConnectionError, AuthError) as error:
            return Answer(Outcome.BROKEN, detail=str(error))

    def handle(self, operation, request):
        try:
            return Answer(Outcome.OK, body=self.run(operation, request))
        except NotFound:
            return Answer(Outcome.ERROR, status=404)             # expected, normal
        except (ConnectionError, AuthError) as error:
            return Answer(Outcome.BROKEN, detail=str(error))     # I cannot work
        except Exception as error:
            return Answer(Outcome.ERROR, status=500, detail=str(error))  # a bug, not an outage
```

Nothing leaves `handle` as an exception. The last `except` is the same thing a
server did before: an error it didn't expect became a 500, and the process kept
serving.

When one of the objects is in a broken state, it is just checked out by a
supervisor where we run an exponential back off reinitialization, so we can put
it back to the router when it's available, but also, we don't waste too many
resources in case it never recovers.

```python
async def supervisor():
    delay    = {}   # key -> seconds until the next attempt, doubles on each failure
    retry_at = {}   # key -> when to try again
    while True:
        for key, worker in list(UNAVAILABLE.items()):
            if time.monotonic() < retry_at.get(key, 0):
                continue
            if (await asyncio.to_thread(worker.start)).outcome is Outcome.OK:
                move(key, UNAVAILABLE, REGISTRY)
                delay.pop(key, None)
                retry_at.pop(key, None)
            else:
                delay[key]    = min(delay.get(key, 0.5) * 2, 300)   # exponential back off
                retry_at[key] = time.monotonic() + delay[key]
        await asyncio.sleep(1)


def move(key, source, target):
    worker = source.pop(key, None)
    if worker is not None:
        target[key] = worker
```

`worker.start()` is blocking code as well, so the supervisor goes through a
thread too. A worker that reconnects must not stop the loop of everybody else.

`move` needs no lock. Only `route` and the supervisor touch the maps, and both
run on the event loop, one step at a time. The threads only ever run `handle`
and `start`.

### Clear boundaries, like in a relationship, must exist between the domains too

I took her to my father's grave... Anyway. The main app and the objects don't
have to share a concurrency model, because they never touch each other. The
interface sits between them, and how the jobs run is part of its domain, like
everything else that has to do with the microservices. The main app calls the
interface in its own model, and the interface runs each job in its own model.
That way, we can leave the code completely untouched and make the interface do
the translation job between them.

In my case the main app was async Python (FastAPI) and the microservices were
blocking code (synchronous clients), so every microservice job needs to go
through `asyncio.to_thread` to be able to run without blocking the main
application.

This bridge exists because Python has two concurrency models that don't mix,
async code and blocking code. A language with a single, native concurrency
model, like Go or Erlang, doesn't need this kind of translation layer between
the domains.

The translation is not free. In my measurements one object call cost 0.065 ms of
CPU and the work inside it only 0.018 ms, the rest was the jump to the thread
and back. Still a tenth of the 0.69 ms that the same call cost over gRPC [^2].

Because the thread pool runs several calls of the same object at the same time,
the object is shared. That is safe as long as the object doesn't change after
start-up: anything that belongs to one request lives in the parameters and local
variables of `handle`, never on the object.

## COSTS

### It's not cope when the costs have my back

Forget about my ex, I didn't even love her anyway. The point of all of this is a
simpler system, that just has a bit more "creativity" in the interface layer,
with the bonus that it's cheaper to run. A sad meal for one instead of a happy
meal for two, if you get what I am saying. It's a no-brainer.

Every call across the boundary between the domains costs time: serialise, cross
a socket, deserialise, schedule in a second runtime, and the same again coming
back. But also, if the traffic of the worker depends only on the calls of the
main process, the worker is never full. You pay for that spare capacity. In one
container the same work scales as one unit, and the CPU and RAM move between the
parts of the system as the traffic moves.

The **requests per pod go up when you split**, because part of the work moved to
another pod. Anybody measuring that will conclude the split is faster. The real
measurement is **cost per request**: CPU-seconds and bytes of memory for the
same unit of **work**.

The following numbers represent a FastAPI app that offloads work to different
workers. To put the microservices in their best-case scenario, we will assume
that all the requests that come to the main application are deferred not to
several microservices but to just one, in the same network, on the same machine.

It helps to see which parts of a request cost what, and which of those parts the
architecture can remove. These are CPU milliseconds for one request, measured on
one machine [^1].

| part of the request                                           | ms    | a faster CPU helps | the split adds it             |
| ------------------------------------------------------------- | ----- | ------------------ | ----------------------------- |
| the work: parse, validate, the domain logic, build the answer | 4.00  | yes                | no, it is the same either way |
| the hop, CPU: serialise, deserialise, wake two schedulers     | ~0.76 | yes                | yes                           |
| the hop, transit: the kernel and the wire                     | ~0.10 | **no**             | yes                           |

**With a faster CPU** the first two rows shrink. The third does not. A socket, a
system call and a scheduler wake-up take the time they take.

**Putting everything together** removes the second and third rows. The first one
stays exactly as it was, because it is the work you came to do. That is 0.86 ms
of CPU less for every request, and about 1 ms less of response time: at 200
requests each second the median went from 6.0 ms to 4.8 ms, and at 250 from 5.9
ms to 4.9 ms. Also, that hop in Python seems too low to consider, but if you
were to use a faster language, that hop could be as long as the work we actually
need to do. It's like saying to your partner that you will be there, and just
dissociate from everyone, especially her, while working, because you are trying
to have a career, or something.

### Let me finish the argument, don't be like her

All you need is how many requests each second one pod answers at its limit, for
each shape. The Python numbers come from the same machine as before [^1]. The Go
values are an illustrative example from another system with the same shape: a
main app that does I/O and hands every request to one worker that also does I/O,
and whose traffic comes only from the main app. It is not the same application
as the Python one, so the numbers are more illustrative than anything else.

```
                   Python (FastAPI)        Go (illustrative)
main service       350 req/s               2,750 req/s
microservice       500 req/s               3,900 req/s
merged service     250 req/s               2,500 req/s
```

For the infrastructure calculation, you round up once for the main app, and once
more for every worker that you split the work into.

```
merged pods = ceil(R / merged)
split  pods = ceil(R / main) + workers * ceil((R / workers) / microservice)
```

With one worker the second term is just `ceil(R / microservice)`, because all of
the traffic goes to it.

#### Python

| Req/s     | merged | split         | additional cost |
| --------- | ------ | ------------- | --------------- |
| 100/s     | 1      | 2 (1+1)       | +100%           |
| 1,000/s   | 4      | 5 (3+2)       | +25%            |
| 2,000/s   | 8      | 10 (6+4)      | +25%            |
| 3,000/s   | 12     | 15 (9+6)      | +25%            |
| 4,000/s   | 16     | 20 (12+8)     | +25%            |
| 5,000/s   | 20     | 25 (15+10)    | +25%            |
| 10,000/s  | 40     | 49 (29+20)    | +22%            |
| 100,000/s | 400    | 486 (286+200) | +22%            |

#### Go

| Req/s     | merged | split      | additional cost |
| --------- | ------ | ---------- | --------------- |
| 100/s     | 1      | 2 (1+1)    | +100%           |
| 1,000/s   | 1      | 2 (1+1)    | +100%           |
| 2,000/s   | 1      | 2 (1+1)    | +100%           |
| 3,000/s   | 2      | 3 (2+1)    | +50%            |
| 4,000/s   | 2      | 4 (2+2)    | +100%           |
| 5,000/s   | 2      | 4 (2+2)    | +100%           |
| 10,000/s  | 4      | 7 (4+3)    | +75%            |
| 100,000/s | 40     | 63 (37+26) | +57%            |

#### Python, with four workers

The two tables above split the work in two. Now cut it in four, which is what
happens when the domain boundaries follow [Conway's law][1] instead of the
traffic. The main app receives the requests and routes each one to the worker
that owns that kind of work. A request still crosses one boundary, so the cost
of a request does not change.

| Req/s    | each worker gets | merged | split, four workers | additional cost |
| -------- | ---------------- | ------ | ------------------- | --------------- |
| 100/s    | 25/s             | 1      | 5 (1 + 4x1)         | +400%           |
| 1,000/s  | 250/s            | 4      | 7 (3 + 4x1)         | +75%            |
| 10,000/s | 2,500/s          | 40     | 49 (29 + 4x5)       | +22%            |

At 1,000 requests each second each worker receives 250. Between them they need
two pods of capacity and you rent four, because a worker cannot have half a pod.
At 100 each second they need a fifth of a pod and you still rent four. At 10,000
the additional cost is the same as when splitting into a single microservice.

### Where the additional cost comes from

A pod is indivisible, so the remainder is capacity that you rent and never use,
and that is what the additional cost is made of. That's why there are points in
the tables where the extra cost of the infrastructure seems to go down.

What matters is where it stops being waste. So instead of counting pods, count
how much of each pod carries traffic. At 100 requests each second one worker pod
is 20% busy and four of them are 5% busy, and that is the whole of the +100% and
the +400%. At 1,000 the four workers are still half idle. Then at 10,000 every
pod on both sides is full, or within 2% of it, with one worker and with four
alike, and the split still costs 22% more, which comes to represent the hop
between the domains: serialisation, deserialisation and the time of the request
on the network.

Every cell is the share of the capacity you rent that is busy.

| Req/s    | split shape  | merged pods | main pods | worker pods | additional cost |
| -------- | ------------ | ----------- | --------- | ----------- | --------------- |
| 100/s    | one worker   | 40%         | 29%       | 20%         | +100%           |
| 100/s    | four workers | 40%         | 29%       | 5%          | +400%           |
| 1,000/s  | one worker   | 100%        | 95%       | 100%        | +25%            |
| 1,000/s  | four workers | 100%        | 95%       | 50%         | +75%            |
| 10,000/s | one worker   | 100%        | 98%       | 100%        | +22%            |
| 10,000/s | four workers | 100%        | 98%       | 100%        | +22%            |

## ISOLATION WITHOUT THE NETWORK

### Because I made my girlfriend my life I don't have friends anymore

Process isolation alone doesn't need network separation, as the problem of
isolation is totally different from the one of distribution, and completely
different from scaling. And even though we have known that since the end of the
60s, what remains in our collective knowledge are the popular implementations,
containers and microservices, not the ideas behind them. We are still using a
hexagonal architecture, after all.

The idea is old and it was never about just distributed machines. A
**microkernel** keeps a minimal core that owns transport, routing and errors,
and puts the domain behaviour in plug-ins that the core loads, refuses and
replaces. The word process is everywhere in that literature, back to Brinch
Hansen's nucleus in 1969, but the part we are borrowing is not the separate
address space. It is isolation inside one program: a piece that can fail, be
taken out of the map and be retried without the core going down with it.

**Erlang with OTP** (Open Telecom Platform) is one implementation of that idea,
and the one that took it furthest. Supervision trees, independent restart and
fault isolation, with processes that live inside a single virtual machine and
cost microseconds to create. A supervisor putting a failed worker back is the
same operational story as a container being rescheduled, without a socket in the
middle. It has worked that way since the mid nineties.

## CONCLUSION

### Everything is different now, I have changed, I promise

After the migration, a few things about the resulting program are worth saying.

**The main application had no change in behaviour.** Its code didn't change. It
still asks for a job and gets back the same answers it got before, because the
interface handles everything that the network used to, and returns what the
microservice used to return.

**The numbers.** In my system, a main app and three microservices, this is what
merging them changed:

| measured                               | split   | merged   |
| -------------------------------------- | ------- | -------- |
| containers                             | 4       | 1        |
| memory after start-up                  | ~425 MB | ~130 MB  |
| CPU of one call to a microservice      | 0.69 ms | 0.065 ms |
| time of one call to a microservice     | 2.5 ms  | 0.06 ms  |
| median response time at 200 requests/s | 6.0 ms  | 4.8 ms   |
| pods for 1,000 requests/s (one worker) | 5       | 4        |

The call rows come from the benchmark of the concurrency section [^2]. The rest
come from the same machine as the costs section [^1].

There is now **simplification** on several fronts. **Deployment**, as we now
have several fewer containers to worry about. **Testing** became easier, as
complex integration tests between containers, plus unit tests for each
implementation, became just unit tests. **Development**, as when one service
needs to be updated or changed, the step of protobuf generation and update
across the different apps is no longer needed. **Costs**, as we no longer pay
for underutilized infrastructure, and there is a clearer correlation between the
clients being served and the costs of our infrastructure.

And for the money, the split costs at least 22% more than the merged app, and
that is the minimum, since this test was done in ideal circumstances. If our I/O
takes more than an instant, those coroutines/threads stay open, consuming extra
memory, and our system has to scale not only for its CPU usage but also for its
RAM usage, shifting the projection towards more costs.

## HOW TO MEASURE YOUR OWN NUMBERS

You do not need a profiler. You need the same work run both ways, and a load
generator that pushes each pod until it stops answering more:

```
merged        = requests each second one merged pod answers at its limit
main          = requests each second one main pod answers at its limit,
                with enough workers behind it that they are not the bottleneck
microservice  = requests each second one worker pod answers at its limit
```

Two warnings. Measure near saturation, because the processor lowers its clock
when the machine is quiet and the same request then looks two or three times
more expensive. And measure the two shapes on the same machine on the same day,
or you are comparing the weather.

[^1]:
    Intel i5-4570 at 3.4 GHz, one core and 512 MiB for each container, Python
    3.14. If your core is twice as fast, divide the two CPU rows by two. The
    transit row does not move. Everything here runs as containers on that one
    machine, so the transit row is the loopback interface. In production the two
    processes sit on different nodes and that row becomes 0.5 to 3 milliseconds.
    It costs almost no CPU, so it barely moves the pod count, but it does change
    how many requests are in flight at the same time (rate times latency), so a
    slower wire needs more concurrent slots, and eventually more pods, for the
    same traffic.

[^2]:
    The same machine, but using its four cores. The gRPC client and server ran
    in one process, with OpenTelemetry on both sides, so the 0.69 ms is the CPU
    of the two sides together, and the 2.5 ms is not the time between two
    containers. The 0.018 ms is the domain logic of one call alone.

[1]: https://en.wikipedia.org/wiki/Conway%27s_law
