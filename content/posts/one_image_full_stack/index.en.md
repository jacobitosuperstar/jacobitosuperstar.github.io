---
title: "One Image Is Worth a Thousand Words: Baking a SPA into the Backend"
date: 2026-01-28T12:00:00-05:00
draft: true

read_more: Read more...
tags: ["docker", "spa", "python", "go", "devops"]
categories: ["programming"]
---

When deploying full-stack applications, you typically see architectures like
this:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Nginx     │────▶│  Frontend   │     │   Backend   │
│   (proxy)   │────▶│ (container) │     │ (container) │
└─────────────┘     └─────────────┘     └─────────────┘
```

Three containers, a reverse proxy to route traffic, CORS configuration, and
separate deployments to coordinate. It works, but for many applications it's
overkill.

**What if your backend just served the frontend directly?**

With Docker multi-stage builds, you can compile your SPA and bundle it into
your backend image - one container, one deployment, no proxy needed:

```
┌─────────────────────────────┐
│         Backend             │
│     (serves API + SPA)      │
└─────────────────────────────┘
```

This approach works with any frontend that compiles to static files: **React,
Vue, Svelte, Angular, SolidJS**, or even plain HTML/CSS/JS. I'll use React as
the example, but the pattern is identical for any SPA.

In this article, I'll show you how to set up this simplified architecture for
both Python (FastAPI/Django) and Go backends.

## What Are Multi-Stage Builds?

Multi-stage builds let you use multiple `FROM` statements in a single
Dockerfile. Each `FROM` starts a new stage, and you can copy artifacts from
previous stages into later ones.

The key insight: **you don't need Node.js in production** - you only need the
built static files. Multi-stage builds let you:

1. Use Node.js to build your SPA (React, Vue, Svelte, etc.)
2. Copy only the `dist/` output to your backend image
3. Discard everything else (node_modules, source files, Node.js itself)

Your final image has no Node.js, no npm, no frontend build tools - just your
backend serving the pre-built static files.

## Stage 1: Building the Frontend SPA

This stage is identical for both Python and Go backends. We use Node.js to
install dependencies and build the production bundle. The example uses React,
but Vue, Svelte, or Angular would look nearly identical.

```dockerfile
# Stage 1: Build frontend SPA
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

COPY ReactFrontend/package.json ReactFrontend/package-lock.json ./

RUN npm ci

COPY ReactFrontend/ ./

RUN npm run build
```

Key points:

- **`AS frontend-builder`**: Names this stage so we can reference it later
- **`npm ci`**: Installs exact versions from lock file (faster, reproducible)
- **Copy package files first**: Leverages Docker layer caching - dependencies
  only reinstall when package.json changes
- **`npm run build`**: Produces optimized static files in `dist/`

## Option A: Python Backend (FastAPI)

For Python, we serve the static files from disk. The frontend build is copied
into a `static/` directory that FastAPI mounts.

```dockerfile
# Stage 2: Python backend
FROM python:3.12-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy backend code
COPY backend/ ./

# Copy frontend build from stage 1
COPY --from=frontend-builder /app/frontend/dist ./static

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Key points:

- **`COPY --from=frontend-builder`**: Pulls the built SPA files from stage 1
- **`python:3.12-slim`**: Minimal Python image without extra packages
- **Static files on disk**: FastAPI serves from `./static/`

Your FastAPI server mounts the static files and serves the SPA:

```python
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

app = FastAPI()

# API routes
@app.get("/api/books")
def get_books():
    return [{"id": 1, "title": "Example Book"}]

# Mount static files (CSS, JS, assets)
app.mount("/assets", StaticFiles(directory="static/assets"), name="assets")

# Serve SPA for all other routes
@app.get("/{path:path}")
def serve_spa(path: str):
    return FileResponse("static/index.html")
```

For **Django**, the approach is similar - use `whitenoise` or Django's
`staticfiles` app to serve the built SPA:

```python
# settings.py
STATICFILES_DIRS = [BASE_DIR / "static"]

# urls.py
from django.views.generic import TemplateView

urlpatterns = [
    path("api/", include("api.urls")),
    path("", TemplateView.as_view(template_name="index.html")),
]
```

## Option B: Go Backend

Go offers something Python can't: embedding static files directly into the
binary using `//go:embed`. The final binary is completely self-contained.

```dockerfile
# Stage 1: Build React frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

COPY ReactFrontend/package.json ReactFrontend/package-lock.json ./

RUN npm ci

COPY ReactFrontend/ ./

RUN npm run build


# Stage 2: Build Go backend
FROM golang:1.25-alpine AS backend-builder

WORKDIR /app

# Install build dependencies for CGO (needed for SQLite)
RUN apk add --no-cache gcc musl-dev

# Copy go mod files
COPY GoBackend/go.mod GoBackend/go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY GoBackend/ ./

# Copy frontend build to the folder that Go will embed
COPY --from=frontend-builder /app/frontend/dist ./api/static

# Build the binary
RUN CGO_ENABLED=1 go build -o server .


# Stage 3: Runtime
FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache libc6-compat

# Copy only the binary - static files are embedded inside it
COPY --from=backend-builder /app/server .

EXPOSE 8000

CMD ["./server"]
```

Key points:

- **Three stages**: Frontend build, Go build, minimal runtime
- **Static files copied before `go build`**: They get embedded into the binary
- **Final image only has the binary**: No Node.js, no Go compiler, no source code

In your Go code, embed the static files:

