---
title: EarthFuneral
date: 2025-12-12
draft: false

job_title: Senior Backend Engineer
start_date: March 2025
end_date: December 2025
---

Real-time monitoring platform for a fleet of around 1,000 machines.

- Developed and maintained the platform’s backend using Django, adding new
  features and improving overall stability.

- Built a real-time data processing system with MQTT (pub/sub), WebSocket
  broadcasting, Redis caching, and asynchronous task execution with Celery,
  sustaining 150 to 160 sensor messages per second.

- Modelled each composting machine as a digital twin that the operators drive
  from the web platform, with a state watcher underneath reconciling the
  physical equipment against the virtual one, and correcting it when the two
  diverged.

- Implemented a multi-database architecture using PostgreSQL for transactional
  data and TimescaleDB for time-series storage, connected through a custom
  database router.

- Developed an alert-response system that detects equipment failures via MQTT,
  triggers automated actions through Celery, and sends immediate notifications
  to monitoring dashboards via WebSocket.

- Improved overall performance by optimizing queries, adding indexes, and using
  Redis to speed up frequent data access, cutting the database usage from 60%
  to 45%.
