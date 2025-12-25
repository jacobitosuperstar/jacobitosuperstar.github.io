---
title: JaDFS
in_navbar: true
weight: 100
draft: false
---

## **JaDFS - Jacobo Distributed File Storage System**

🔗 [View on Codeberg](https://codeberg.org/jacobitosuperstar/JaDFS)

A learning project to build a distributed file storage system in Go, progressing from a simple file server to a fully distributed, fault-tolerant storage system.

### **Project Vision**

JaDFS aims to be a distributed file storage server that:
- Splits large files into chunks across multiple nodes
- Replicates each chunk 3 times for fault tolerance
- Uses Raft consensus for metadata management
- Provides configurable sync/async replication
- Handles node failures gracefully

### **Core Design Principles**

#### Storage Strategy
- **Chunking**: Fixed-size chunks (64MB default) allowing files to be larger than any single node
- **Hybrid Storage**: SQLite for metadata + filesystem for data
  - Chunk bytes stored as files on disk for fast streaming
  - Local metadata in SQLite for queryability and transactions
  - Distributed metadata in Raft for cluster-wide coordination
- **Content-Addressable**: Chunk ID = SHA256(data) enabling automatic deduplication

#### Replication & Metadata
- **Replication Factor**: 3 copies per chunk
- **Metadata Management**: Raft-based distributed consensus
- **Two-Plane Architecture**: Control plane (Raft) separate from data plane (direct transfers)

### **Architecture**

The system uses a three-layer metadata architecture:
1. **Local SQLite** (per node): Fast local queries with transaction safety
2. **Raft Cluster** (distributed): Cluster-wide view with strong consistency
3. **Filesystem**: Actual chunk bytes for fast streaming

### **Current Status**

**Phase 1 (Implementation Complete)**: Simple File Server
- Single node file storage and retrieval with streaming support
- HTTP REST API for upload/download (PUT, GET, DELETE endpoints)
- Hybrid SQLite + filesystem storage with transaction safety
- Content-addressable chunking (SHA256-based) with automatic deduplication
- File management and node statistics endpoints
- Orphan detection for garbage collection

**Phase 2 (Planned)**: Multi-Node Coordination
- Node-to-node communication protocol
- Simple leader election (heartbeat-based, avoiding full Raft complexity)
- Metadata broadcast and synchronization across nodes
- Distributed file operations with 3x replication
- Node-centric architecture using Go's native concurrency (goroutines + channels)

### **Why This Project?**

JaDFS is a hands-on exploration of distributed systems concepts:
- Understanding how distributed file systems like HDFS and Ceph work
- Learning about consensus algorithms and fault tolerance
- Practicing Go's concurrency primitives (goroutines and channels)
- Building production-grade systems from first principles

