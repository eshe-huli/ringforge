# Ringforge — Protocol Buffer Definitions

Shared `.proto` definitions for the **ringforge** mesh protocol.

## Package: `keyring.v1`

All types live under `keyring/v1/`.

### identity.proto

Core identity primitives.

| Message | Purpose |
|---|---|
| `NodeIdentity` | Ed25519 public key + name + capabilities |
| `NodePresence` | Live status of a node (ONLINE / OFFLINE / SYNCING) |

### store.proto

Content-addressed blob store and versioned document store.

| Message | Purpose |
|---|---|
| `Blob` | Immutable, BLAKE3-hashed binary object |
| `Document` | Mutable, versioned data record with CRDT state hash |

**StoreService RPCs:**

- `PutBlob` / `GetBlob` — store & retrieve blobs by hash
- `PutDocument` / `GetDocument` / `ListDocuments` — CRUD for documents

### sync.proto

Merkle-tree based state reconciliation between peers.

| Message | Purpose |
|---|---|
| `MerkleRoot` | Root hash for a single document's hash tree |
| `SyncRequest` | Node presents its current roots to a peer |
| `SyncResponse` | Peer replies with missing / needed blob hashes |

**SyncService RPCs:**

- `Reconcile` — single round-trip diff exchange

### events.proto

Mesh-wide event bus.

| Message | Purpose |
|---|---|
| `Event` | Envelope — type, source node, timestamp, `Any` payload |
| `NodeJoinedEvent` | A node joined the mesh |
| `NodeLeftEvent` | A node left / became unreachable |
| `SyncStartedEvent` | Sync session began |
| `SyncCompletedEvent` | Sync session finished |
| `BlobStoredEvent` | New blob stored |
| `DocumentUpdatedEvent` | Document created or modified |

**EventService RPCs:**

- `Subscribe` — server-stream of filtered mesh events

## Tooling

This module uses **[buf](https://buf.build)** for linting and breaking-change detection.

```bash
# Lint
buf lint proto/

# Check for breaking changes against main
buf breaking proto/ --against '.git#branch=main,subdir=proto'

# Generate code (configure buf.gen.yaml as needed)
buf generate proto/
```

## Conventions

- **Field numbering:** sequential, no gaps unless a field was removed.
- **Enums:** always start with an `_UNSPECIFIED = 0` sentinel.
- **Timestamps:** use `google.protobuf.Timestamp` everywhere.
- **Hashes:** BLAKE3, 32 bytes, represented as `bytes`.
- **Node IDs:** Ed25519 public keys, 32 bytes, represented as `bytes`.
