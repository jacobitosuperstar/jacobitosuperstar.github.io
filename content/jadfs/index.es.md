---
title: JaDFS
in_navbar: true
weight: 100
draft: false
---

## **JaDFS - Sistema de Almacenamiento Distribuido de Archivos de Jacobo**

🔗 [Ver en Codeberg](https://codeberg.org/jacobitosuperstar/JaDFS)

Un proyecto de aprendizaje para construir un sistema de almacenamiento distribuido de archivos en Go, progresando desde un servidor de archivos simple hasta un sistema de almacenamiento completamente distribuido y tolerante a fallos.

### **Visión del Proyecto**

JaDFS pretende ser un servidor de almacenamiento distribuido de archivos que:
- Divide archivos grandes en fragmentos a través de múltiples nodos
- Replica cada fragmento 3 veces para tolerancia a fallos
- Usa consenso Raft para gestión de metadatos
- Proporciona replicación sincrónica/asincrónica configurable
- Maneja fallos de nodos de forma elegante

### **Principios Básicos de Diseño**

#### Estrategia de Almacenamiento
- **Fragmentación**: Fragmentos de tamaño fijo (64MB por defecto) permitiendo archivos más grandes que cualquier nodo individual
- **Almacenamiento Híbrido**: SQLite para metadatos + sistema de archivos para datos
  - Bytes de fragmentos almacenados como archivos en disco para transmisión rápida
  - Metadatos locales en SQLite para consultas y transacciones
  - Metadatos distribuidos en Raft para coordinación a nivel de clúster
- **Direccionamiento por Contenido**: ID de fragmento = SHA256(datos) habilitando deduplicación automática

#### Replicación y Metadatos
- **Factor de Replicación**: 3 copias por fragmento
- **Gestión de Metadatos**: Consenso distribuido basado en Raft
- **Arquitectura de Dos Planos**: Plano de control (Raft) separado del plano de datos (transferencias directas)

### **Arquitectura**

El sistema usa una arquitectura de metadatos de tres capas:
1. **SQLite Local** (por nodo): Consultas locales rápidas con seguridad transaccional
2. **Clúster Raft** (distribuido): Vista a nivel de clúster con consistencia fuerte
3. **Sistema de Archivos**: Bytes de fragmentos reales para transmisión rápida

### **Estado Actual**

**Fase 1 (Implementación Completa)**: Servidor de Archivos Simple
- Almacenamiento y recuperación de archivos en un solo nodo con soporte de streaming
- API REST HTTP para carga/descarga (endpoints PUT, GET, DELETE)
- Almacenamiento híbrido SQLite + sistema de archivos con seguridad transaccional
- Fragmentación direccionable por contenido (basada en SHA256) con deduplicación automática
- Gestión de archivos y endpoints de estadísticas del nodo
- Detección de huérfanos para recolección de basura

**Fase 2 (Planificada)**: Coordinación Multi-Nodo
- Protocolo de comunicación nodo a nodo
- Elección simple de líder (basada en heartbeat, evitando la complejidad completa de Raft)
- Difusión y sincronización de metadatos entre nodos
- Operaciones de archivos distribuidos con replicación 3x
- Arquitectura centrada en nodos usando concurrencia nativa de Go (goroutines + canales)

### **¿Por Qué Este Proyecto?**

JaDFS es una exploración práctica de conceptos de sistemas distribuidos:
- Entender cómo funcionan sistemas de archivos distribuidos como HDFS y Ceph
- Aprender sobre algoritmos de consenso y tolerancia a fallos
- Practicar primitivas de concurrencia de Go (goroutines y canales)
- Construir sistemas de nivel de producción desde primeros principios

