# Database Migration Regression Testing

NativeTavern's migration harness lives in
`test/support/database_migration_harness.dart`, with executable coverage in
`test/database_migration_harness_test.dart`. It opens file-backed, isolated
SQLite databases through `AppDatabase.migration`, the same migration strategy
used in production.

## What the harness covers

- A fresh database at the current schema version.
- Historical v10 and v13 fixtures reconstructed from the corresponding
  committed Drift table definitions.
- Stable logical snapshots before and after migration for primary records,
  relationships, and JSON/settings fields.
- SQLite integrity and foreign-key checks after migration.
- Rollback behavior when an upgrade fails partway through its DDL.
- Logical export and restore equivalence through `DatabaseBackupService`.

Every test creates its own temporary directory and removes it during teardown.
No app database or user file is opened.

## Adding a feature migration case

1. Add the new table or column and increment `AppDatabase.schemaVersion`.
2. Preserve the previous release schema as a `LegacyDatabaseFixture`. Prefer a
   schema copied from the last committed table definitions over one inferred
   from the new schema.
3. Seed the fixture with a small record that exercises risky values such as
   JSON, nullable fields, defaults, and foreign keys.
4. Add the affected columns to a `SnapshotTable` list. Capture the fixture
   before opening it, then compare that snapshot with the migrated database.
5. Assert the new schema version, new-column defaults or transformed values,
   `PRAGMA integrity_check`, and `PRAGMA foreign_key_check`.
6. Include the new table in `currentSnapshotTables` so backup/restore coverage
   fails until the logical backup service supports it.
7. Run the focused test, the persistence regression test, static analysis, and
   the full Flutter test suite.

Keep fixture data minimal and deterministic. Do not use a copied user database,
wall-clock timestamps, platform storage APIs, or shared filesystem locations.
