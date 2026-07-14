# Sync Architecture

ClipTrace sync is optional, local-first, and end-to-end encrypted. The storage
backend only sees encrypted object sizes, names, and update timing.

## Format and migration

- `SyncArchive.currentFormatVersion` is `2`.
- Version 1 snapshots remain readable. The first successful merge seeds hybrid
  logical timestamps and per-field versions, then writes a version 2 snapshot.
- The recovery key, attachment encryption, and remote `.cliptrace-sync-v1`
  directory remain compatible. No destructive remote migration is required.
- Archives reject invalid versions, duplicate entity identifiers, live/deleted
  identifier collisions, invalid clock metadata, and content-hash mismatches.
- A corrupt local `sync-state.json` is moved aside with a timestamped name and
  reported once. The following sync can rebuild state from the database and
  encrypted remote snapshot instead of silently treating corruption as a new
  device.

## Merge rules

- A hybrid logical clock (physical milliseconds, logical counter, device ID)
  supplies a deterministic total order and remains monotonic after wall-clock
  rollback.
- Clipboard and group scalar fields carry independent versions. Editing a title
  on one Mac does not overwrite a favorite change made on another Mac.
- Tags and group membership are observed sets with versioned additions and
  removals, so concurrent additions converge to a union and removals remain
  durable.
- Exact live/deleted ties favor the tombstone. A newer intentional edit may
  resurrect an older deletion.
- When non-mergeable content loses, its full record is retained as an encrypted
  conflict copy for 30 days. Attachments referenced by retained copies remain
  live as well.

## Commit protocol

1. Read and authenticate the encrypted snapshot.
2. Read immutable encrypted operation batches not covered by snapshot device
   watermarks and merge them in HLC order.
3. Build the local delta, persist it as a pending batch, merge, and verify any
   downloaded attachments by byte count and SHA-256.
4. Upload missing encrypted attachments, then publish the immutable operation
   batch with create-only semantics.
5. Commit the encrypted snapshot using compare-and-swap (`If-Match` or a local
   content revision). A conflict restarts from step 1.
6. After a successful snapshot commit, delete operations covered by its device
   watermarks and clear the pending local batch.

The journal ensures a writer's delta remains discoverable if another device
wins the snapshot race. The snapshot keeps startup bounded after journal
compaction.

## Retention

- Tombstones remain for at least 90 days and are removed only after every known
  device acknowledgement covers the deletion.
- Conflict copies remain for 30 days.
- An unreferenced remote attachment must remain continuously orphaned for seven
  days before deletion. A modification during that window restarts the grace
  period.
- Journal deletion occurs only after a compare-and-swap snapshot includes the
  corresponding device watermark.

## Backends

- iCloud Drive and local folders use atomic filesystem writes.
- WebDAV uses ETags when available and an encrypted-content revision fallback
  otherwise. Immutable objects use create-only writes.
- S3-compatible storage uses AWS Signature Version 4, paginated object listing,
  create-only immutable objects, and conditional snapshot writes. Custom
  endpoints, path-style addressing, prefixes, and temporary session tokens are
  supported.

CloudKit is intentionally not exposed yet. It requires an iCloud container and
entitlements tied to a suitable signing setup; the current self-signed release
cannot provide a dependable production CloudKit identity.
