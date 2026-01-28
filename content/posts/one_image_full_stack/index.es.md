---
title: "Una Imagen Vale Más Que Mil Palabras: Integrando una SPA en el Backend"
date: 2026-01-28T12:00:00-05:00
draft: true

read_more: Leer más...
tags: ["docker", "spa", "python", "go", "devops"]
categories: ["programming"]
---

Al desplegar aplicaciones full-stack, típicamente se ven arquitecturas como
esta:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Nginx     │────▶│  Frontend   │     │   Backend   │
│   (proxy)   │────▶│ (container) │     │ (container) │
└─────────────┘     └─────────────┘     └─────────────┘
```

Tres contenedores, un reverse proxy para enrutar el tráfico, configuración de
CORS y despliegues separados que coordinar. Funciona, pero para muchas
aplicaciones es excesivo.

**¿Y si tu backend sirviera el frontend directamente?**

Con los builds multi-stage de Docker, puedes compilar tu SPA e incluirla en tu
imagen de backend - un contenedor, un despliegue, sin proxy:

```
┌─────────────────────────────┐
│         Backend             │
│     (sirve API + SPA)       │
└─────────────────────────────┘
```

Este enfoque funciona con cualquier frontend que compile a archivos estáticos:
**React, Vue, Svelte, Angular, SolidJS**, o incluso HTML/CSS/JS puro. Usaré
React como ejemplo, pero el patrón es idéntico para cualquier SPA.

En este artículo, te mostraré cómo configurar esta arquitectura simplificada
para backends en Python (FastAPI/Django) y Go.

## ¿Qué Son los Builds Multi-Stage?

Los builds multi-stage te permiten usar múltiples declaraciones `FROM` en un
solo Dockerfile. Cada `FROM` inicia una nueva etapa, y puedes copiar artefactos
de etapas anteriores a las siguientes.

La idea clave: **no necesitas Node.js en producción** - solo necesitas los
archivos estáticos compilados. Los builds multi-stage te permiten:

1. Usar Node.js para compilar tu SPA (React, Vue, Svelte, etc.)
2. Copiar solo el output de `dist/` a tu imagen de backend
3. Descartar todo lo demás (node_modules, archivos fuente, Node.js mismo)

Tu imagen final no tiene Node.js, ni npm, ni herramientas de build del frontend
- solo tu backend sirviendo los archivos estáticos pre-compilados.

## Etapa 1: Compilando el Frontend SPA

Esta etapa es idéntica para backends en Python y Go. Usamos Node.js para
instalar dependencias y compilar el bundle de producción. El ejemplo usa React,
pero Vue, Svelte o Angular se verían casi idénticos.

```dockerfile
# Etapa 1: Compilar frontend SPA
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

COPY ReactFrontend/package.json ReactFrontend/package-lock.json ./

RUN npm ci

COPY ReactFrontend/ ./

RUN npm run build
```

Puntos clave:

- **`AS frontend-builder`**: Nombra esta etapa para poder referenciarla después
- **`npm ci`**: Instala versiones exactas del lock file (más rápido, reproducible)
- **Copiar archivos de paquetes primero**: Aprovecha el caché de capas de Docker
  - las dependencias solo se reinstalan cuando package.json cambia
- **`npm run build`**: Produce archivos estáticos optimizados en `dist/`

## Opción A: Backend en Python (FastAPI)

Para Python, servimos los archivos estáticos desde disco. El build del frontend
se copia a un directorio `static/` que FastAPI monta.

```dockerfile
# Etapa 2: Backend Python
FROM python:3.12-slim

WORKDIR /app

# Instalar dependencias
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copiar código del backend
COPY backend/ ./

# Copiar build del frontend desde la etapa 1
COPY --from=frontend-builder /app/frontend/dist ./static

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Puntos clave:

- **`COPY --from=frontend-builder`**: Extrae los archivos de la SPA desde la etapa 1
- **`python:3.12-slim`**: Imagen mínima de Python sin paquetes extra
- **Archivos estáticos en disco**: FastAPI sirve desde `./static/`

Tu servidor FastAPI monta los archivos estáticos y sirve la SPA:

```python
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

app = FastAPI()

# Rutas de API
@app.get("/api/books")
def get_books():
    return [{"id": 1, "title": "Libro de Ejemplo"}]

# Montar archivos estáticos (CSS, JS, assets)
app.mount("/assets", StaticFiles(directory="static/assets"), name="assets")

# Servir SPA para todas las demás rutas
@app.get("/{path:path}")
def serve_spa(path: str):
    return FileResponse("static/index.html")
```

Para **Django**, el enfoque es similar - usa `whitenoise` o la app `staticfiles`
de Django para servir la SPA compilada:

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

## Opción B: Backend en Go

Go ofrece algo que Python no puede: embeber archivos estáticos directamente en
el binario usando `//go:embed`. El binario final es completamente autónomo.

```dockerfile
# Etapa 1: Compilar frontend React
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

COPY ReactFrontend/package.json ReactFrontend/package-lock.json ./

RUN npm ci

COPY ReactFrontend/ ./

RUN npm run build


# Etapa 2: Compilar backend Go
FROM golang:1.25-alpine AS backend-builder

WORKDIR /app

# Instalar dependencias de compilación para CGO (necesario para SQLite)
RUN apk add --no-cache gcc musl-dev

# Copiar archivos go mod
COPY GoBackend/go.mod GoBackend/go.sum ./

# Descargar dependencias
RUN go mod download

# Copiar código fuente
COPY GoBackend/ ./

# Copiar build del frontend a la carpeta que Go embebera
COPY --from=frontend-builder /app/frontend/dist ./api/static

# Compilar el binario
RUN CGO_ENABLED=1 go build -o server .


# Etapa 3: Runtime
FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache libc6-compat

# Copiar solo el binario - los archivos estáticos están embebidos dentro
COPY --from=backend-builder /app/server .

EXPOSE 8000

CMD ["./server"]
```

Puntos clave:

- **Tres etapas**: Build del frontend, build de Go, runtime mínimo
- **Archivos estáticos copiados antes de `go build`**: Se embeben en el binario
- **La imagen final solo tiene el binario**: Sin Node.js, sin compilador de Go, sin código fuente

En tu código Go, embebe los archivos estáticos:

```go
package api

import "embed"

//go:embed static/*
var staticFiles embed.FS

func (s *Server) serveStaticFile(w http.ResponseWriter, r *http.Request) {
    // Servir desde sistema de archivos embebido
    http.FileServer(http.FS(staticFiles)).ServeHTTP(w, r)
}
```

### ¿Embebido vs Carpeta Separada?

Go te da una opción: embeber archivos estáticos en el binario o servirlos desde
disco. Aquí está el trade-off:

| Aspecto | Embebido | Carpeta Separada |
|---------|----------|------------------|
| Despliegue | Binario único | Binario + carpeta static |
| Actualizaciones | Requiere recompilar | Puede actualizar archivos independientemente |
| Experiencia de desarrollo | Sin hot reload | Hot reload posible |
| Integridad de archivos | No pueden modificarse | Pueden borrarse/corromperse |

**Patrón recomendado:** Usa ambos. Embebido para producción, desde disco para
desarrollo:

```go
//go:embed static/*
var embeddedFiles embed.FS

func getStaticFS() http.FileSystem {
    if os.Getenv("DEV") == "true" {
        // Servir desde disco - soporta hot reload
        return http.Dir("./static")
    }
    // Servir archivos embebidos
    return http.FS(embeddedFiles)
}
```

Para la mayoría de aplicaciones, **embebido es la mejor opción por defecto**.
El despliegue de binario único es una gran ventaja de Go - no la pierdas a menos
que tengas una necesidad específica de actualizar archivos estáticos independientemente.

## Comparación

| Aspecto | Python (FastAPI/Django) | Go |
|---------|-------------------------|-----|
| Tamaño de imagen final | ~150-200MB | ~20MB |
| Archivos estáticos | En disco | Embebidos en binario |
| Despliegue | Imagen + carpeta static | Binario único |
| Dependencias de runtime | Intérprete Python | Ninguna (binario estático) |
| Complejidad del build | Más simple | Requiere configurar embed |
| Hot reload | Fácil (montar volumen) | Requiere recompilar |

## Agregando un Servicio de Seed Separado

Para desarrollo, puede que quieras un seeder de base de datos que se ejecute
antes de tu app. Docker Compose puede orquestar esto con build targets.

Primero, agrega una etapa de seed a tu Dockerfile:

