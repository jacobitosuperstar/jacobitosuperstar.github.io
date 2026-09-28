---
title: From couples to singles. Microservices as Objects
date: 2026-09-27
draft: true

read_more: Read more...
tags: ["Python", "Go", "Design", "microservices", "microkernel"]
categories: ["programming"]
---

After being dumped by my girlfriend, I regain a lot of time that I had devoted
before, so I started to think about the boundaries of our relationship,
communications issues, and patterns that instead of making two distinc and
different persons, made us a singular blob that just happens to be in two places
at the same time, and then it hit me, I should be using a different architecture
than microservices for system that have similar designs.

As many of you have, I have also encountered systems that go to the
microservices design path in search of distributing work, but that keep having a
singular point of failure and node whose traffic is still proportional to the
main process or router that distributes that work. Meaning the microservice
behaves as a subrotuine of the main process (These article won't discuss systems
where different services can be touched by several main processes). The point of
that solution is to keep the single point of failure as simple as possible and
offload work assigned to the different workers that compose the system. So I
began to think, are microservices the answer for a system like this, is the
modular monolith the answer or are there other designs that we can check upon to
attack this types of designs?.

# THE PROBLEM

As always, the first thing that one must think of is the problem that You are
trying to solve. Within this article, and there are two main ones that want to
tackle.

1. Networking. When we offload the complexity between the main program interface
   to its workers using networking, what we are doing is adding more latency for
   a round trip response and adding the fickleness of network connection to main
   processes of our system.

2. Efficiency and Costs. When we start spawning workers that depend directly on
   the traffic of our main service, we are adding more containers than are
   needed for the solution of a problem. Making the problem require more
   resources for its solution and with the ever increasing expenses of the
   cloud, you have to really think how many points of your profits can go to
   infrastructure costs.

# JUST THINKING ABOUT NEW IDEAS

The microservices in this sense give us several advantages that we have to take
into account when evaluating a solution, and those are,

1. Operational Isolation. When a microservice process fails to start its just a
   worker that failed to start. Not the hole application.

2. Independent Scaling when the traffic is mix and uneven.

3. PlugIn design. We can add and route different parts of the system to
   different workers. For example, if we need to have two of the same worker
   with different configurations, like a worker that sends emails to A and
   another that sends emails to B, is just a routing conditional and we have two
   of the same worker serving different purpuses.

And I though, after all the self reflection and self healing that I did while
soobing, that there is a system design that covers these things without the need
of sending those workloads over the network.

There two design architectures that came to my mind,

**Microkernel** in the sense that we have a minimal core application that owns
transport, routing, errors and observability, plus plugings that own the domain
behaviour.

**Hexagonal Architecture** which is what we currently have, but instead of
leaving the adapters over the network, we would create the interface in the main
that that interacts with each one of the subprocesses that we are running.

The modular monolith architecture, how is normally understod, its a big block
with all of this components initialized together, where each of the well defined
domains has an API that the main process calls, is not sufficient, so a
microkernel like approach is added to achieve plugin design and operational
isolation.

For this I thought of objects that hold the logic of the microservice, that can
carry a state (like a continued connection to a DB, authentication credentials,
and things like that) while also executing the logical steps that the
microservice did. And in case of failure, they would have their own retry logic
elsewhere and if a call from the main process is send here, we will quickly
return a non available error and not let the system overload or spend cycles on
non starting processses.

# THE DESIGN

As for the migration from the distributed monolith to this, I thought of three
parts, the main application, the interface between the main application and the
processes (this would hold each of the microservices logic). Where the interface
is the only thing that have in common the main application and the processes
code. The application routes the jobs through that interface, the processes
initialize each of the registered objects (like the registered micro service)
and then each of those objects is loaded into that interface.

For the interface the map is the most flexible structure to hold things like
this, as we can define the key that routes to that object and for value we can
have an optional type, so that key can return the object that represents the
microservice or None. And for key strings that we can modify, create or change
how we see fit. Those also resemble the string that hold the microservice URL so
the idea is to have this in case there are similar routing mechanism, mainly
string manipulation.

Two maps compose the registered processes, one map that hold the succesfully
initiaded and working processes and another that holds the failed to initialize
objects and objects that fail after initialization, like, a process that tries
to connecto to an unavailable database after start up, and have on that other
map the logic that will retry their initialization at different stages of the
application (exponential back off or other strategies that you may see fit),
completelly independent of their in process calls. That way we can quickly
return failed responses without overloading the system with per request
evaluations.

Those two maps hold between them all of the initalized processes that the app
offloaded before into the network.

```
# what the core needs from any worker. Nothing about how it is done.
interface Worker:
    handle(operation, request) -> response

# the map, built once at start-up, only modified in case of well defined types
# of failures
REGISTRY: map[key] -> Worker Object
```

The map could be built from configuration, in case we may need to load different
kinds of workers for different instances, or self adding objects, which add
themselfes into the registry after their initializion code is executed. We could
also add a map evaluation, so no more of the required processes from the main
app are added into the registry.

