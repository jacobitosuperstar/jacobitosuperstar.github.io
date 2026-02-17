---
title: I Got 99 Problems but Endpoint Configuration Ain't One
date: 2026-02-16T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "metaprogramming", "FastAPI"]
categories: ["programming"]
---

You have a FastAPI application. A handful of endpoints. Some need
authentication, some need logging. You reach for the standard tools:
decorators and `Depends()`.

```python
@log_requests
@require_login
async def get_user_profile(
    user_id: int,
    current_user: User = Depends(get_current_user),
) -> UserProfileResponse:

    # Inline permission check, duplicated across endpoints
    if not current_user.has_permission("view_profiles"):
        raise HTTPException(status_code=403, detail="Insufficient permissions")

    user = await user_service.get_profile(user_id)
    return UserProfileResponse(user=user)
```

Then the requirements change. Your API needs to be deployed across multiple
regions. Each region has different business rules:

- **Region A** needs full authentication and rate limiting on admin endpoints.
- **Region B** is an internal deployment — no authentication needed, but
  logging is mandatory.
- **Region C** needs authentication *and* rate limiting on every single
  endpoint.

## This Has Several Problems

### The Naive Solution

The instinct is to reach for environment variables:

```python
import os

@log_requests
async def get_user_profile(
    user_id: int,
    current_user: User = Depends(get_current_user),
) -> UserProfileResponse:

    if os.environ.get("REQUIRE_AUTH") == "true":
        if not current_user.is_authenticated:
            raise HTTPException(status_code=401, detail="Auth required")

    if os.environ.get("CHECK_PROFILE_PERMISSIONS") == "true":
        if not current_user.has_permission("view_profiles"):
            raise HTTPException(status_code=403, detail="Insufficient permissions")

    user = await user_service.get_profile(user_id)
    return UserProfileResponse(user=user)
```

Three regions, two checks. Manageable. But more regions means more checks,
more endpoints, and each combination might need a different set of pre-checks
in a different order. Your environment starts looking like this:

```bash
REQUIRE_AUTH=true
CHECK_PROFILE_PERMISSIONS=true
CHECK_UPLOAD_RATE_LIMIT=true
CHECK_ADMIN_PERMISSIONS=true
CHECK_SETTINGS_RATE_LIMIT=true
CHECK_BILLING_VERIFICATION=true
ENABLE_REQUEST_LOGGING=true
ENABLE_AUDIT_TRAIL=true
# ... 30 more of these
```

And every endpoint accumulates conditional blocks:

```python
async def get_user_profile(
    user_id: int,
    current_user: User = Depends(get_current_user),
) -> UserProfileResponse:

    if os.environ.get("REQUIRE_AUTH") == "true":
        if not current_user.is_authenticated:
            raise HTTPException(status_code=401, detail="Auth required")

    if os.environ.get("CHECK_PROFILE_PERMISSIONS") == "true":
        if not current_user.has_permission("view_profiles"):
            raise HTTPException(status_code=403, detail="Insufficient permissions")

    if os.environ.get("CHECK_PROFILE_RATE_LIMIT") == "true":
        await check_rate_limit(current_user)

    if os.environ.get("ENABLE_AUDIT_TRAIL") == "true":
        await log_audit_event("view_profile", user_id, current_user)

    user = await user_service.get_profile(user_id)
    return UserProfileResponse(user=user)
```

The problems pile up:

1. **Code repetition**: The same conditional blocks are copied across every
   endpoint that needs them.
2. **Code changes for new regions**: Adding a region with a different
   combination of checks means reviewing every endpoint.
3. **Runtime overhead**: Every request evaluates conditionals for checks that
   are *never* going to run in that deployment. The `if` branches are dead code
   that the application pays for on every single request.
4. **No ordering control**: What if Region C needs rate limiting *before*
   authentication, but Region A needs it *after*? The order is hardcoded.
5. **Testing matrix explosion**: Every combination of environment variables
   is a test scenario.

### The Idiomatic Solution

FastAPI has `Depends()` for exactly this kind of cross-cutting concern. The
idea: extract each check into a dependency function that reads an environment
variable to decide whether it should run.

