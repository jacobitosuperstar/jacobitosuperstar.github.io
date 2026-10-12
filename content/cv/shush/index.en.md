---
title: SHUSH
date: 2026-07-03
draft: false

job_title: Senior Backend / Platform Engineer (Contractor)
start_date: January 2025
end_date: Present
---

Contract role: part-time (a few hours per month) from January 2025 to
December 2025, full-time since January 2026.

- Developed and maintained the platform's backend using FastAPI, adding new
  features and improving its stability.

- Developed and maintained the platform's microservices using gRPC,
  incorporating new features and improving their stability.
  - Designed and implemented a pipeline-based architecture for request
    execution, increasing the efficiency and stability of the system's
    configuration-driven architecture.

- Packaged the per carrier releases with multi-stage Docker builds, so that
  each image ships only the code that was generated for that carrier, without
  the build toolchain or the sources behind it.

- Enforced code quality with ruff and mypy, through pre-commit hooks and
  CI-gated checks, across the Python services.

- Developed and maintained the dynamic usage-based billing system for the
  different clients that use the platform.

- Designed, developed and maintained network observability and session-lookup
  tooling for the CGNAT infrastructure of different carriers, covering up to 10
  million subscribers, built as two
  tools at two scale points, so that each carrier runs, and pays for, only the
  infrastructure that its traffic actually needs.
  - Designed and implemented a simple pipeline-based tool with a processing
    capacity of up to 150,000 messages per second.
  - Designed and implemented a more complex Kafka-backed, microservices- and
    event-based tool with a processing capacity of up to 1 million messages
    per second.