```go
package api

import "embed"

//go:embed static/*
var staticFiles embed.FS

func (s *Server) serveStaticFile(w http.ResponseWriter, r *http.Request) {
    // Serve from embedded filesystem
    http.FileServer(http.FS(staticFiles)).ServeHTTP(w, r)
}
```

### Embedded vs Separate Folder?

Go gives you a choice: embed static files into the binary or serve them from
disk. Here's the trade-off:

| Aspect | Embedded | Separate Folder |
|--------|----------|-----------------|
| Deployment | Single binary | Binary + static folder |
| Updates | Rebuild required | Can update files independently |
| Dev experience | No hot reload | Hot reload possible |
| File integrity | Can't be modified | Can be deleted/corrupted |

**Recommended pattern:** Use both. Embed for production, serve from disk for
development:

```go
//go:embed static/*
var embeddedFiles embed.FS

func getStaticFS() http.FileSystem {
    if os.Getenv("DEV") == "true" {
        // Serve from disk - supports hot reload
        return http.Dir("./static")
    }
    // Serve embedded files
    return http.FS(embeddedFiles)
}
```

For most applications, **embedded is the better default**. Single-binary
deployment is a major advantage of Go - don't give it up unless you have a
specific need to update static files independently.

## Comparison

| Aspect | Python (FastAPI/Django) | Go |
|--------|-------------------------|-----|
| Final image size | ~150-200MB | ~20MB |
| Static files | On disk | Embedded in binary |
| Deployment | Image + static folder | Single binary |
| Runtime dependencies | Python interpreter | None (static binary) |
| Build complexity | Simpler | Requires embed setup |
| Hot reload | Easy (mount volume) | Rebuild required |

## Adding a Separate Seed Service

For development, you might want a database seeder that runs before your app.
Docker Compose can orchestrate this with build targets.

First, add a seed stage to your Dockerfile:

```dockerfile
# Stage 3: Seed (separate target)
FROM alpine:latest AS seed

WORKDIR /app

RUN apk add --no-cache libc6-compat

COPY --from=backend-builder /app/seed .

CMD ["./seed"]


# Stage 4: Runtime (default - must be last)
FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache libc6-compat

COPY --from=backend-builder /app/server .

EXPOSE 8000

CMD ["./server"]
```

**Important**: The default stage (no target specified) is always the **last**
stage in the Dockerfile. Put your production runtime last.

Then in `docker-compose.yaml`:

```yaml
services:
  seed:
    build:
      context: .
      target: seed
    volumes:
      - app_data:/app/data

  app:
    build:
      context: .
      # No target = uses last stage (runtime)
    depends_on:
      seed:
        condition: service_completed_successfully
    ports:
      - "8000:8000"
    volumes:
      - app_data:/app/data

volumes:
  app_data:
```

The seed service runs first, populates the database, then exits. The app
service waits for seed to complete successfully before starting.

## Development with Docker Compose

During development, you often want to mount your source code for hot reload.
But here's the problem: if you mount `./backend:/app`, it overrides everything
in `/app` - including the `static/` folder that was built into the image.

The solution is **anonymous volumes**:

```yaml
services:
  app:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DEBUG=true
    volumes:
      - ./backend:/app        # Mount source code for hot reload
      - /app/static           # Anonymous volume - preserves built static files
    command: ["python", "main.py"]
```

The key line is `/app/static` (no colon, no host path). This creates an
anonymous volume that:

1. **On first run**: Copies the contents of `/app/static` from the image into
   the volume
2. **On subsequent runs**: Uses the volume contents, ignoring the image

This means your source code mount (`./backend:/app`) won't clobber the static
files that were built during `docker build`. You get hot reload for your Python
code while keeping the pre-built SPA.

**When to rebuild**: If you change your frontend code, you need to rebuild the
image (`docker compose up --build`) since the SPA is baked in during build time.

## Tips and Gotchas

**Layer caching**: Always copy dependency files (`package.json`, `go.mod`)
before copying source code. This way, dependencies only reinstall when they
actually change.

**Volume precedence**: Named and anonymous volumes take precedence over bind
mounts for the same path. Use this to your advantage to preserve built files.

**Minimal base images**: You can use any base image for the runtime stage -
Alpine, Debian slim, Ubuntu, or distroless. Smaller images mean faster pulls
and smaller attack surface, but may require additional dependencies.

**Build arguments**: Use `ARG` for build-time configuration:

```dockerfile
ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV
```

## When to Use This Approach

**This simplified architecture works well when:**

- You have a single backend serving your API
- Your frontend is a standard SPA (React, Vue, Svelte)
- You want simple deployments (one container, one port)
- You're building internal tools, MVPs, or small-to-medium applications

**Consider separate containers when:**

- You need to scale frontend and backend independently
- You have multiple backends serving the same frontend
- You need CDN/edge caching for static assets
- You're running a high-traffic application where static file serving becomes a bottleneck

For most applications, especially during early development, the simplified
approach reduces complexity without sacrificing functionality. You can always
split them later if needed.

## Conclusion

Multi-stage Docker builds let you eliminate the separate frontend container
entirely. Your backend builds and serves the SPA - one image, one deployment,
no reverse proxy configuration.

For Python backends, you get a clean image with static files on disk. For Go
backends, you get a single self-contained binary with everything embedded.
Either way, you've simplified your deployment from three containers to one.

The full working examples are available at:
https://github.com/jacobitosuperstar/fullstack-coding-challenge-library
