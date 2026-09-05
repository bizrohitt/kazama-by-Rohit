# SESSION_LOG — append-only

Newest entry last. A future session reads `MASTER_PROMPT.md` first, then the **last entry here**.

---

## Session 1 — 2026-09-03 · Phase 0 (all batches) + Phase 1 (plan) — **no code written**

**Branch:** `arena/01a06866-kazama-by-rohit` (from `main` @ `513e578`, which contained only `README.md`).

### What happened
1. Repo verified empty → cold start, nothing to resume (R7).
2. Sandbox probed: no `flutter`/`dart`/`java`/`adb`/Android SDK; `pub.dev`, `storage.googleapis.com`
   and apt mirrors **blocked**; `github.com`/`api.github.com`/release downloads, npm and PyPI reachable.
   → Flutter cannot be installed or verified here; no Dart VM obtainable (only source tags, no binaries).
3. Phase 0 Batch 1 asked → answered **Flutter · single restaurant · offline-first with sync queue**,
   test target "my Android realme phone + Android Studio emulator". (An initial framing of the batch was
   answered, then the user asked to restart with all nine questions re-explained; the restart batch was
   re-answered identically, so Q1–Q3 are confirmed twice.)
4. Batch 2 asked → **module order = user's custom two-section flow**, **cash + manual split**, **no scanning**.
5. Q4 free text drove the biggest design decision: **separate order-taking and billing sections**,
   because dine-in guests pay after eating while takeaway pays upfront → ticket state machine, held-tickets
   due list, "order taking never touches money / billing never touches the menu".
6. Batch 3 (backend, brand, licence, printer hardware) was **skipped by the user** → the four decisions were
   **assumed and flagged** in `MASTER_PROMPT.md` §2 for veto during approval, rather than asked again.
7. Phase 1 delivered as documents only (R4/R3): flow diagram, module map, 47-task backlog in 10 phases.

### Files created this session
| File | Purpose | Lines |
|---|---|---|
| `MASTER_PROMPT.md` | resume contract: prompt + all answers + assumptions + decisions + setup | ~150 |
| `PROJECT_FLOW.md` | flow diagram, schema, module map, live backlog | ~215 |
| `SKILLS.md` | reusable techniques (money/paise, outbox, seam, ESC/POS, licence vetting) | ~185 |
| `SESSION_LOG.md` | this file | — |
| `README.md` | project cover + entry points | ~30 |

No `lib/`, no `pubspec.yaml`, no Dart file exists yet — by design.

### Decisions summary (one line each)
Flutter · single outlet · offline-first SQLite (drift) + dormant sync outbox · Riverpod · Money = int paise
· uuid PKs + local bill seq · append-only order_events · PrintTransport with fake first · cash+UPI+card+CREDIT
split ledger · reports as SQL aggregates · inventory deduct-on-fire · staff PIN auth last · MIT app code,
permissive-only deps · polish phase after all v1 features pass.

### Assumptions awaiting veto
Q6 no scanning (but `barcode` column in schema) · Q7 SQLite + Supabase-shaped seam + backup export ·
Q8 `Kazama POS` + named colour tokens, no logo yet · Q9 sell-safe permissive-only + MIT · Q10 no printer
hardware, fake transport first.

### Open questions (ask once at the start of Session 2)
1. Receipt paper width — **58 mm (32 cols)** or **80 mm (48 cols)**? Blocks P1/P2 template detail.
2. Do you own a Bluetooth/Wi-Fi ESC/POS printer now, and which model? Decides whether P4 is scheduled or parked.
3. GST rates actually used (5 / 12 / 18 / 28 %) and are menu prices **tax-inclusive**? Changes Y5 defaults.
4. Is staff PIN needed on day 1 (before payments), or is Phase S fine last? Affects phase ordering only.

### Next steps (Session 2)
1. Get plan approval (⛔ gate not yet passed — do not code without it).
2. User runs `flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .` +
   `flutter pub get` at repo root on their machine; commit the scaffold.
