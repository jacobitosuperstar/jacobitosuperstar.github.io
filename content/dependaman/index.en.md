---
title: DependaMan
in_navbar: false
weight: 300
draft: false
is_project: true
project_description: "A Python dependency analysis and visualization tool. Analyzes your project's internal module structure and produces an interactive HTML graph — surfacing cycles, dead modules, hotspots, and coupling issues with zero external dependencies."
project_dates: "25/03/2026 – present"
project_link: "https://codeberg.org/jacobitosuperstar/DependaMan"
---

## **DependaMan - Python Dependency Analyzer**

🔗 [View on Codeberg](https://codeberg.org/jacobitosuperstar/DependaMan)

A command-line tool and Python library that analyzes a project's internal module structure and produces an interactive HTML graph. It surfaces architectural problems — circular imports, dead code, coupling hotspots — using nothing but the Python standard library.

### **Project Vision**

DependaMan aims to answer the questions that get harder to answer as a codebase grows:
- Which modules does everyone depend on?
- Which modules are never imported by anything?
- Where are the import cycles hiding?
- Which files change the most and are imported the most — the highest-risk hotspots?

### **Core Design Principles**

#### Zero External Dependencies
The entire tool runs on Python's standard library (`ast`, `pathlib`, `json`, `subprocess`, `concurrent.futures`). No pip install required beyond the package itself — works in any environment.

#### Pipeline Architecture
The analysis is split into six discrete phases, each with a single responsibility:
1. **Discovery** — walks the project tree, identifies Python modules, determines package roots, and separates internal from external code
2. **Parsing** — uses `ast` to extract imports from each file, resolves relative imports, and filters to internal-only edges
3. **Graph Construction** — builds a directed graph where nodes are modules and edges represent import relationships
4. **Analysis** — runs four independent passes over the graph: dead code detection, circular import detection (DFS-based), hotspot analysis (fan-in), and coupling analysis (fan-out)
5. **Git Integration** — queries `git log` per file to extract commit frequency, lines added/removed, and last author
6. **Rendering** — produces a self-contained HTML file with an interactive canvas graph and no external JS dependencies

#### Concurrency Strategies
DependaMan applies two different concurrency strategies depending on the nature of the work:

- **Git stats (I/O-bound)** — fetching per-file git metrics involves waiting on subprocess calls, not CPU work. `ThreadPoolExecutor` is used here so multiple `git log` calls run concurrently without the overhead of spawning separate processes.
- **Parsing (CPU-bound)** — `ast` parsing is pure computation. When the module count is high enough, DependaMan switches to `ProcessPoolExecutor` to bypass the GIL and use multiple cores in parallel.

Both paths include a minimum module threshold before engaging concurrent execution. Spawning a process pool has real memory and startup costs — for small projects, the overhead exceeds the benefit, so the work runs sequentially instead.

### **Analysis Passes**

#### Dead Code Detection
Modules with no incoming edges — never imported by any other internal module. Candidates for removal or consolidation.

#### Circular Import Detection
DFS traversal of the directed graph to find all cycles. Reports the full cycle path so you can see exactly which modules are entangled.

#### Hotspot Analysis (Fan-In)
Modules imported by the most other modules. High fan-in means high blast radius — a change here affects everything that depends on it.

#### Coupling Analysis (Fan-Out)
Modules that import the most other modules. High fan-out means high fragility — this module breaks whenever any of its dependencies change.

### **Git Integration**

For each module, DependaMan overlays version control data on top of the structural analysis:
- **Commit frequency**: how often this file changes (volatility)
- **Churn**: total lines added + removed over the project's history
- **Last author**: who last touched this file

Combining structural metrics with git metrics reveals the truly dangerous files: high fan-in + high churn = a frequently-changing module that everything depends on.

### **Interactive HTML Output**

The renderer produces a single, self-contained HTML file:
- Canvas/SVG-based graph with force-directed layout
- Hover tooltips showing import count and churn score at a glance
- Click modals with full per-module detail: dependents, dependencies, git log, file size
- No CDN calls, no external libraries — works fully offline

### **Usage**

**CLI:**
```bash
dependaman                  # analyze current directory
dependaman /path/to/project # analyze a specific project
```

**Python API:**
```python
from dependaman import dependaman

html = dependaman(".", in_memory=True)  # returns HTML string (e.g. for FastAPI)
dependaman(".")                         # writes output.html and opens in browser
```

### **Why This Project?**

As Python projects grow, their import graphs become impossible to reason about mentally. Linters catch syntax errors; type checkers catch type errors — but nothing tells you that your `utils.py` is imported by 40 modules and changed 200 times in the last year. DependaMan makes that visible.