```
def build_registry(config):
    registry = {}
    for key, spec in config.routes:
        kind = KNOWN_KINDS.get(spec.kind)
        if kind is None:
            fail("unknown kind: " + spec.kind)   # refuse to start, loudly
        registry[key] = kind(spec.settings)
    return registry
```

And the route becomes a lookup and a call, the same shape it had when the worker
was a network call, which is the point:

```
def route(request):
    worker = REGISTRY.get(key_of(request))
    if worker is None:
        return 501
    return worker.handle(request.operation, request)
```

Two workers of the same kind with different settings is now a second entry in
the map, not another element to deploy:

```
routes:
  "notify.a" : { kind: "email", settings: { provider: A } }
  "notify.b" : { kind: "email", settings: { provider: B } }
```

## Isolation is a property of the object, not of the process

This is the part people assume requires separate processes. It doesn't. It
requires each worker/object to own its own failure state:

@CLAUDE: this code has the object owing the failure state, but still being
routed to it. We defined before two maps, one that holds the ready workers, and
other that holds the failed ones. I think that here we should have retry logic
for the elements of that map, instead of this.

```
class Worker:
    state    = READY
    retry_at = 0

    def handle(operation, request):
        if state is BROKEN and now() < retry_at:
            return 503                      # local, immediate, no cascade
        if not connected:
            try:
                connect()                   # first request, not boot
            except:
                state, retry_at = BROKEN, now() + 30s
                return 503
        return run(operation, request)
```

A dependency that is down now costs one route a fast 503, with retries on the
background. That is exactly the isolation a separate process was buying, only
the _unreachable_ dependency is deferred.

## The concurrency bound becomes explicit

Because the state of the object it self is not mutable by external processes,
meaning the interaction with the main application

Depending on the language we can

In the split version, each worker had a thread pool, and that pool silently set
the capacity of the whole system:

```
capacity = threads / (dependency latency + work)
```

Nobody chose that number as a policy. It was a default in a server that nobody
read. In-process you write it down, per worker, and one slow dependency cannot
drain the whole application:

```
class Worker:
    limiter = Semaphore(N)      # what the worker's thread pool used to be

    def handle(operation, request):
        if not limiter.acquire(timeout=0):
            return 503          # shed here, do not queue forever
        try:
            return run(operation, request)
        finally:
            limiter.release()
```

This is the one place where the in-process version is not merely cheaper but
better: the bound goes from accidental to chosen.

# COSTS ANALYSIS

## The tax is per request, and it never amortises

Every call across the boundary pays: serialise, cross a socket, deserialise,
schedule in a second runtime, and the same again coming back. It does not
improve with scale and it does not show up in a latency chart, because it hides
under a millisecond. It shows up in the bill.

## A captive worker can never be filled

This is the structural argument, and it needs no benchmark. A worker with one
consumer inherits that consumer's duty cycle. When the parent is saturated, the
worker sits at whatever ratio the work happens to imply, and you cannot sell the
remainder to anybody, because nothing else calls it. A _shared_ service pools
demand from many callers and runs hot. A captive one cannot.

## You round up twice

```
pods = ceil(rate / parent_capacity) + ceil(rate / worker_capacity)
```

Two tiers, two roundings, and the ratio between the two capacities is rarely an
integer, so the waste never cancels out. One tier rounds once.

## Every process pays an entry fee

A runtime, its libraries and its baseline memory, per replica, before serving a
single request. Split one program into two and you pay that twice for the same
work.

## The metric that flatters the split

**Requests per pod goes up when you split**, because the work moved to another
pod. Anybody measuring that will conclude the split is faster. The honest
measure is **cost per request**: CPU-seconds and bytes of memory for the same
unit of work.

## Where the milliseconds go

Before the formula, it helps to see which parts of a request cost what, and
which of those parts the architecture can remove. These are CPU milliseconds for
one request, measured on one machine [^1].

| part of the request                                           | ms    | a faster CPU helps | the split adds it             |
| ------------------------------------------------------------- | ----- | ------------------ | ----------------------------- |
| the work: parse, validate, the domain logic, build the answer | 3.28  | yes                | no, it is the same either way |
| the hop, CPU: serialise, deserialise, wake two schedulers     | ~0.70 | yes                | yes                           |
| the hop, transit: the kernel and the wire                     | ~0.10 | **no**             | yes                           |

Read the table twice, once for each column on the right.

**What a faster CPU changes.** The first two rows shrink. The third does not. A
socket, a system call and a scheduler wake-up take the time they take.

**What the architecture changes.** The second and third rows disappear. The
first one stays exactly as it was, because it is the work you came to do.

That is the whole argument in one table. The split does not make your work
slower. It adds two rows of cost that have nothing to do with your work, and one
of those rows does not improve when you buy a better machine [^2].

## The arithmetic

The four things above become one calculation. These are the symbols:

