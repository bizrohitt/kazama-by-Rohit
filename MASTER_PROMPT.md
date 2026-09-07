# MASTER_PROMPT — Kazama Fast Food POS (Flutter, Android + iOS)

> **Purpose of this file:** resume contract. Any future session starts here, then reads
> `SESSION_LOG.md` (last session) and `PROJECT_FLOW.md` (live task status). Never assume
> context from a previous chat (R7).

**Repo:** `bizrohitt/kazama-by-Rohit` · **Branch policy:** work on `arena/*` session branch, PR into `main`
**Documented:** 2026-09-03 · **Status:** Phase 1 plan delivered — ⛔ awaiting approval before Phase 2

---

## 1. Original instruction (verbatim intent, condensed)

Build a **Fast Food Point-of-Sale mobile app for Android & iOS** in ordered phases:

- **Phase 0** — clarifying questions, batched, before any code.
- **Phase 1** — Project Plan: flow diagram, module map, task backlog. No code.
- **Phase 2** — session-managed build loop, one small task per iteration:
  state task → write only that module → keep every file < 600 lines → functionality first
  (no styling/animations) → tell how to test → ask "Tested? Pass/Fail?" → PASS marks ✅ and
  proposes next task; FAIL debugs inside that module only. Every 3 done tasks → SESSION SUMMARY.
- **Phase 3** — maintain `MASTER_PROMPT.md`, `SKILLS.md`, `PROJECT_FLOW.md`, `SESSION_LOG.md`.

### Non-negotiable rules (apply at all times)

| # | Rule |
|---|---|
| R1 | **Modularization** — each feature is isolated with its own models, logic, UI. No cross-module spaghetti. |
| R2 | **600-line limit** per file. Split as it approaches the cap, immediately. |
| R3 | **Task splitting** — one small task per loop iteration. Never dump the whole app. |
| R4 | **Plan before code** — no code until the plan is approved. |
| R5 | **Functionality → styling** — plain placeholder UI while features are built; a dedicated polish phase only after every v1 feature passes. |
| R6 | **Open-source only** — every dependency 100% free, open-source, legally modifiable; licence cited per package. |
| R7 | **Session hygiene** — on "resume", read this file + `SESSION_LOG.md` first. |
| R8 | **No guessing** — ambiguous → stop and ask. |

---

## 2. Phase 0 — clarification answers (Batch 1 & 2 answered; Batch 3 skipped)

### ANSWERED BY USER

| Q | Question | Answer | Consequences locked in |
|---|---|---|---|
| **Q1** | Framework: Flutter or React Native? | **Flutter** (Dart), one codebase for Android + iOS | `pub.dev` unreachable in sandbox → I cannot run `pub get`, `analyze`, `test` or `build` here. All verification happens on the user's machine. |
| **Q2** | Single restaurant or multi-branch? | **Single restaurant** | No `branch_id` on any table. Multi-branch is explicitly out of v1 and would need a migration. |
| **Q3** | Offline-first or online-only? | **Offline-first with local sync queue** | SQLite is the source of truth; every write is queued for later sync; the till must keep selling with no internet. |
| **Q4** | v1 module priority | **User-specified custom flow (see below)** — two separate sections: order-taking vs billing | Not a single "cart" screen. Dine-in = eat first, pay later. Takeaway = pay upfront. |
| **Q5** | Payments | **Cash + manual split across modes on one bill** | `payments` is a line-item table (not a column). No gateway SDK in v1. |

#### Q4 user note (verbatim)

> "I want two sections, one for only order taking and other for billing the ordered items.
> This is because people here orders and eats food first then comes to the counter for paying
> but sometimes (most of the time) when people orders for a takeaway they pays upfront."