3. **Task T1 — `Money` value object** (`core/money/money.dart` + `test/core/money_test.dart` +
   `tools/check_money.dart`). Expected result: `dart run tools/check_money.dart` → `12/12 PASS`,
   `flutter test test/core/money_test.dart` → all green. Then "Tested? Pass/Fail?"
4. Session summary due after 3 completed tasks (T1, T2, T3) per Phase 2 §7.

---

## Session 2 — 2026-09-03 · Plan approved → **Task T1 code written (⏳ awaiting Pass/Fail)**

**Loop step 1 — task & module:** T1 `Money` value object. Touched `lib/core/money/` only, plus its
test and its verification script. No drift, no UI, no other module imported it, nothing imports it.

**Files created (R2 check — all far under 600):**

| File | Lines | What it is |
|---|---|---|
| `lib/core/money/money.dart` | 271 | immutable int-paise value object: parse/rupees, `+ - scale sum`, `percentOf`, half-up int division, taxFromInclusive / taxOnExclusive / grossFromExclusive, `roundedToRupee` + `roundingAdjustment` (ROUNDING line), `changeFor`, `split` (largest remainder), toJson/fromJson, `==`/`hashCode`/`compareTo`/`< <= > >=`, `toString` |
| `tools/check_money.dart` | 181 | zero-dependency runnable gate: 12 numbered cases + 3 invariant fuzz groups (2000 cases each, seed 42). `dart run` only — no `pub get`, no flutter |
| `test/core/money_test.dart` | 144 | `flutter_test` mirror with extra edge cases (empty sum, sort order, Set dedup, `fromJson(null)`, absurd 150% tax bound) |

**Two self-caught bugs (documented so they are not re-introduced):**
1. `Money.parse` rounded the fraction half-up but **lost the carry** → ₹12.999 became ₹12.00. Fixed:
   carry now increments the rupee part.
2. `roundingAdjustment` had a dead ternary branch (`roundedToRupee()` is always `>=` the original).
   Removed; behaviour unchanged.

**Verification I could do here:** line counts, brace/paren/bracket balance (all 0), confirmation that
`core/money/` has **no imports at all**, and hand-computed expected values in both test files.
**Verification I could not do:** execution — no Dart VM obtainable in this sandbox (probed again:
`dart-lang/sdk` releases expose 0 binary assets, `dart.dev` and `storage.googleapis.com` blocked).
Expected values in the check script are computed by hand, deliberately not by running the code.

**Gate handed to the user:** `dart run tools/check_money.dart` must print `12/12 PASS` and exit 0;
`flutter test test/core/money_test.dart` all green. **Awaiting "Tested? Pass/Fail".**

**Docs updated:** `PROJECT_FLOW.md` (T1 → ⏳ with file/line detail, status table, Phase-2 started banner),
`SKILLS.md` (§B4 largest-remainder allocation), this file. Still no `pubspec.yaml` / no scaffold — the user
runs `flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .` before T1 can run
(package name must stay `kazama_pos` or the `package:` import in the test file needs editing).

**RESULT: PASS** (2026-09-03). T1 → ✅.

**Next task:** T2 — enums + immutable models with JSON codecs, `data/models/` only, no drift yet.
**Session summary due after 3 tasks** → will follow T2 and T3.

---

## 📋 SESSION SUMMARY #1 — after 1 completed task (T1)

*Summary cadence is "every 3 tasks"; issuing this one early because the user may close the session now.
A fresh session resumes from here + `MASTER_PROMPT.md` §5 — nothing else needs to be re-read.*

**Approved & passed**
- Plan (47 tasks / 10 phases) approved 2026-09-03. Assumptions in `MASTER_PROMPT.md` §2 stand as written
  (no scanning / local SQLite + sync seam / `Kazama POS` placeholder brand / sell-safe MIT + permissive-only deps /
  fake print transport first).
- **T1 `Money` — ✅ PASSED** by user verification.

