# Frozen build-68 migration fixture

This is synthetic data written by the **actual build-68 persistence code**, pinned to Git commit `6614558dbb888ae9b453f54be3ed4e0fd36f8466` (`baseline-1.0-68`). It is not a database generated from whichever model the current branch happens to contain.

## Contents

- `store.sqlite`: standalone SQLite snapshot, including the old Core Data model hashes.
- `expected.json`: portable export from the same old executable after saving.
- `cloud-baseline.json`: exact bytes stored in the synthetic `CloudSyncState.baseline`.
- `cloud-state.json`: expected enabled flag, synthetic account identifier, last-sync timestamp and baseline digest.
- `manifest.json`: pinned source commit, model-source hashes, generator hashes, Xcode version and frozen artifact hashes.

The fixture contains three nested/colorized lists; four tasks covering repeat links, completed/deleted/undated states, reminders and subtasks; one week title; two currency accounts with bank labels; one budgeted book; parent/child categories; five entries including a transfer with fee, refund, missing conversion and deleted entry; one manual rate; one enabled but synthetic sync state. All identifiers, dates, names and amounts are test values. No personal data, credentials or live CloudKit access are involved.

## Run against a new build

From the project directory:

```sh
python3 Checks/check_migration.py /path/to/小记.app/Contents/MacOS/Jianshi
```

The runner checks fixture hashes, copies only `store.sqlite` into a temporary directory, and runs `--self-check` with `JIANSHI_MIGRATION_COPY`, `JIANSHI_MIGRATION_EXPECTED`, `JIANSHI_MIGRATION_CLOUD_BASELINE` and `JIANSHI_MIGRATION_CLOUD_STATE`. SwiftData never opens the committed fixture in place. The app exits its self-check before normal app storage, reminders or cloud services start.

## Provenance and regeneration

`generate.py` exports only the pinned Git commit to `/private/tmp/tally-migration68-*`, appends `generate.swift` to that temporary copy's self-check, and inserts an early fixture-export hook in the temporary app initializer. The original model, finance and cloud files are unchanged and their hashes are recorded. It builds under the isolated identity `local.jianshi.sandboxcheck.migration68`, opens an explicit temporary store URL, then uses SQLite's backup API to capture committed WAL data. The final snapshot uses a single database file with no WAL dependency.

For provenance investigation only:

```sh
python3 Checks/Fixtures/schema-68/generate.py /private/tmp/schema-68-regenerated
```

The output directory must not exist. Never regenerate or replace this fixture as part of a routine check: doing so would erase the regression boundary. SQLite internal store UUIDs can differ between independently generated files; portable records and their stable identifiers are deterministic. Keep this fixture when adding a later schema fixture.

This proves upgrades from the pinned **68 schema**. It does not claim coverage of every earlier release's schema or of real-device performance; older released database layouts need their own frozen synthetic fixtures.
