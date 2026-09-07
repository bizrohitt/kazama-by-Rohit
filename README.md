# Kazama POS

Fast-food **point-of-sale** for Android & iOS — Flutter, single outlet, **offline-first**
(SQLite is the source of truth; a local sync outbox drains to a future backend).
One phone runs both sections of the counter flow: **order taking** (dine-in guests pay after
eating) and **billing** (takeaway pays upfront).

## Start here

| File | Read it for |
|---|---|
| [`MASTER_PROMPT.md`](MASTER_PROMPT.md) | Resume contract: the plan-of-record, every clarified answer, and the assumptions awaiting veto |
| [`PROJECT_FLOW.md`](PROJECT_FLOW.md) | Screen/flow diagram, ticket state machine, schema, module map, **47-task backlog with live status** |
| [`SKILLS.md`](SKILLS.md) | Reusable techniques: integer-paise money, outbox pattern, print transports, licence vetting |
| [`SESSION_LOG.md`](SESSION_LOG.md) | Session-by-session summaries — latest entry = where we stopped |

## Build rules this project follows

Modularised features (one folder per feature, no cross-feature imports) · every file under 600 lines ·
one small task per loop with a device-verified Pass/Fail gate · functionality before styling ·
**open-source-only dependencies with licences recorded** · no guessing — ambiguity stops the build.

## Current state

⏳ **v1 code is written; nothing has been compiled yet.** ~17.3k lines of Dart across
81 files — the whole vertical slice (order → kitchen → billing → print → reports →
staff → inventory → backup → sync outbox) plus 10 test files. The sandbox that wrote
it has no Dart/Flutter SDK and no network to `pub.dev` (see `SESSION_LOG.md`), so
`tools/dart_balance.py` (brace/quote balance, 600-line limit) is the only static gate
available. **`flutter analyze` is the first real gate** and `PROJECT_FLOW.md` §4b lists
what each area still needs from it.

## Setup (run on your machine — this repo has no CI toolchain)

```bash
flutter --version && flutter doctor          # need a clean Android toolchain
flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .
tools/apply_android_config.sh                # minSdk 23, orientation lock, largeHeap (Z2)
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift codegen (T3)
flutter analyze
flutter test                                 # 10 files, incl. the DB-backed ones
adb devices                                  # your realme phone, or an AVD
flutter run
```

The `flutter create` step is not optional and is why the repo has no `android/` or
`ios/` directory: those folders are generated, and `tools/apply_android_config.sh`
patches them afterwards. Re-running `flutter create` is safe — the script is idempotent
and reports what it changed.

## Licence

Code in this repository: **MIT** (see [`LICENSE`](LICENSE)). Chosen as a "sell-safe" default —
app code permissive, and every runtime dependency restricted to MIT / Apache-2.0 / BSD.
