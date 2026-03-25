---
title: DependaMan
in_navbar: false
weight: 300
draft: false
is_project: true
project_description: "Una herramienta de análisis y visualización de dependencias para Python. Analiza la estructura interna de módulos de tu proyecto y genera un grafo HTML interactivo — mostrando ciclos, módulos muertos, hotspots y problemas de acoplamiento sin dependencias externas."
project_dates: "25/03/2026 – presente"
project_link: "https://codeberg.org/jacobitosuperstar/DependaMan"
---

## **DependaMan - Analizador de Dependencias Python**

🔗 [Ver en Codeberg](https://codeberg.org/jacobitosuperstar/DependaMan)

Una herramienta de línea de comandos y librería Python que analiza la estructura interna de módulos de un proyecto y produce un grafo HTML interactivo. Detecta problemas arquitectónicos — importaciones circulares, código muerto, hotspots de acoplamiento — usando únicamente la biblioteca estándar de Python.

### **Visión del Proyecto**

DependaMan busca responder las preguntas que se vuelven más difíciles de responder a medida que crece una base de código:
- ¿De qué módulos depende todo lo demás?
- ¿Qué módulos nunca son importados por nadie?
- ¿Dónde se esconden los ciclos de importación?
- ¿Qué archivos cambian más y son los más importados — los hotspots de mayor riesgo?

### **Principios Básicos de Diseño**

#### Sin Dependencias Externas
La herramienta completa funciona con la biblioteca estándar de Python (`ast`, `pathlib`, `json`, `subprocess`, `concurrent.futures`). No se requiere ningún `pip install` adicional — funciona en cualquier entorno.

#### Arquitectura de Pipeline
El análisis está dividido en seis fases discretas, cada una con una única responsabilidad:
1. **Descubrimiento** — recorre el árbol del proyecto, identifica módulos Python, determina raíces de paquetes y separa el código interno del externo
2. **Parseo** — usa `ast` para extraer importaciones de cada archivo, resuelve importaciones relativas y filtra solo las conexiones internas
3. **Construcción del Grafo** — construye un grafo dirigido donde los nodos son módulos y las aristas representan relaciones de importación
4. **Análisis** — ejecuta cuatro pasadas independientes sobre el grafo: detección de código muerto, detección de importaciones circulares (basada en DFS), análisis de hotspots (fan-in) y análisis de acoplamiento (fan-out)
5. **Integración con Git** — consulta `git log` por archivo para extraer frecuencia de commits, líneas añadidas/eliminadas y último autor
6. **Renderizado** — produce un archivo HTML autocontenido con un grafo interactivo en canvas sin dependencias de JS externas

#### Estrategias de Concurrencia
DependaMan aplica dos estrategias de concurrencia distintas según la naturaleza del trabajo:

- **Estadísticas de Git (I/O-bound)** — obtener métricas por archivo implica esperar llamadas a subprocesos, no trabajo de CPU. Se usa `ThreadPoolExecutor` para que múltiples llamadas a `git log` corran de forma concurrente sin el costo de crear procesos separados.
- **Parseo (CPU-bound)** — el parseo con `ast` es cómputo puro. Cuando la cantidad de módulos es suficientemente alta, DependaMan cambia a `ProcessPoolExecutor` para eludir el GIL y usar múltiples núcleos en paralelo.

Ambos caminos incluyen un umbral mínimo de módulos antes de activar la ejecución concurrente. Crear un pool de procesos tiene costos reales de memoria e inicialización — en proyectos pequeños, el overhead supera el beneficio, por lo que el trabajo se ejecuta secuencialmente en su lugar.

### **Pasadas de Análisis**

#### Detección de Código Muerto
Módulos sin aristas entrantes — nunca importados por ningún otro módulo interno. Candidatos para eliminación o consolidación.

#### Detección de Importaciones Circulares
Recorrido DFS del grafo dirigido para encontrar todos los ciclos. Reporta el camino completo del ciclo para que puedas ver exactamente qué módulos están entrelazados.

#### Análisis de Hotspots (Fan-In)
Módulos importados por más otros módulos. Alto fan-in significa alto radio de impacto — un cambio aquí afecta a todo lo que depende de él.

#### Análisis de Acoplamiento (Fan-Out)
Módulos que importan a más otros módulos. Alto fan-out significa alta fragilidad — este módulo se rompe cuando cualquiera de sus dependencias cambia.

### **Integración con Git**

Para cada módulo, DependaMan superpone datos de control de versiones sobre el análisis estructural:
- **Frecuencia de commits**: con qué frecuencia cambia este archivo (volatilidad)
- **Churn**: total de líneas añadidas + eliminadas a lo largo de la historia del proyecto
- **Último autor**: quién tocó este archivo por última vez

Combinar métricas estructurales con métricas de git revela los archivos verdaderamente peligrosos: alto fan-in + alto churn = un módulo que cambia frecuentemente del que depende todo.

### **Salida HTML Interactiva**

El renderizador produce un único archivo HTML autocontenido:
- Grafo basado en canvas/SVG con disposición dirigida por fuerzas
- Tooltips al pasar el cursor mostrando el conteo de importaciones y puntuación de churn
- Modales al hacer clic con detalle completo por módulo: dependientes, dependencias, git log, tamaño de archivo
- Sin llamadas a CDN, sin librerías externas — funciona completamente sin conexión

### **Uso**

**CLI:**
```bash
dependaman                  # analiza el directorio actual
dependaman /ruta/al/proyecto # analiza un proyecto específico
```

**API Python:**
```python
from dependaman import dependaman

html = dependaman(".", in_memory=True)  # retorna string HTML (ej. para FastAPI)
dependaman(".")                         # escribe output.html y abre en el navegador
```

### **¿Por Qué Este Proyecto?**

A medida que los proyectos Python crecen, sus grafos de importación se vuelven imposibles de razonar mentalmente. Los linters detectan errores de sintaxis; los verificadores de tipos detectan errores de tipos — pero nada te dice que tu `utils.py` es importado por 40 módulos y cambió 200 veces en el último año. DependaMan hace eso visible.
