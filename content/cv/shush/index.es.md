---
title: SHUSH
date: 2026-07-03
draft: false

job_title: Ingeniero Backend / de Plataforma Senior (Contratista)
start_date: Enero 2025
end_date: Presente
---

Contrato por prestación de servicios: medio tiempo (unas pocas horas al
mes) desde enero de 2025 hasta diciembre de 2025, tiempo completo desde
enero de 2026.

- Desarrollé y mantuve el backend de la plataforma usando FastAPI, agregando
  nuevas funcionalidades y mejorando la estabilidad del mismo.

- Desarrollé y mantuve los microservicios de la plataforma utilizando gRPC,
  incorporando nuevas funcionalidades y mejorando su estabilidad.
  - Diseñé e implementé una arquitectura basada en pipelines para la ejecución
    de solicitudes (requests), aumentando la eficiencia y estabilidad de la
    arquitectura basada en configuración del sistema.

- Empaqueté las entregas por carrier con construcciones de Docker en varias
  etapas, de modo que cada imagen envía únicamente el código generado para ese
  carrier, sin las herramientas de construcción ni las fuentes detrás de él.

- Mantuve la calidad del código con ruff y mypy, mediante ganchos de
  pre-commit y validaciones obligatorias en la integración continua, en todos
  los servicios de Python.

- Desarrollé y mantuve el sistema de facturación dinámica por uso de los
  diferentes clientes que usan la plataforma.

- Diseñé, desarrollé y mantuve herramientas de observabilidad de red y búsqueda
  de sesiones para infraestructura de CGNATs de diferentes carriers, que cubren
  hasta 10 millones de suscriptores,
  construidas como dos herramientas en dos puntos de escala distintos, para que
  cada carrier opere, y pague, solamente la infraestructura que su tráfico
  realmente necesita.
  - Diseñé e implementé una herramienta simple basada en pipelines con
    capacidades de procesamiento de hasta 150 mil mensajes por segundo.
  - Diseñé e implementé una herramienta más compleja basada en microservicios y
    eventos, soportada en Kafka, con capacidad de procesamiento de hasta 1
    millón de mensajes por segundo.