```dockerfile
# Etapa 3: Seed (target separado)
FROM alpine:latest AS seed

WORKDIR /app

RUN apk add --no-cache libc6-compat

COPY --from=backend-builder /app/seed .

CMD ["./seed"]


# Etapa 4: Runtime (por defecto - debe ser el último)
FROM alpine:latest

WORKDIR /app

RUN apk add --no-cache libc6-compat

COPY --from=backend-builder /app/server .

EXPOSE 8000

CMD ["./server"]
```

**Importante**: La etapa por defecto (sin target especificado) es siempre la
**última** etapa en el Dockerfile. Pon tu runtime de producción al final.

Luego en `docker-compose.yaml`:

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
      # Sin target = usa la última etapa (runtime)
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

El servicio seed se ejecuta primero, llena la base de datos, y luego termina.
El servicio app espera a que seed complete exitosamente antes de iniciar.

## Desarrollo con Docker Compose

Durante el desarrollo, frecuentemente quieres montar tu código fuente para hot
reload. Pero aquí está el problema: si montas `./backend:/app`, sobreescribe
todo en `/app` - incluyendo la carpeta `static/` que se construyó en la imagen.

La solución son los **volúmenes anónimos**:

```yaml
services:
  app:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DEBUG=true
    volumes:
      - ./backend:/app        # Montar código fuente para hot reload
      - /app/static           # Volumen anónimo - preserva archivos estáticos compilados
    command: ["python", "main.py"]
```

La línea clave es `/app/static` (sin dos puntos, sin ruta del host). Esto crea
un volumen anónimo que:

1. **En la primera ejecución**: Copia el contenido de `/app/static` desde la
   imagen al volumen
2. **En ejecuciones posteriores**: Usa el contenido del volumen, ignorando la imagen

Esto significa que tu mount de código fuente (`./backend:/app`) no destruirá
los archivos estáticos que se construyeron durante `docker build`. Obtienes hot
reload para tu código Python mientras mantienes la SPA pre-compilada.

**Cuándo recompilar**: Si cambias tu código frontend, necesitas reconstruir la
imagen (`docker compose up --build`) ya que la SPA se integra durante el build.

## Tips y Gotchas

**Caché de capas**: Siempre copia los archivos de dependencias (`package.json`,
`go.mod`) antes de copiar el código fuente. De esta manera, las dependencias
solo se reinstalan cuando realmente cambian.

**Precedencia de volúmenes**: Los volúmenes nombrados y anónimos tienen
precedencia sobre los bind mounts para la misma ruta. Usa esto a tu favor para
preservar archivos compilados.

**Imágenes base mínimas**: Puedes usar cualquier imagen base para la etapa de
runtime - Alpine, Debian slim, Ubuntu, o distroless. Imágenes más pequeñas
significan pulls más rápidos y menor superficie de ataque, pero pueden requerir
dependencias adicionales.

**Build arguments**: Usa `ARG` para configuración en tiempo de build:

```dockerfile
ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV
```

## Cuándo Usar Este Enfoque

**Esta arquitectura simplificada funciona bien cuando:**

- Tienes un solo backend sirviendo tu API
- Tu frontend es una SPA estándar (React, Vue, Svelte)
- Quieres despliegues simples (un contenedor, un puerto)
- Estás construyendo herramientas internas, MVPs, o aplicaciones pequeñas a medianas

**Considera contenedores separados cuando:**

- Necesitas escalar frontend y backend independientemente
- Tienes múltiples backends sirviendo el mismo frontend
- Necesitas CDN/edge caching para assets estáticos
- Estás ejecutando una aplicación de alto tráfico donde servir archivos estáticos se convierte en cuello de botella

Para la mayoría de aplicaciones, especialmente durante el desarrollo temprano,
el enfoque simplificado reduce complejidad sin sacrificar funcionalidad.
Siempre puedes separarlos después si es necesario.

## Conclusión

Los builds multi-stage de Docker te permiten eliminar el contenedor de frontend
separado por completo. Tu backend compila y sirve la SPA - una imagen, un
despliegue, sin configuración de reverse proxy.

Para backends en Python, obtienes una imagen limpia con archivos estáticos en
disco. Para backends en Go, obtienes un binario único y autónomo con todo
embebido. De cualquier forma, has simplificado tu despliegue de tres
contenedores a uno.

Los ejemplos completos y funcionales están disponibles en:
https://github.com/jacobitosuperstar/fullstack-coding-challenge-library
