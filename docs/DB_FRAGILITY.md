# The local database: how it breaks, and what we did about it

Written 2026-07-13, after an install was **permanently bricked** — every write
threw, the caregiver was stranded on onboarding with "Couldn't save just now",
and reinstalling the app did not help because the database file outlives it.
That day also destroyed a tester's care record. Both were self-inflicted.

This is the audit. It is deliberately blunt, because the failure mode of this
component is *a caregiver loses their loved one's medication list*, and the
failures we shipped were all preventable.

---

## The two facts that make this component dangerous

1. **The database file outlives the app.** Deleting and reinstalling the app on
   iOS does NOT clear the app's Documents directory in the way people assume for
   a dev-installed build; a corrupt or wrongly-stamped file survives. So a bug
   that wedges the database wedges it *permanently*, and the user has no escape
   hatch — they cannot "just reinstall".
2. **Drift's migration runner is not transactional.** It executes the steps,
   and only *afterwards* writes the new `user_version`. There is no rollback.
   So **any interruption — a crash, an OOM kill, a user swiping the app away
   mid-launch — leaves a half-migrated file that re-runs the same steps on the
   next launch.**

Together those mean: **every migration step must be safe to run twice**, or the
app is one bad launch away from bricking a user forever.

---

## What actually broke (2026-07-13)

| # | Bug | Effect |
|---|-----|--------|
| 1 | Every call to `HoldcloseDatabase.open()` eagerly built a throwaway executor, each of which raced to mint its own SQLCipher key | The DB ended up encrypted under a key nobody kept → `file is not a database` on every launch → **care record destroyed** |
| 2 | Added an iOS keychain `accessibility` class to the DB key | `flutter_secure_storage` ≥9.1 puts `kSecAttrAccessible` in the **read** query and Apple only honours it on first write → the key became invisible → the DB looked unopenable → **care record quarantined**, every save failed |
| 3 | The quarantine step **deleted** the previous quarantine | One more false alarm would have destroyed the **only surviving copy** |
| 4 | `sqlcipher_export` (the decrypt) carries schema + rows but **not `user_version`** | Drift saw version 0, called a populated database "new", ran `createAll()` over it, and died on a bare `CREATE INDEX ... already exists` → **every write failed, forever** |

Note the shape: **#4 was not an encryption bug at all.** It was a
copy-loses-the-version-stamp bug, wearing an encryption costume. We spent hours
looking at crypto because that is where the previous three bugs were.

---

## Decision: app-level encryption is GONE

`sqlcipher_flutter_libs` removed; the DB is a plain SQLite file
(`lib/db/local_db.dart`).

**Why.** It caused four ways to lose or brick a caregiver's data in one day and
prevented zero attacks. Meanwhile **both platforms already encrypt this file at
rest**: iOS Data Protection, and Android file-based encryption (mandatory since
Android 10; FDE below that — our floor is API 26). App data lives in
credential-encrypted storage, unreadable before first unlock. SQLCipher only
added cover for a **rooted/jailbroken device while unlocked**, or a raw copy
lifted from a running phone.

**If it ever comes back:** use drift's supported stack (SQLite3MultipleCiphers
on `sqlite3` 3.x — NOT the obsolete `sqlcipher_flutter_libs`, whose 0.7.0+
releases are no-op shims), keep the key lifecycle boring (read; mint once if
absent; never touch keychain options after release), and **carry `user_version`
across any export or copy**.

---

## The failure surface, enumerated

### A. Migrations (highest risk — this is what bricks people)

| Operation | Drift emits | Safe to re-run? | Status |
|---|---|---|---|
| `m.createTable` | `CREATE TABLE IF NOT EXISTS` | ✅ yes | fine |
| `m.createIndex` | bare `CREATE INDEX` | ❌ **no** | **fixed** — v20 uses `CREATE INDEX IF NOT EXISTS` |
| `m.addColumn` | bare `ALTER TABLE ADD COLUMN` | ❌ **no** | **fixed** — v17 goes through `_addColumnIfMissing` |
| `customStatement('DROP TABLE IF EXISTS …')` | as written | ✅ yes | fine |
| `customStatement('DELETE FROM …')` | as written | ✅ yes (idempotent by nature) | fine |