Design response (mandatory, not optional):
1. `orders.status` state machine: `DRAFT → OPEN → IN_KITCHEN → READY → SERVED → PARTIALLY_PAID → PAID → VOIDED`.
2. A **held-tickets / due list** is a first-class screen (unpaid open tickets, searchable).
3. **Order-taking never touches money**; **Billing never touches the menu**. They share the ticket aggregate.
4. Takeaway path: `OPEN` can go straight to Billing before firing to kitchen.
5. KDS at rank #2–3 with **one terminal** ⇒ KDS is a screen on the same phone, not a networked display.
   Data model must not assume same-process delivery, so it upgrades to a real kitchen device in v2.

### ASSUMED BY ME (Batch 3 skipped — veto any one of these during plan approval)

| Q | Assumption | Why, and what changes if you veto |
|---|---|---|
| **Q6** scanner | **No scanning in v1**, but `menu_items.barcode TEXT` + `categories.sort_order` etc. added to the schema on day 1. | Adding a column later = migration; adding the UI later = one task. Veto → `mobile_scanner` (BSD-3) task for "scan QR to reopen a ticket". |
| **Q7** backend | **Pure local SQLite + a `SyncRepository` seam shaped for Supabase**, plus daily JSON/CSV backup export. | With one till, a sync target has no partner yet; the outbox is built and drains to a `NoopSyncGateway`. Veto → Supabase free tier becomes Tasks in phase R, and auth moves earlier. |
| **Q8** brand | **`Kazama POS`** name from the repo, `AppColours` tokens in `lib/core/theme/`, **no logo/graphic assets** until polish (R5). | Veto with your hex values + logo file → they go into one theme file + `pubspec` assets block. |
| **Q9** licence | **Sell-safe**: your app code `MIT`; dependency policy = permissive only (MIT / Apache-2.0 / BSD-3), **no GPL/LGPL/AGPL**, no paid tier hooks. | Rationale: you may operate or sell this; copyleft deps would force you to open-source your app. Veto → relaxes nothing retroactively, so this is the safe default. |
| **Q10** printer | **No confirmed hardware** ⇒ `PrintTransport` interface with `FakePrintTransport` (renders monospace receipt in-app, shareable as file). Real ESC/POS Bluetooth task deferred until the hardware task. | You told me you have a Bluetooth 58 mm or 80 mm printer → swap task P4 earlier and I need paper width to write every template. |

---

## 3. Confirmed technical decisions

| Area | Decision | Reason |
|---|---|---|
| Framework | Flutter stable (latest), Dart 3 with null safety | User choice (Q1) |
| Scaffold location | **Repo root = the Flutter project** (`flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .`) | Keeps docs beside code; no nested repo |
| Architecture | Feature-first layered: `core / data / features / shared`, repository pattern, unidirectional flow | R1 |
| Local DB | `drift` (+ `sqlite3_flutter_libs`, `drift_flutter`), `build_runner` codegen | Type-safe, reactive streams (KDS auto-refresh), MIT, official Flutter Favorite |
| State mgmt | **`flutter_riverpod`** | Plain MIT. `bloc` v9 switched to a commercial licence for the paid DevTools Extension → rejected under R6 |
| Money | **Integer paise** everywhere (`Money` value object), never `double` | Eliminates float rounding bugs in split payments and change calc; pure-Dart testable |
| IDs | `uuid` v4 text primary keys + local `bill_number` counter | Offline-safe, sync-mergeable, no auto-increment collisions |
| Audit trail | Append-only `order_events` table | Who fired/served/voided/changed price — required for a real till |
| Navigation | `IndexedStack` 3-tab shell + `Navigator` named routes for dialogs | Avoids `go_router`'s generated-code friction; revisit at polish |
| Printing | `PrintTransport` abstraction; ESC/POS bytes built by our own `EscposBuilder` (MIT) rather than a half-maintained plugin | ESC/POS is a simple byte protocol; owning it removes a licence/maintenance risk |
| Tests | `flutter_test` per-task unit tests + a runnable pure-Dart check script per logic task | Device builds can't run here — see §4 |

