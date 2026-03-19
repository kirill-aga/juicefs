# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Standard build
make juicefs

# Debug build (no optimizations, no inlining)
make debug

# Lite build (minimal backends, no gateway/webdav)
make juicefs.lite

# Specialized builds
make juicefs.ceph      # With Ceph support
make juicefs.fdb       # With FoundationDB support
make juicefs.gluster   # With GlusterFS support
make juicefs.all       # All backends (ceph + fdb + gluster)

# Cross-compile for Linux from macOS (requires musl-cross)
make juicefs.linux

# Build with coverage
make juicefs.cover
```

## Testing

```bash
# Metadata engine core tests
make test.meta.core

# Metadata engine non-core tests (Redis Cluster, PostgreSQL, Etcd, KeyDB)
make test.meta.non-core

# All pkg/ tests except meta
make test.pkg

# CLI/cmd tests (requires sudo, uses minio env vars)
make test.cmd

# FoundationDB tests
make test.fdb

# Run a single test
go test -v -run TestName -count=1 -timeout=5m ./pkg/meta/...

# Property-based random testing
make unit-random-test meta=redis seed=12345 checks=100 steps=50
```

Coverage data is written to `cover/`. Tests use `-count=1` to prevent caching.

## Linting

```bash
# golangci-lint (configured in .golangci.yml, 5m timeout, skips test files)
golangci-lint run

# Pre-commit hooks (install once)
pre-commit install
```

Every source file must have the Apache 2.0 license header. Run `go fmt` before committing.

## Architecture

JuiceFS is a POSIX-compliant distributed filesystem with three layers:

```
Client (FUSE mount, S3 Gateway, WebDAV, Hadoop SDK)
   ↓
Metadata Engine (pluggable: Redis, MySQL, PostgreSQL, SQLite, TiKV, FoundationDB, Etcd, Badger)
   ↓
Object Storage (pluggable: 60+ backends including S3, Azure, GCS, HDFS, local disk)
```

### Data Model

Files are split into fixed 64 MiB **chunks** (configurable via `ChunkBits=26`). Each chunk contains variable-length **slices** representing contiguous writes. Slices are stored as 4 MiB **blocks** in object storage. Metadata (inodes, directory entries, chunk/slice mappings) lives in the metadata engine.

### Key Packages

| Package | Role |
|---------|------|
| `cmd/` | CLI commands (urfave/cli v2): mount, format, config, gc, fsck, sync, gateway, etc. |
| `pkg/meta/` | Metadata engine interface (`Meta` in `interface.go`) and implementations |
| `pkg/object/` | Object storage interface (`ObjectStorage` in `interface.go`) and 60+ implementations |
| `pkg/chunk/` | Chunk caching layer (`ChunkStore` interface) — disk/memory cache, prefetch |
| `pkg/vfs/` | Virtual filesystem layer bridging metadata + data operations |
| `pkg/fuse/` | FUSE protocol handler (uses `go-fuse/v2`) |
| `pkg/gateway/` | S3-compatible gateway |
| `pkg/compress/` | LZ4 and Zstandard compression |
| `pkg/acl/` | POSIX ACL support |
| `pkg/sync/` | Cross-storage data synchronization |

### Metadata Backend Implementations

All backends implement the `Meta` interface (`pkg/meta/interface.go`). Shared logic lives in `base.go` (~3900 lines). Backend families:

- **Redis** (`redis.go`) — uses Lua scripts for atomic transactions, sorted sets for directory entries
- **SQL** (`sql.go` + `sql_mysql.go`, `sql_pg.go`, `sql_sqlite.go`) — uses xorm ORM
- **TKV** (transactional key-value: `tkv.go` + `tkv_tikv.go`, `tkv_fdb.go`, `tkv_etcd.go`, `tkv_badger.go`) — shared key-value abstraction

### Build Tags

Feature backends are toggled via build tags. Negative tags disable features:
`nogateway`, `nowebdav`, `nocos`, `nobos`, `nohdfs`, `nosqlite`, `nomysql`, `nopg`, `notikv`, `noetcd`, `noazure`, `nogs`, `nosftp`, `noswift`, `nocifs`, `nonfs`, etc.

The `juicefs.lite` target uses all negative tags for a minimal binary.

### Entry Point

`main.go` at repo root calls into `cmd/main.go` which registers all CLI subcommands. The `mount` command wires together metadata engine → chunk store → VFS → FUSE.