```
R    requests each second the system must answer
Wm   CPU seconds one request costs inside one process
Wp   CPU seconds the parent part costs
Ww   CPU seconds the worker part costs          (Wm = Wp + Ww)
h    CPU seconds the hop adds, both sides together
u    the share of a core you are willing to use (0.7 is common)
```

And this is the pod count:

```
one process     pods = ceil( R * Wm / u )

two processes   parent = ceil( R * (Wp + h/2) / u )
                worker = ceil( R * (Ww + h/2) / u )
                pods   = parent + worker
```

When the dependency is slow, a second limit can bind before the CPU does:

```
T    concurrent requests one pod allows (threads, or async slots)
L    seconds the dependency takes to answer

concurrency pods = ceil( R * (L + W) / T )
pods = max(cpu pods, concurrency pods)
```

You have to measure `Wm` and `h` on your own system. The two tables below are
only an example of the shape, with numbers I measured on one machine.

### Python: `Wm = 3.28 ms`, `h = 0.8 ms`, `u = 0.7`

| R         | one process | two processes | extra |
| --------- | ----------- | ------------- | ----- |
| 100/s     | 1           | 2 (1+1)       | +100% |
| 1,000/s   | 5           | 7 (4+3)       | +40%  |
| 10,000/s  | 47          | 59 (36+23)    | +26%  |
| 100,000/s | 469         | 584 (355+229) | +25%  |

### Go: `Wm = 0.33 ms`, `h = 0.2 ms`, `u = 0.7`

The work is ten times cheaper. The hop is only four times cheaper, because a
socket, a system call and a scheduler wake-up have a floor that no language
removes.

| R         | one process | two processes | extra |
| --------- | ----------- | ------------- | ----- |
| 100/s     | 1           | 2 (1+1)       | +100% |
| 1,000/s   | 1           | 2 (1+1)       | +100% |
| 10,000/s  | 5           | 9 (5+4)       | +80%  |
| 100,000/s | 48          | 77 (45+32)    | +60%  |

Three things come out of these tables.

**The faster the language, the worse the split looks.** In Python the hop is 24%
of the work. In Go the same hop is 61% of a much smaller number. You removed the
expensive part and you kept the fixed part. Look at the last row of each table:
the extra settles at 25% for Python and at 60% for Go. That number is the hop,
and it is the price you pay for ever.

**A split has a floor of two pods, and it never goes away.** Under about 10,000
requests each second in Go, the whole system fits in one pod, and the split
still asks you for two. At a small scale the overhead is 100%, and no amount of
efficiency removes it.

**The number that hides the most money is `u`.** From `u = 0.7` to `u = 0.5`
every number above is multiplied by 1.4. Most teams choose that value by feel
and never look at it again, and it costs more than the choice of architecture.

## How to measure your own numbers

You do not need a profiler. You need the same work run both ways:

```
Wm = cores the merged app uses / requests each second it answers

split parent = cores the parent uses  / requests each second
split worker = cores the worker uses  / requests each second
h  = (split parent + split worker) - Wm
```

Two warnings. Measure near saturation, because the processor lowers its clock
when the machine is quiet and the same request then looks two or three times
more expensive. And measure the two shapes on the same machine on the same day,
or you are comparing the weather.

[^1]:
    Intel i5-4570 at 3.4 GHz, one core and 512 MiB for each container, Python
    3.14. If your core is twice as fast, divide the two CPU rows by two. The
    transit row does not move.

[^2]:
    These are containers on one machine, so the transit row is the loopback
    interface. In production the two processes are on different nodes and that
    row becomes 0.5 to 3 milliseconds. It costs almost no CPU, so it does not
    change the pod count through the first formula, and it does change it
    through the second one: the requests in flight are rate times latency, so a
    slower wire needs more concurrency, and eventually more pods, for the same
    traffic.

# ISOLATION WITHOUT THE NETWORK

There is an existence proof that isolation and the transport are separable, and
it is thirty years old. Erlang and OTP give fault isolation, independent restart
and supervision trees with processes that live inside one virtual machine and
cost microseconds to create. A supervisor restarting a failed worker is the same
operational story as a container being rescheduled, without a socket in the
middle.

Most people defending a captive worker believe they are buying isolation. They
are buying isolation _plus_ a transport they never needed.

The older name for this decision is **linking versus IPC**. Unix programmers
split programs into communicating processes deliberately and sparingly, because
the cost of the pipe was visible to them. Containers made the split the default
and hid the cost behind a YAML file.

# CONCLUSION

<!-- Draft to rewrite in your own voice. The metaphor from the opening is worth
     calling back to here: two people who must be in the same place at the same
     time, communicating through a channel, are not two people. They are one
     person paying for two apartments. -->

A worker that only ever answers one caller is not a service. It is a subroutine
that you are paying a process, a runtime and a network hop to call. The
microkernel keeps everything the split was actually buying, the isolation, the
plug-in routing, the separate configuration, and gives back the transport.
