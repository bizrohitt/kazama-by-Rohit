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

⏳ **Phase 1 — plan delivered, awaiting approval. No app code exists yet.**
`lib/` and `pubspec.yaml` appear only after approval (Phase 2, Task T1).

## Setup (run on your machine — this repo has no CI toolchain)

```bash
flutter --version && flutter doctor          # need a clean Android toolchain
flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .
flutter pub get
adb devices                                  # your realme phone, or an AVD
flutter run
```

## Licence

Code in this repository: **MIT** (see [`LICENSE`](LICENSE)). Chosen as a "sell-safe" default —
app code permissive, and every runtime dependency restricted to MIT / Apache-2.0 / BSD.