**Files created this session (597 Dart lines total)**
| Path | Lines | Note |
|---|---|---|
| `lib/core/money/money.dart` | 271 | 45% of the 600-line budget; **0 imports** |
| `tools/check_money.dart` | 181 | zero-dependency gate (works before `pub get`) |
| `test/core/money_test.dart` | 144 | 34 tests |
| `PROJECT_FLOW.md` | 311 | status now live: T1 ✅ |
| `SKILLS.md` | 212 | added §B4 largest-remainder split |
| `MASTER_PROMPT.md` / `SESSION_LOG.md` / `README.md` / `LICENSE` | 156 / 129 / 41 / 21 | unchanged in structure |

**Lines used vs limits:** 271 of 600 max per file (no file within 300 lines of the cap → no split pressure yet).
**Git:** branch `arena/01a06866-kazama-by-rohit`, commit `4763f7d` (+ doc commits). Not pushed to `main` — user's call.

**Sandbox truth for the next session:** no Flutter/Dart/Java/Android SDK, `pub.dev` + `storage.googleapis.com` +
apt mirrors blocked, GitHub/npm/PyPI reachable. **Never** write a task whose only test is something I run here.

**Known debt deliberately left in T1** (fix in T2, do not silently accumulate):
`Money.roundingAdjustment` returns a **non-negative** `Money`, so a total that is *lower* than the sum of
its lines (possible if a discount is over-applied) would throw instead of showing `−1p` on the receipt.
A receipt needs a signed ROUNDING line. Planned fix: add `roundingAdjustmentSignedPaise` (int, may be < 0)
and keep `roundingAdjustment` for the common case, documented on both.

**Next task: T2 — enums + immutable models + JSON codecs** (`lib/data/models/` only).
Deliverables planned: `enums.dart`, `menu.dart`, `order.dart`, `payment.dart`, `staff.dart`, `report.dart`,
`tools/check_models.dart`, `test/data/models_test.dart`. Still zero drift, zero Flutter, zero UI.
Hard requirement: every `toJson`/`fromJson` round-trip is asserted per model, and `order.dart` carries the
status state machine helpers that T3's drift tables and O1 will both read.

**If the session restarts:** read `MASTER_PROMPT.md` (all decisions + setup commands) → last entry here →
`PROJECT_FLOW.md` §3 for the queue. Do not re-ask Q1–Q5; four open questions are listed in `SESSION_LOG.md`
Session 1 §"Open questions" and are only blocking at P1 / Y5 / S.


---

## Task T2 — enums + models + codecs + MoneyDelta (2026-09-03) — ⏳ code written, awaiting Pass/Fail

**Module touched:** `lib/data/models/` + one new file in `lib/core/money/` (`money_delta.dart`).
T1's `money.dart` left byte-identical (already ✅) — the signed-rounding need was met with an
**extension** in the new file instead of editing a passed module.

**Files (all balanced, all under the 600 cap; total Dart now 3,909 lines):**
`deep_eq.dart` 63 · `enums.dart` 184 · `menu.dart` ~416 · `order_line.dart` 211 · `order.dart` 448 ·
`payment.dart` 270 · `staff.dart` 295 · `report.dart` 266 · `mutation.dart` 153 ·
`money_delta.dart` 90 · `tools/check_models.dart` 453 · `test/data/models_test.dart` 470.

**R2 in action:** `order.dart` reached **518 lines** mid-task → split `OrderDiscount` + `DiscountKind` +
`TicketLine` into `order_line.dart`, with `order.dart` re-exporting them so callers keep one import.

**Cycles:** none. `enums → (nothing)`; `menu → money`; `order_line → menu,enums,money`;
`order → order_line,menu,enums,money,money_delta`; `payment → order,enums,money`;
`staff → payment,enums,money,money_delta`; `report → enums,money,money_delta,deep_eq`.

