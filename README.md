# Ringforge

**The Keyring monorepo** — a distributed agent mesh runtime.

## Components

| Directory | Language | Role |
|-----------|----------|------|
| `hub/`    | Elixir/OTP | Coordination layer — Phoenix channels, presence, CRDT sync |
| `store/`  | Rust | Storage engine — redb, BLAKE3, Merkle sync (stdin/stdout port) |
| `edge/`   | Go | Lightweight edge agent — offline-first, WebSocket sync |
| `proto/`  | Protobuf | Shared protocol definitions |
| `infra/`  | Docker/Helm | Deployment, CI/CD |

## The Six Laws

1. **Offline-first** — every node works alone
2. **Zero-config convergence** — nodes find each other and sync
3. **No SPOF** — any node can die, mesh continues
4. **Data sovereignty** — your data stays yours
5. **Transport agnostic** — QUIC, WebSocket, TCP, Bluetooth, carrier pigeon
6. **Scale invariant** — 2 nodes or 2000, same code

## License

Apache 2.0
