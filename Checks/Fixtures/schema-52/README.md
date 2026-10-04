# Frozen build-52 migration fixture

This synthetic database was written by the **actual build-52 source archive**, `反馈修改前-52-源码.zip`. All 43 archived files match the independently saved `反馈修改前-52-源码校验.json`. The archive, original checksum file, every source file and generator hashes are recorded in `manifest.json`; this fixture is not generated with the current models.

The archived source declares build 52 and portable backup version 6. Its SQLite model metadata contains `TaskItem`, `TaskList`, `FinanceLedger` and `CloudSyncState`, with **no `CalendarWeekTitle` entity**. Its exported JSON has no `weekTitles` field; finance accounts and categories also predate the optional bank-name and category-parent fields.

## Contents

- `store.sqlite`: a standalone SQLite snapshot, including the original model hashes and all committed WAL data.
- `expected.json`: the old executable's portable export, still version 6 and without week titles.
- `cloud-baseline.json`: the exact bytes stored in the synthetic cloud merge baseline.
- `cloud-state.json`: expected sync consent, synthetic account binding, sync timestamp and baseline digest.
- `manifest.json`: source provenance and frozen artifact hashes.

The data covers three nested/colorized lists; four scheduled, repeating, completed, deleted and undated tasks with reminder/subtask/occurrence links; two currency accounts; a budgeted book; two synthetic categories; five entries covering a purchase linked to a task, refund, transfer with fee, missing conversion and deletion; a manual rate; and one synthetic sync state. Names, identifiers, amounts and dates are generated test values. No user database, backup, credential or live CloudKit service was used.

## Check migration

```sh
python3 Checks/check_migration.py /path/to/小记.app/Contents/MacOS/Jianshi
```

The runner verifies hashes, copies each frozen database to a fresh temporary directory and checks both build 52 and build 68. It never opens the committed database in place. The new app's self-check compares all task/list/finance records before and after saving and reopening. For old exports, only the export version and absent week titles are normalized for comparison, and the newly added week-title table must be empty. Sync consent, account, timestamp and the exact original baseline bytes are checked separately without normalization.

## Provenance and regeneration

For provenance investigation only:

```sh
python3 Checks/Fixtures/schema-52/generate.py /path/to/反馈修改前-52-源码.zip /path/to/反馈修改前-52-源码校验.json /private/tmp/schema-52-regenerated
```

The archive and checksum hashes are pinned in the generator. It verifies all source files before extracting into `/private/tmp/tally-migration52-*`, appends the synthetic export routine to the old self-check and adds an early app-initializer hook in that temporary copy. The model, finance, cloud source and original project settings remain unchanged. The build command assigns `local.jianshi.sandboxcheck.migration52`; the export hook additionally requires that identity and an explicit temporary output directory, and exits before normal app startup. The generator uses an explicit store URL with CloudKit disabled, then SQLite's backup API to produce the single-file fixture. Temporary source and executable files are removed afterward.

The output directory must not exist. Do not regenerate or replace this fixture during routine regression checks. Store UUIDs can vary between generated files; the original frozen artifact hashes remain the regression boundary. This fixture covers the archived build-52 schema and complements build 68; it does not claim coverage of every historical release or live multi-device sync.