**Six defects self-caught during review (each was a real runtime bug, no test run needed to find them):**
1. `Money.parse` lost the round-up carry (T1, fixed pre-handover) — ₹12.999 → ₹12.00.
2. `BillTotals.subtotal` was a no-op expression (`base + d - d`); renamed to `netBeforeTax = total − tax`
   so the printed receipt **foot** (`net + tax == total`) even when rounding is negative, and
   `grossBeforeDiscount` now reads the real `lineBase`.
3. `as List<dynamic>?` on decoded JSON would have thrown for any `List<String>` field (5 sites) →
   `as List<Object?>?`. New SKILLS §G1.
4. `ModifierOption.copyWith(activeSet: …)` could never set `false` → `activeOverride`. New SKILLS §G2.
5. `fired()` guard was logically inverted (an open ticket with nothing pending threw nothing).
6. `cancelledLine` evaluated `quantity ?? l.liveQuantity` twice, so the qty and the status could disagree
   after a partial cancel → extracted `_cancel()`.

**Also:** value equality (`==`/`hashCode`) added to all 14 models *specifically* so the gate can assert
`M.fromJson(m.toJson()) == m` — a dropped field in either codec now fails loudly. Structural compare for
nested lists/maps via `deep_eq.dart` rather than pulling `package:collection`.

**Not yet verified:** nothing executed (no Dart VM here). The gate for the user is
`dart run tools/check_models.dart` (expect `14/14 PASS … 0 failures`, exit 0) and
`flutter test test/data/models_test.dart`.

**Next:** T3 — drift `AppDatabase`, tables, `schemaVersion`, migration scaffold (`core/db/` + `data/tables/`).
First task that needs `pub get`, i.e. first one where the user's environment can genuinely fail for
non-code reasons — flagged in the handover.


---

## Task T3 — drift schema + AppDatabase + DAOs (2026-09-03) — ⏳ code written, awaiting Pass/Fail

**Module touched:** `lib/core/db/`, `lib/data/tables/`, `lib/data/daos/`, plus the first `pubspec.yaml`.
`flutter create` has NOT been run by the user yet, so `pubspec.yaml`/`analysis_options.yaml` are now
authored by me; `main.dart`/`android/`/`ios/` are still absent and must appear via
`flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .` (it will not
overwrite an existing pubspec only if run before edits — if it complains, scaffold in a temp dir and
copy in `android/ ios/ lib/main.dart test/widget_test.dart`).

**T2 was never given a verdict** — the user replied "continue". Both T2 and T3 stay ⏳. Their gates are
merged on purpose: `app_database_test.dart` writes models and reads them back, so a codec bug in T2
shows up as a named failing test in T3.

**Files:** `pubspec.yaml` 52 · `core/db/app_database.dart` 110 · `core/db/connection.dart` 56 ·
`data/tables/{menu,order,money}_tables.dart` 148/158/177 · `data/daos/{dao_base,menu_dao,orders_dao}.dart`
30/182/232 · `test/core/app_database_test.dart` 322 · `tools/setup_check.sh`.
Dart total now **5,323 lines**, largest file 470 — no file over 600, verified by script.

**Design decisions made in code, not just docs:**
- `app_meta.synced_at`-style upload markers: **no**. The outbox is the only sync state; two sources drift.
- Enums stored as **text names**, not indices (a reordered model must not corrupt stored rows).
- `Money` has **no drift TypeConverter**; DAOs map `int paise` explicitly so raw report SQL sees the unit.
- `orders.bill_number` is `integer NULLABLE UNIQUE` — SQLite lets many NULLs coexist, which is exactly
  what an unnumbered draft needs.
- FK policy: cascade only `order_lines`; money rows keep a plain indexed `order_id` (see SKILLS §H4).
- No background isolate for the DB (justified in `connection.dart` header).
- `menu_items.modifier_group_ids` is JSON text instead of a join table (single-category ownership, <10 rows).
- DAOs are `with`-mixed into `AppDatabase` via `part` files instead of `@DriftAccessor` — fewer moving parts.