```python
import os
from fastapi import Depends, HTTPException


async def require_login_if_enabled(
    current_user: User = Depends(get_current_user),
):
    if os.environ.get("REQUIRE_AUTH") != "true":
        return
    if not current_user.is_authenticated:
        raise HTTPException(status_code=401, detail="Auth required")


async def check_permissions_if_enabled(
    current_user: User = Depends(get_current_user),
):
    if os.environ.get("CHECK_PERMISSIONS") != "true":
        return
    if not current_user.has_permission("admin"):
        raise HTTPException(status_code=403, detail="Insufficient permissions")
```

Then each endpoint declares the checks it *might* need:

```python
@app.get("/admin/users")
async def get_users(
    _auth=Depends(require_login_if_enabled),
    _perms=Depends(check_permissions_if_enabled),
    _rate=Depends(check_rate_limit_if_enabled),
):
    ...


@app.get("/users/{user_id}")
async def get_user_profile(
    user_id: int,
    _auth=Depends(require_login_if_enabled),
):
    ...
```

Cleaner than raw `if` blocks, but it has its own problems:

1. **The environment variables are still there**. You just moved them inside
   the dependency functions. You still need `REQUIRE_AUTH`,
   `CHECK_PERMISSIONS`, `CHECK_RATE_LIMIT`, etc., and each region still needs
   its own set.
2. **Dependencies resolve even when disabled**. Look at
   `require_login_if_enabled`: it declares `Depends(get_current_user)`. Even
   when `REQUIRE_AUTH` is `"false"`, FastAPI still resolves `get_current_user`
   on every request. If that dependency hits a database or calls an external
   auth service, you are paying for it on every request *for nothing*.
3. **Every endpoint must list all possible checks**. An endpoint that needs
   permissions checking in Region C but not Region A still needs
   `_perms=Depends(check_permissions_if_enabled)` in its signature. Otherwise,
   it cannot be enabled later without a code change.
4. **Per-endpoint, per-region configuration is impossible**. `Depends()` is
   declared statically in the function signature. You cannot say "this endpoint
   gets rate limiting in Region A but not Region B" without going back to
   environment variables *inside* the dependency, which is where we started.
5. **Adding a check to a specific endpoint requires a code change**. Someone
   decides Region D needs audit logging on `/users/{user_id}`. You have to go
   modify that endpoint's signature.

The `Depends()` approach centralizes the *logic* of each check, but it does
not solve the *configuration* problem. The decision about what runs where is
still scattered across endpoint signatures and environment variables.

You need a different approach entirely.

## What Is Metaprogramming?

Metaprogramming is writing code that manipulates other code at runtime.
Instead of calling functions directly, you modify which functions exist, how
they are connected, or what they do.

In Python, the most common forms are:

- **Decorators**: Functions that wrap other functions, adding behavior before
  or after the original runs.
- **Metaclasses**: Classes that control how other classes are created.
- **Runtime attribute mutation**: Directly modifying objects' attributes to
  change their behavior after they have been created.

What we are doing here is the third kind. FastAPI registers endpoint functions
as Python objects with mutable attributes. At startup, after all routes are
registered, we reach into those objects and replace the function references —
rewiring what gets called when a request comes in. The application
"reprograms itself" based on a configuration file before it starts serving
traffic.

If you want a deeper introduction to decorators and metaclasses, I wrote about
them in the [previous article](/en/posts/metaprogram_your_problems_away/).

## The Design

Instead of scattering conditional checks across every endpoint, we move the
decision about *what runs where* into a configuration file and assemble the
endpoint pipelines at startup.

The solution has two types of composable functions:

- **Pre-checks**: Async functions that run *before* the endpoint. They act as
  gates — either returning silently (check passed) or raising an
  `HTTPException` (check failed).
- **Wrappers**: Decorators that wrap *around* the entire pipeline. They handle
  cross-cutting concerns like logging or error handling.

The pipeline for a given endpoint looks like this:

```
wrapper (log_requests)
  -> global pre-check (require_login)
    -> per-endpoint pre-check (check_permissions)
      -> original endpoint function
```

And it is defined entirely in a TOML config file:

```toml
[base]
wrappers = ["log_requests"]
global_pre_checks = ["require_login"]

[pre_checks]
"/admin/users" = ["check_permissions"]
"/admin/settings" = ["check_permissions", "rate_limit"]
```

No environment variables. No conditionals in the endpoint code. The
configuration file *is* the source of truth for what runs where.