### Dependency register (licence audit — R6)

| Package | Licence | Used for | Rejected alternatives (why) |
|---|---|---|---|
| `drift`, `drift_flutter` | MIT | SQLite ORM, migrations, reactive queries | `sqflite` (MIT, fine, but no type-safe streams → hand-rolled change bus) |
| `sqlite3_flutter_libs` | BSD-3 | Bundles native SQLite on Android/iOS | — |
| `build_runner`, `drift_dev` | MIT (dev-time only, not shipped) | codegen | — |
| `flutter_riverpod` | MIT | DI + state + caching | `flutter_bloc` v9 (MIT + commercial DevTools extension), `get` (GPL-3.0 → **banned by R6**) |
| `path_provider` | BSD-3 | Backup file location | — |
| `intl` | BSD-3 | Number/currency/date formatting | — |
| `uuid` | MIT | Offline-safe record ids | — |
| `convert` / `crypto` | BSD-3 | SHA-256 of staff PIN + backup checksums | `bcrypt`/`argon2` bindings — heavier, native deps |
| `share_plus` | BSD-3 | Export backup / share receipt | — |
| `flutter_blue_plus` | GPL-3.0 **only if needed** | ⚠️ If Bluetooth transport needs a plugin, we must instead talk raw SPP via a permissive package or platform channel. Flagged, not decided — Task P4 | — |

**No** analytics, crash reporters, ad SDKs, or payment SDKs in v1.

---

## 4. Environment reality (read before promising any verification)

Measured in this sandbox on 2026-09-03:

| Capability | State |
|---|---|
| `flutter`, `dart`, `java`, Android SDK, `adb`, emulators | ❌ absent, and **cannot be installed**: apt mirrors + `storage.googleapis.com` blocked |
| `pub.dev` | ❌ blocked → `flutter pub get` cannot run here |
| `github.com`, `api.github.com`, release downloads, `npm`, `pypi` | ✅ reachable → git/`gh` work fine |
| Consequence | **Every "Tested? Pass/Fail" happens on your machine.** My deliverable per task is code + an exact test procedure with an unambiguous expected result |

### Your one-time setup (do before Task 1)

```bash
# 1. Flutter (3.24+ stable) — https://docs.flutter.dev/get-started/install/linux
flutter --version
flutter doctor            # need: Android toolchain, Chrome optional, no ✗ on Android

# 2. Scaffold the app at the REPO ROOT (run inside the cloned repo)
cd kazama-by-Rohit
flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .
flutter pub get

# 3. Device: realme phone with USB debugging, or an AVD
adb devices                       # must list your phone
flutter devices
```

If `flutter create .` refuses (untracked-file conflict), scaffold in a temp dir and move
`lib/ pubspec.yaml analysis_options.yaml android/ ios/ test/` into the repo root.

---

## 5. How to resume this project

Say **`resume`**. The next session must then:
1. read this file in full;
2. read `SESSION_LOG.md` → last entry = where we stopped;
3. read `PROJECT_FLOW.md` → next ⏳/❌ task in the backlog;
4. `git log --oneline -5` + `git status` to reconcile docs against real files (docs can drift);
5. restate the current task and its module, then run the Phase 2 loop. No re-asking questions answered in §2.

**Open questions still unanswered (ask once, then proceed):** receipt paper width (58 vs 80 mm),
whether you have real printer hardware, GST/tax rates per item class, and whether staff PIN login
is needed on day 1 or after payments.
→ **Status 2026-09-05:** never answered across four asks; the recorded defaults are now IN THE
CODE and treated as chosen (32 columns = 58 mm default in `app_meta`, overridable in the Shop &
printer screen; `FakePrintTransport` until P4; GST inclusive per item at the item's own
`taxPercent`; staff PIN from the first launch, because `KazamaGate` cannot render a till with no
user). Overriding any of these is a small, local change — see PROJECT_FLOW §4b for which file.