**Five bugs found by review (no runtime available, so review is the only filter):**
1. `DatabaseConfig(sendMustUnawaited:true)` — invented API, drift has no such class → dropped.
2. `const AppMetaCompanion.insert(updatedAt: DateTime.now())` — not a const expression → helper method.
3. `Orders0` placeholder class to satisfy a cross-file `references()` — drift codegen would reject it →
   `payments.order_id` is a plain indexed TEXT (H4).
4. `updatedAt: now` passed where a companion needs `Value(now)` (3 sites) → fixed.
5. `expect(() => db.insertPayment(...), throwsArgumentError)` passes vacuously on an async method →
   `await expectLater(...)`. Also `.first` on an empty drift stream hangs → `findItem` guard (H5).

**Environment honesty:** `tools/setup_check.sh` was executed here and exits 1 listing the 5 sandbox
gaps (no flutter/dart/adb/java, `pub.dev` blocked). That is the expected state of this workspace, not a
code failure — the script's job is to make that distinction unambiguous for the user.

**Incident, recorded because it affects how you should trust this repo:** the commits made in earlier
turns (`4763f7d` T1, `1021b18`/`d081172`/`0a4bbd3` T2 docs) are **not in this branch's history** —
`git reflog` shows only `clone → checkout → e5e2c6f`. File *contents* persisted (T1/T2 verified intact:
`money.dart` 271, `money_delta.dart` 90, `check_money.dart` 181), but the sandbox's git objects were
rolled back between turns. Consequence: **the working tree is the source of truth, not `git log`.**
From now on everything is committed as one tree per turn, and the docs remain the real task ledger.
If you `git push` at any point, verify `git log --oneline` shows what you expect before pushing to `main`.

**Next task:** T4 — JSON backup export/restore + SHA-256 checksum (`data/backup/`). Needs
`path_provider` + `crypto` + `share_plus`, all already in `pubspec.yaml`. If T3's codegen fails, fix
that first: T4 writes through the same `AppDatabase`.


---

## Task T4 — JSON backup export / restore (2026-09-03) — ⏳ code written, awaiting Pass/Fail

**Module:** `lib/data/backup/` (4 files, 860 lines) + 3 test files. No new packages.

| File | Lines |
|---|---|
| `snapshot_format.dart` | 72 — envelope keys, table order, filename, money-column rule |
| `backup_service.dart` | 155 — `buildSnapshot` (drift row `toJson()`), canonical encode, sha256 sidecar |
| `snapshot_validator.dart` | 278 — **imports no drift/flutter at all**, so a snapshot can be checked with a broken DB |
| `restore_service.dart` | 361 — `inspect` / `restoreFile` / `restoreLatest`, merge + replace modes |
| `test/data/backup/helpers.dart` | 218 — shared fixture with the hand-computed bill |
| `test/data/backup/export_and_validator_test.dart` | 218 |
| `test/data/backup/restore_test.dart` | 301 |

Design: **export rows, not models** (a model-based file would make the format hostage to refactors, and
would drop columns that only sync/audit needs). Snapshot = 13 tables in parent-first order; **`sync_outbox`
is deliberately excluded** — restoring a snapshot into a device that already synced must not resurrect ACKed
mutations. Two modes: `merge` (upsert, safe as an "undo my mistake" repair) and `replace` (wipe + apply,
requires `confirmReplace: true` **and** writes a pre-restore snapshot of what it destroyed). All inside one
transaction so a mid-restore failure leaves the till untouched.

Decisions: file `formatVersion` (envelope shape) and DB `schemaVersion` are separate numbers — conflating
them is how a restore tool starts refusing files it could read fine. Validation never *repairs*: `10.5` in a
paise column is refused with the row/column named, because quietly rounding puts a number in a till that
matches no printed bill. The checksum is a **sidecar** (`file.json.sha256`) not an in-file field, so a
hand-repair doesn't invalidate itself; a missing sidecar is allowed, a mismatching one is refused.

**`updated_at` stripping:** `_comparable()` removes it from every row before the rebuild comparison,
because DAO writes legitimately re-stamp it during restore. Documented in the helper.