## The Pre-Check Functions

A pre-check is an async function with the signature
`async def check(**kwargs) -> None`. It receives the endpoint's resolved
keyword arguments from FastAPI's dependency injection (the request body,
path parameters, dependencies, etc.), and either returns silently or raises
an `HTTPException`.

Here is a login verification pre-check:

```python
from fastapi import HTTPException, status


async def require_login(**kwargs) -> None:
    """Verify that the current user is authenticated."""
    current_user = None
    for value in kwargs.values():
        if hasattr(value, "is_authenticated"):
            current_user = value
            break

    if current_user is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="require_login misconfiguration: endpoint has no "
                   "user dependency"
        )

    if not current_user.is_authenticated:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
```

Notice how it finds the user object from `**kwargs` by checking for
attributes. This makes it work with *any* endpoint that has a user dependency
with an `is_authenticated` attribute, regardless of the specific model used.

If someone adds `require_login` to an endpoint that has no user dependency in
`config.toml`, the function raises a 500 with a clear misconfiguration
message, instead of silently skipping the check.

## The Wrapper

A wrapper is a standard Python decorator. Here is a request logging wrapper
that wraps the entire pipeline (pre-checks + endpoint):

```python
import functools
import logging
import time

logger = logging.getLogger("api")


def log_requests(func):
    """Log request execution time and outcome."""
    @functools.wraps(func)
    async def wrapper(*args, **kwargs):
        start = time.monotonic()
        try:
            result = await func(*args, **kwargs)
            elapsed = time.monotonic() - start
            logger.info(
                f"{func.__name__} completed in {elapsed:.3f}s"
            )
            return result
        except HTTPException as e:
            elapsed = time.monotonic() - start
            logger.warning(
                f"{func.__name__} failed with {e.status_code} "
                f"in {elapsed:.3f}s"
            )
            raise
        except Exception as e:
            elapsed = time.monotonic() - start
            logger.error(
                f"{func.__name__} error: {e} in {elapsed:.3f}s"
            )
            raise HTTPException(
                status_code=500,
                detail="Internal server error."
            )
    return wrapper
```

The key difference between a wrapper and a pre-check: a pre-check runs
*before* the endpoint and does not need access to the endpoint function. A
wrapper runs *around* the endpoint and captures its result or exceptions.
That is why wrappers remain as decorators while pre-checks are plain async
functions.

## How Starlette and FastAPI Handle Requests

To understand why the mutation works, we need to look at what happens under
the hood. FastAPI is built on top of Starlette, which provides routing,
request/response handling, and the ASGI interface.

When you write:

```python
@app.get("/users/{user_id}")
async def get_user_profile(user_id: int):
    ...
```

FastAPI does the following at registration time:

1. Creates an `APIRoute` object (FastAPI's extension of Starlette's `Route`).
2. Stores the endpoint function in `route.endpoint`.
3. Builds a `dependant` object that analyzes the function's signature — its
   path parameters, query parameters, request body, and `Depends()`
   dependencies.
4. Stores a reference to the endpoint function in `route.dependant.call`.
5. Creates an ASGI application (`route.app`) that handles the full request
   lifecycle.

When a request comes in:

1. Starlette's router iterates through `app.routes` and matches the request
   path to a `Route`.
2. The matched route's ASGI app is called.
3. FastAPI's handler resolves all dependencies declared in `dependant` — path
   params, query params, body, `Depends()` functions.
4. The resolved values are passed to `dependant.call(**values)` — the actual
   endpoint function.
5. The return value is serialized into an HTTP response.

The critical detail: `dependant.call` is just a reference to a Python function
stored on a mutable object. Steps 1-3 and 5 do not care *which* function
`call` points to — they only care about its signature (which we preserve with
`functools.wraps`). By replacing `dependant.call` with our composed pipeline
function, we insert pre-checks and wrappers into step 4 without touching
anything else.

Starlette's routing, FastAPI's dependency resolution, response serialization,
the middleware chain, and OpenAPI schema generation all continue to work
unchanged. We are only changing which function gets called at the very last
step.

## Changing the Endpoint Pipeline

With that understanding, here is the core. At application startup, after all
routes are registered, this function reads the TOML config and rewires every
endpoint:

```python
import functools
import tomllib
from pathlib import Path
from fastapi import FastAPI
from fastapi.routing import APIRoute


DECORATORS = {
    "log_requests": log_requests,
}

PRE_CHECKS = {
    "require_login": require_login,
    "check_permissions": check_permissions,
    "rate_limit": rate_limit,
}


def setup_pipeline(app: FastAPI):
    config_path = Path(__file__).parent.parent / "config.toml"
    with open(config_path, "rb") as f:
        config = tomllib.load(f)

    base_wrappers = config.get("base", {}).get("wrappers", [])
    global_pre_checks = config.get("base", {}).get("global_pre_checks", [])
    global_check_fns = [PRE_CHECKS[name] for name in global_pre_checks]
    endpoint_pre_checks = config.get("pre_checks", {})

    for route in app.routes:
        if not isinstance(route, APIRoute):
            continue

        checks = endpoint_pre_checks.get(route.path, [])
        endpoint_check_fns = [PRE_CHECKS[name] for name in checks]
        all_checks = global_check_fns + endpoint_check_fns
        original = route.endpoint

        @functools.wraps(original)
        async def composed(
            *args,
            _checks=all_checks,
            _orig=original,
            **kwargs,
        ):
            for check in _checks:
                await check(**kwargs)
            return await _orig(*args, **kwargs)

        wrapped = composed
        for wrapper_name in base_wrappers:
            wrapper_fn = DECORATORS[wrapper_name]
            wrapped = wrapper_fn(wrapped)

        route.endpoint = wrapped
        route.dependant.call = wrapped
```

Let's break down what is happening.

### Reading Configuration

The function reads `config.toml` using Python's built-in `tomllib` (available
since Python 3.11, zero dependencies). It extracts three things: which
wrappers to apply globally, which pre-checks to run on all endpoints, and
which pre-checks to run on specific endpoints.

### Iterating Routes

FastAPI stores all registered routes in `app.routes`. We iterate over them,
skipping anything that is not an `APIRoute` (like mount points or static
files).

### Composing the Pipeline

For each route, we build a new async function that:

1. Runs all global pre-checks in order.
2. Runs all per-endpoint pre-checks in order.
3. Calls the original endpoint.

The default arguments `_checks=all_checks, _orig=original` are critical.
Without them, Python's closure semantics would cause every route to reference
the *last* loop iteration's values. This is the classic closure-in-loop
pitfall:

```python
# Without default args (broken):
funcs = []
for i in range(3):
    async def f():
        return i
    funcs.append(f)
# All three functions return 2 (the last value of i)

# With default args (correct):
funcs = []
for i in range(3):
    async def f(_i=i):
        return _i
    funcs.append(f)
# Functions return 0, 1, 2 respectively
```

Wrappers are applied as decorators around the composed function. The first
wrapper in the config list becomes the outermost layer.

## Clean Code _not_ Horrible Performance?

Casey Muratori makes a compelling argument that "clean code" patterns —
polymorphism, small functions, layers of indirection — hurt performance. And
he is generally right. But this is a rare case where cleaning up the code
*also* improves performance.

With all the conditional boilerplate gone, the endpoint becomes pure business
logic:

```python
async def get_user_profile(
    user_id: int,
    current_user: User = Depends(get_current_user),
) -> UserProfileResponse:
    user = await user_service.get_profile(user_id)
    return UserProfileResponse(user=user)
```

No decorators. No inline checks. No conditionals. No boilerplate. The pipeline
is assembled at startup from configuration.

And in `api.py`, after all routes are registered:

```python
from .pipeline import setup_pipeline

# ... all @app.get, @app.post definitions ...

setup_pipeline(app)
```

The reason this is not the usual "clean code = slow code" trade-off: the
environment variable approach evaluates conditionals on every single request,
even for checks that are never active in that deployment. With config-driven
pipelines, the branching happens once — at startup. After that, each
endpoint's pipeline is a straight chain of function calls with zero
conditional overhead.

For a single request, the difference is small: a few `if` checks cost
nanoseconds. But it adds up. At 10,000 requests per second across 30
endpoints, each with 5 conditional checks, that is 150,000 branch evaluations
per second that serve no purpose. Remove those branches and the function calls
become a clean sequence that the CPU's branch predictor handles trivially.

The bigger win is at startup. The `setup_pipeline()` function validates the
entire configuration when the application boots:

- References a pre-check that does not exist in the registry? `KeyError`
  immediately.
- Typo in a wrapper name? The app does not start.
- Missing config file? Crash at startup, not on the first request that
  happens to hit that code path.

This fail-fast behavior means configuration errors are caught during
deployment, not in production traffic. Combined with a health check that
verifies the application started successfully, bad configurations never reach
users.

## Adding a New Check

Adding a new pre-check to the system requires three steps:

1. Create a module with an `async def my_check(**kwargs)` function.
2. Import it and add it to the `PRE_CHECKS` registry.
3. Reference `"my_check"` in `config.toml`.

No changes to any endpoint. No new environment variables. The new check is
immediately available for any region's configuration.

## One Image, Every Region

This is where it all comes together. You build a single container image with
all the endpoint code, all the pre-check functions, and all the wrappers. The
`config.toml` file is the only thing that changes between deployments.

In Kubernetes, you mount a different ConfigMap. In Docker Compose, you bind
mount a different file. In any deployment system, you swap one file and the
application assembles itself differently at startup.

**Region A** (full security, rate limiting on admin):
```toml
[base]
wrappers = ["log_requests"]
global_pre_checks = ["require_login"]

[pre_checks]
"/admin/users" = ["check_permissions"]
"/admin/settings" = ["check_permissions", "rate_limit"]
"/api/v1/upload" = ["rate_limit"]
```

**Region B** (internal, no auth, logging only):
```toml
[base]
wrappers = ["log_requests"]
global_pre_checks = []
```

**Region C** (auth + rate limiting everywhere):
```toml
[base]
wrappers = ["log_requests"]
global_pre_checks = ["require_login", "rate_limit"]

[pre_checks]
"/admin/users" = ["check_permissions"]
"/admin/settings" = ["check_permissions"]
```

Same codebase, same image, different behavior. The array order *is* the
execution order, so each region controls not just *which* checks run, but
*in what order*.

No code changes to onboard a new region. No new environment variables. No
redeployment of the application code. Just a new `config.toml`.

## Why Not Router-Level Dependencies or Middleware?

We showed earlier why `Depends()` on each endpoint does not solve the
configuration problem. But FastAPI and Starlette offer other mechanisms worth
addressing:

- **Router-level dependencies**: You could group endpoints into routers based
  on which checks they need and attach dependencies to each router. But this
  means restructuring your entire API around check combinations instead of
  domain logic. A massive refactor, and adding a new check combination still
  requires a code change.
- **App-level dependencies**: Only works for global checks. Does not solve
  per-endpoint configuration.
- **Middleware**: Middleware runs on *every* request, so you need conditionals
  to match URL patterns and decide which checks to apply — essentially
  reimplementing the router inside the middleware. You are back to environment
  variables to toggle checks per region, and every request pays the cost of
  evaluating all those URL conditionals even when none of them match. Worse,
  middleware operates on the raw `Request` and `Response` objects, with no
  access to FastAPI's parsed parameters or dependency injection.
- **Custom `APIRoute` subclass**: The closest built-in alternative, but
  pre-checks receive a raw `Request` object instead of parsed kwargs, losing
  FastAPI's dependency injection benefits.

The `dependant.call` mutation is a pragmatic trade-off: it touches one
internal attribute, but it preserves the entire FastAPI machinery (DI,
validation, OpenAPI docs, middleware) and gives us full config-driven control.

## Conclusions

We started with decorators and `Depends()`, which work fine for a single
deployment. We tried environment variables when multi-region came along, and
watched the complexity grow with every new region and every new check. We ended
up with a system where configuration drives behavior: one image, one codebase,
and a TOML file that assembles the right pipeline for each deployment at
startup.

In the [previous article](/en/posts/metaprogram_your_problems_away/), we used
metaclasses to propagate logging across a class hierarchy. Here we applied the
same principle — propagating cross-cutting behavior across API endpoints — but
driven by configuration instead of code.

Metaprogramming is not always the right answer. It adds complexity and can
make debugging harder. But when the alternative is maintaining duplicated
conditional boilerplate across dozens of endpoints for multiple deployments, a
small amount of controlled metaprogramming at startup can save a lot of
ongoing maintenance — and the fail-fast configuration validation means you are
not trading reliability for convenience.