**Rule, now enforced by tests:** a migration step must be safe to run twice.
`test/db/migration_resilience_test.dart` re-runs the whole v1→v20 path over an
already-migrated database and requires it to complete.

### B. The version stamp (`user_version`)

Drift keys its ENTIRE migration decision off this one integer. A populated
database stamped `0` is treated as brand new.

**Anything that copies a SQLite file can drop it**: `sqlcipher_export`,
`VACUUM INTO`, some backup/restore tools. We hit this. `stampSchemaVersionIfMissing()`
now repairs it on open: if `user_version == 0` **and** our tables are present,
stamp it. (A genuinely empty file is left alone so drift creates the schema
normally — tested.)

### C. App updates

- **Normal update (v20 → v21):** container persists, `onUpgrade` runs. Safe iff
  every step is idempotent (see A) — because an update is exactly when a
  half-applied migration can happen.
- **Downgrade** (tester installs an older build; possible with dev/TestFlight
  builds, not the App Store): drift calls `onUpgrade(from: 20, to: 19)`. Our
  steps are all `if (from < N)` so nothing runs, and the file is re-stamped to
  the lower version. The schema still has the newer tables/columns, which the
  old code ignores. Re-upgrading later re-runs those steps — **which is only
  survivable because they are now idempotent.** Before today, a downgrade
  followed by an upgrade would have bricked the install.
- **Reinstall:** deleting the app removes the container on iOS — **all local
  care data is gone** unless it synced (see E).

### D. Deliberate wipes — the ones that can hit a real user

- `maybeResetForDemo()` — wipes + reseeds when `DEMO_MODE` **and** the settings
  toggle is on. Off by default, demo builds only.
- `maybeSeedDemoDataset()` — **`storage.reset()` wipes the whole database**, then
  seeds six months of fake data. Fires when `SEED_DEMO=true` **and** a
  `SEED_TOKEN` is baked in that differs from the last-applied one.
  ⚠ **`tools/run_device.sh SEED=1` sets both.** A build handed to a tester with
  `SEED=1` will silently destroy their real care data on first launch. The token
  guard means it happens once per build, which is no comfort to the person whose
  data it was. **Do not ship SEED=1 to anyone who has real data.**

### E. There is no backup. At all.

- iOS: the DB directory is **excluded from iCloud/iTunes backup**
  (`_excludeIosDataFromBackup`).
- Android: `allowBackup="false"`.
- Server sync is the *only* copy — and it was **broken** (the phone was bound to
  a circle that returned 404 on every push and pull, so nothing had synced;
  fixed 2026-07-13 by unbinding and re-bootstrapping on a 404).

So today: **device lost, phone replaced, or app deleted ⇒ the care record is
gone permanently.** That is a product-level risk, not a code bug, and it is
worth a deliberate decision:
1. keep sync healthy and treat it as the backup (it must then be *monitored*, not
   assumed), and/or
2. reconsider the backup exclusion now that the DB is no longer encrypted — the
   exclusion was defence-in-depth *for encrypted data*; with plaintext + platform
   encryption, allowing iCloud backup may serve caregivers better than protecting
   them from a threat they don't have.

### F. Concurrency

`HoldcloseDatabase.open()` returns a **process-wide singleton** — one connection
for every repository and the sync engine. This is deliberate: separate
connections to one file produced `SQLITE_BUSY` "database is locked" failures.
WAL + `busy_timeout` remain as defence in depth. Do not reintroduce a second
connection.

### G. Quarantine (the last-resort path)

An unreadable file is **moved aside, never deleted**, and never overwrites an
earlier quarantine (the first takes `.quarantined`; later ones get timestamped
siblings). A quarantined file we *can* read is restored on the next open. A file
we cannot read may still be someone's only copy — that is the whole point.

---

## The rules, short enough to remember

1. **Every migration step must be safe to run twice.** Assume it will be.
2. **`user_version` is load-bearing.** Anything that copies the DB must carry it.
3. **Never delete a user's database file.** Move it aside; keep every generation.
4. **A keychain option change is a data migration**, not a config tweak.
5. **The DB file outlives the app** — a wedge is permanent, so wedges are the
   most expensive class of bug we can ship. Prefer "start fresh, keep the old
   file" over "fail forever".
6. **Test the file, not the mock.** These bugs are invisible to in-memory tests;
   `test/db/migration_resilience_test.dart` runs against real files on disk.