**5 defects caught in review:** `suffixOverride:` vs `suffix:` (service wouldn't compile) · a `typedef
SnapshotReportish = String` used as an object type · an uninterpolated `$problems.length` in the exception
message · `late var db = seedDatabase()` (not legal Dart) · a fabricated
`getSingleWhereFilter` drift API replaced with a plain select · and the bill total I'd guessed as 33560
before hand-computing **33000** (with `rounding_paise = -38`, which is the first time a negative ROUNDING
line reaches a real assertion). Column-name mismatch `discount_kind_value` vs `discount_value` fixed across
schema/DAO/validator/test in one pass.

**Deferred deliberately:** the `share_plus` handoff. There is no seam to unit-test it against and
`path_provider`/platform channels don't exist under `flutter test`, so shipping it now would be untested
platform code; the export already returns the file path so the settings screen (R4) can share it.
`BackupService.backupDirectory()` is therefore the only untestable line in the task.

**Test-run ordering note:** `flutter test test/data/backup/` runs 20 tests; the replace-mode suite is the
real proof, the scale test just guards against an export that outlasts a counter rush (500 tickets).

**Next task (queue, all ⏳ until verified):** T5 — `sync_outbox` write-in-transaction + `SyncEngine` +
`NoopSyncGateway` + stuck-badge counter (`core/sync/`). That completes Phase T.

---

## 2026-09-05 (later) — screens finished, T5 shipped, outbox atomicity fix

Wrote the last v1 surfaces and the last v1 subsystem, then fixed a real atomicity
bug in what I had just written. Full file list is `git show --stat HEAD~2..HEAD`; the
decisions that outlive a diff:

- **Reports screen**: day stepper, `DailyTotals`' own getters (nothing re-derived in
  UI), hour strip drawn with Containers (no chart dependency), CSV → clipboard.
  Bestsellers window is `[from, from+1d)` because `ordersBetween` is half-open —
  a single-day report asking for `(Tue, Tue)` had no rows after midnight.
- **Roles**: `currentRoleProvider` + `UserRole.*` getters are the only permission
  path now; comparing `session.roleName` to display strings was removed from the KDS.
- **Cash up**: `StaffRepository.expectedCashFor` — the dialog must not re-add float +
  payments itself, or "expected" has two definitions.
- **T5**: engine (`sync/sync_engine.dart`) + `OutboxDao` (a new file — the class never
  existed; the model and the table did) + `sync_journal.dart`. Rules: delete only on an
  explicit ack; attempts incremented in SQL with the `stuck` threshold in the same
  statement; `in_flight` released at `start()` ONLY (per-cycle release would un-lease a
  slow upload → double-send); polling disabled unless `gateway.isRemote` (no server, no
  battery drain); drained rows DELETED, not flagged.
- **Schema v3**: `sync_outbox.last_error`, additive via the repeatable
  `createAll`+`ALTER` template already documented for v2.
- **pubspec**: `flutter_test` → `dependencies` (because `AppDatabase.memory()` lives in
  `lib/` so a widget test overrides one provider); `share_plus` and `intl` removed with
  their non-existent call sites; `path` added (imported by `connection.dart`).
- **Z2**: `tools/apply_android_config.sh`, self-tested against a fake `android/` tree
  (4 edits applied, re-run = 0 edits, failures exit 1).
- New tests: `test/features/kds_wait_test.dart`, `test/features/billing_rounding_test.dart`
  (`roundUpTo` and `waitedMinutes` are public *for* them), plus the two `test/sync/` files.

**Status unchanged and important: still never compiled.** 83 files / 17.4k lines / max
542 / `tools/dart_balance.py` BALANCED. `flutter analyze` is the first tool that can
catch an invented member name, and I found several by hand this session
(`Money * int`, `item.noteHint`, `RadioListTile(groupValue:)`, a nonexistent
`OutboxDao`, `DigitBuffer(initial:)` which I then added for real). Expect more of the
same class; each is a one-line fix in the screen, not in the architecture.
