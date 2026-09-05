# PROJECT_FLOW — Kazama POS

Live plan + task status. Legend: ✅ passed on device · ⏳ pending / in progress · ❌ failed or blocked · 🔒 depends on an unfinished task

---

## 1. PROJECT FLOW (screens → navigation → data)

### 1.1 Screen / navigation map

```
                            ┌──────────────────────────┐
                            │  SPLASH / DB READY        │  open drift, run migrations,
                            │  (auto, <1s)              │  verify local bill counter
                            └────────────┬─────────────┘
                                         │
                       ⏸ AUTH GATE (phase S, added when staff module lands)
                                         │
                            ┌────────────▼─────────────┐
                            │  HOME SHELL (IndexedStack)│
                            │  [ Take ] [ Kitchen ][ Bill]│
                            └───┬─────────────┬───────────┬───────────┐
            ┌───────────────────▼──┐   ┌──────▼────────┐  └─────────┬─────────────────┐
            │ TAB 1: ORDER TAKING  │   │ TAB 2: KDS    │            │ TAB 3: BILLING    │
            │ category chips       │   │ open tickets  │            │ due-list (unpaid) │
            │ item grid/tiles      │   │ ┌─ ticket ──┐ │            │ take 1..n tickets │
            │ [+ item → draft]     │   │ │ Burger x2 │ │            │ + new takeaway    │
            │  • ticket header     │   │ │ [Fire]    │ │            └────┬────────────┘
            │  • DINE_IN / TAKEAWAY│   │ │ [Ready]   │ │                 │
            │  • table no / name   │   │ └───────────┘ │                 ▼
            │  • per-line notes    │   │ auto-refresh  │      ┌──────────────────────┐
            │  • qty / remove line │   │ from drift    │      │ BILL DETAIL          │
            └───────┬──────────────┘   │ stream (no    │      │ lines + running total│
                    │                  │ polling)      │      │ DISCOUNT (abs/%)     │
        ┌───────────┴──────────┐       └──────┬────────┘      │ TAX summary          │
        ▼                      ▼              │               └──────┬───────────────┘
 ┌──────────────┐     ┌──────────────┐        │                      ▼
 │ SAVE DRAFT   │     │ FIRE TO      │        │           ┌───────────────────────┐
 │ (stay open,  │     │ KITCHEN      │◄───────┘           │ PAYMENT SHEET (split) │
 │  untagged)   │     │ status:OPEN→ │  (kitchen marks    │  rows: CASH/UPI/CARD/  │
 └──────────────┘     │   IN_KITCHEN │   ready/served)    │        CREDIT          │
        │             └──────────────┘                    │  cash → quick notes    │
        │  long-press item                                │  → change auto-calc    │
        ▼                                                 │  settle remaining?     │
 ┌──────────────┐     ┌──────────────┐                    └──────┬────────────────┘
 │ MENU ITEM    │     │ MODIFIER     │                           ▼
 │ EDITOR       │────►│ GROUP EDITOR │              ┌──────────────────────────┐
 │ (phase M)    │     │ (phase M)    │              │ CLOSE BILL               │
 └──────────────┘     └──────────────┘              │  → receipt RENDER →      │
                                                     │    PrintTransport        │
        ┌──────────────────────┐                     │  → status PAID / PARTIAL │
        │ REPORTS (tab 4)      │                     └──────────┬───────────────┘
        │ day / week / custom  │                                ▼
        │ sales by mode, item  │                     ┌──────────────────────────┐
        │ bestsellers, due     │                     │ RECEIPT PREVIEW (fake    │
        └─────────┬────────────┘                     │ transport) → share file  │
                  ▼                                  └──────────────────────────┘
        ┌──────────────────────────┐
        │ BACKUP / RESTORE         │  writes JSON snapshot to app dir, share via
        │ (data-integrity screens) │  share_plus; restore = replace DB
        └──────────────────────────┘
```

### 1.2 Ticket lifecycle (single source of truth for both sections)

```
   DRAFT ──open ticket──► OPEN ──fire──► IN_KITCHEN ──ready──► READY ──hand over──► SERVED
     │  ▲                   │  │                                  │                    │
     │  └──add course───────┘  │  (takeaway: skip to Billing      │                    │
     │  (any non-VOID state)   │   while still OPEN/IN_KITCHEN)  │                    │
     │                     void│                                  │                    ▼
     └─────────────────────────┴──────────────────────────► VOIDED ◄──────┐  ┌────────────────┐
                                                                            │  │ BILLING        │
                                       PARTIALLY_PAID ◄──split payment──────┤  │ pays any state │
                                             │  all settled                │  └────────────────┘
                                             ▼                              │
                                            PAID ──── reprint marked "COPY"
```
Allowed transitions are enforced in **one** place: `OrderState.canTransitionTo`. UI reads
allowed actions from the same function, so a bad transition is impossible rather than merely hidden.

### 1.3 Data flow

```
WRITE PATH
  UI event ─► Notifier (feature) ─► Repository (feature, interface)
            ─► Drift DAO ─► SQLite transaction ──┬─► business table write
                                                 └─► sync_outbox INSERT (kind, payload,
                                                    idempotencyKey, attempts)   ← same txn
  (no await on network, ever — the write is complete when the local txn commits)

READ PATH
  Drift SELECT ─► watch() Stream ─► Repository stream ─► Notifier state ─► rebuild
  (KDS, due-list and reports refresh with no polling and no event bus)

SYNC PATH (built, dormant — no cloud partner until v2)
  trigger: connectivity restored / app resume / manual "Sync now"
  SyncEngine ─► drain outbox in batches of 50, ordered by queuedAt
             ─► SyncGateway.push(mutations) ─► [NoopSyncGateway] returns "accepted"
             ─► ACKed rows deleted; failures increment attempts, >10 ⇒ status:'stuck' + UI badge
  idempotencyKey (uuid) makes a re-send harmless; bill_number is allocated LOCALLY and never
  recomputed, so an outage can never create duplicate bill numbers.
```

### 1.4 Schema (Task T2+ ; money = integer paise; soft delete only where audit needs it)

| Table | Notable columns |
|---|---|
| `users` | id, name, pinHash, role(`CASHIER/KITCHEN/MANAGER`), active |
| `shifts` | id, userId, openedAt, closedAt, openingFloat, expectedCash, countedCash |
| `menu_categories` | id, name, sortOrder, active |
| `menu_items` | id, name, pricePaise, taxPercent, kitchenLabel, prepSeconds, printable, barcode, active |
| `modifier_groups` | id, name, minSelect, maxSelect, required |
| `modifier_options` | id, groupId, name, priceDeltaPaise, sortOrder |
| `menu_item_modifier_groups` | itemId, groupId |
| `orders` | id, billNumber, type(`DINE_IN/TAKEAWAY/DELIVERY`), tableOrName, status, openedBy, openedAt, firedAt, readyAt, servedAt, closedAt, discountPaise, discountIsPercent, subtotalPaise, taxPaise, totalPaise, paidPaise, duePaise, voidReason, note, updatedAt |
| `order_lines` | id, orderId, itemId, nameSnapshot, qty, unitPricePaise, modifiersSnapshotJson, lineTotalPaise, status(`PENDING/FIRED/READY/SERVED/CANCELLED`), cancelledQty |
| `order_events` | id, orderId, type, payloadJson, actorId, at — **append-only** |
| `payments` | id, orderId, mode(`CASH/UPI/CARD/CREDIT`), amountPaise, tenderedPaise, changePaise, reference, recordedBy, at |
| `credit_entries` | id, party, amountPaise, kind(`DUE/SETTLED`), phone, note, linkedOrderId, at |
| `receipts` | id, orderId, kind(`SALE/VOID/DUE/COPY`), bytesBase64 or path, transported, printerName, at |
| `sync_outbox` | id, entity, entityId, op(`INSERT/UPDATE/DELETE`), payloadJson, idempotencyKey, queuedAt, attempts, status |
| `app_meta` | key, value — `bill.seq`, `db.schemaVersion`, `backup.lastAt`, `printer.paperWidth`, `tax.inclusive` |

---

## 2. MODULE MAP (R1 — one feature = one folder = one repository interface)

```
lib/
  main.dart                          # 3 lines: ProviderScope + KazamaPosApp  (never grows)
  app.dart                           # MaterialApp, theme wiring, home shell only

  core/                              # no feature may be imported from here
    config/       env.dart, flags.dart
    constants/    app_strings.dart, db_constants.dart, route_names.dart
    money/        money.dart                  # pure Dart: int paise + rounding  (no Flutter import)
    errors/       app_exception.dart          # sealed failure types
    utils/        datetime.dart, json.dart, id.dart, result.dart
    theme/        app_colours.dart, app_typography.dart, app_theme.dart
    db/           app_database.dart, connection.dart, migrations.dart
    sync/         sync_engine.dart, sync_gateway.dart, mutation.dart   # infra, feature-agnostic

  data/
    models/         enums.dart, menu.dart, order.dart, payment.dart, staff.dart, report.dart
    tables/         (drift table definitions, one file per aggregate, R2-friendly)
    daos/           menu_dao.dart, order_dao.dart, payment_dao.dart, staff_dao.dart, report_dao.dart
    repositories/   contract/  (abstract interfaces — features depend on THESE ONLY)
                    impl/      (drift-backed implementations)
    backup/         backup_service.dart, restore_service.dart
    seed/           fast_food_seed.dart

  features/                          # each:  domain/ (logic) · application/ (notifier) · ui/
    order_flow/   # THE heart: ticket aggregate + both sections
      domain/     ticket_state.dart, order_aggregate.dart, due_list.dart
      taking/     order_taking_screen.dart, order_repository.dart, order_taking_notifier.dart
      billing/    billing_screen.dart, bill_detail.dart, due_list_screen.dart
      shared_widgets/  ticket_header.dart, line_tile.dart
    kds/          domain/kds_query.dart, ui/kds_screen.dart, ui/kds_ticket_card.dart
    menu/         domain/menu_validator.dart, ui/(menu_list, item_editor, modifier_editor)
    payments/     domain/(split_calculator, change_calculator, tax_calculator)
                  payment_sheet.dart, credit_repository.dart
    printing/     domain/(receipt_model, receipt_renderer, escpos_builder)
                  transport/(print_transport.dart, fake_transport.dart, escpos_bt_transport.dart)
                  ui/receipt_preview_screen.dart
    reports/      domain/(daily_totals, bestsellers, due_report)  ui/(reports_screen, csv_export)
    inventory/    domain/(stock_math, low_stock)  ui/(stock_screen, stock_adjust)
    staff_auth/   domain/(pin_hasher, session_rules)  ui/(pin_pad, shift_screen)

  shared/
    widgets/        async_value_view.dart, money_text.dart, empty_state.dart,
                    confirm_dialog.dart, numeric_keypad.dart   # dumb, callback-driven only
    patterns/       list_tile_selectors.dart

test/                                  # mirrors lib/, one test file per logic file
tools/
  check_<topic>.dart                   # runnable pure-Dart verification script per logic task
```

**Dependency direction (enforced by review, not tooling):**
`features/* → data/repositories/contract → (impl) → data/daos → core/db`.
`features/A` may **never** import `features/B`; they share state only through `data/` and the DB.
`shared/` imports nothing from `features/`. `core/` imports nothing from anyone.

---

## 3. TASK BACKLOG (one module per task, independently testable)

### Phase T — Trustworthy foundation (must precede all features)

| # | Task | Module touched | Definition of done / test |
|---|---|---|---|
| **T1** ✅ | `Money` value object: int paise, add/sub/percent, 0.5-rupee rounding, JSON | `core/money/` | **PASSED 2026-09-03** (user-verified). Files: `lib/core/money/money.dart` (271), `tools/check_money.dart` (181), `test/core/money_test.dart` (144). Gate: `dart run tools/check_money.dart` → `12/12 PASS` + 3 invariant groups, exit 0 |
| **T2** ⏳ | Enums + immutable models with `copyWith`, JSON codecs, `Money` fields; **+ MoneyDelta (signed) + deep_eq** | `data/models/` | **code written 2026-09-03.** 10 files (deep_eq, enums, menu, order_line, order, payment, staff, report, mutation + `core/money/money_delta`). Gates: `dart run tools/check_models.dart` → `14/14` round-trips + 0 failures; `flutter test test/data/models_test.dart` |
| **T3** ⏳ | Drift `AppDatabase` + 14 tables + `schemaVersion` + migration scaffold + 2 DAOs | `core/db/`, `data/tables/`, `data/daos/` | **code written 2026-09-03.** Gates: `bash tools/setup_check.sh` clean → `flutter pub get` → `dart run build_runner build --delete-conflicting-outputs` → `flutter test test/core/app_database_test.dart` (17 tests; doubles as T2's real codec gate) |
| **T4** ⏳ | JSON backup export/restore + validation + checksum sidecar | `data/backup/` | **code written 2026-09-03.** 4 lib files + 3 test files (20 tests). Gate: `flutter test test/data/backup/`. `share_plus` handoff deliberately deferred (no testable seam in a unit test — see SESSION_LOG) |
| **T5** | `sync_outbox` write-inside-transaction + `SyncEngine` + `NoopSyncGateway` + stuck counter | `core/sync/` | unit test: 3 mutations → outbox drained → empty; forced failure → attempts++, no data loss |

### Phase M — Menu management

| # | Task | Module | Test |
|---|---|---|---|
| M1 | `MenuDao` + `MenuRepository` (CRUD, reorder, soft-delete) | `data/{daos,repositories}` | test: create/update/soft-delete; deleted item hidden, order history intact |
| M2 | `fast_food_seed.dart` (≈25 items, 6 categories, modifiers, realistic paise prices) | `data/seed/` | one-shot seed command; count assertions; second run is a no-op |
| M3 | Menu list screen (categories + items, read-only) | `features/menu/ui` | device: all seeded items visible, scroll smooth |
| M4 | Item editor (name, price, tax %, kitchen label, prep secs, active) + validation | `features/menu` | device: edit price → visible in M3; invalid input blocked with reason |
| M5 | Modifier groups editor (size/add-ons, price delta, min/max, required) | `features/menu` | device: create "Size S/M/L +0/+1500/+2500 paise"; attach to item |
| M6 | Availability: sold-out toggle + auto "unavailable if stock ≤ 0" hook (inventory later) | `features/menu` | device: toggle → tile greys out, cannot be added to a ticket |

### Phase O — Order taking (section 1) — money never touched here

| # | Task | Module | Test |
|---|---|---|---|
| O1 | Ticket state machine + transition tests (`DRAFT→…→PAID/VOIDED`) | `features/order_flow/domain` | pure-Dart script: every legal transition true, every illegal one throws |
| O2 | `OrderDao`+`OrderRepository`: create ticket, add/remove/qty lines, modifier snapshot, price snapshot | `data/daos`,`features/order_flow` | device: build a 4-line ticket, quit app, reopen → identical |
| O3 | Order-taking screen: category chips, item tap→line, qty +/−, line notes, DINE_IN/TAKEAWAY + table no | `features/order_flow/taking` | device: open ticket A (dine-in T3), B (takeaway); both persist |
| O4 | Held-tickets list: open/unpaid tickets, search by table/name/bill, resume | `features/order_flow` | device: 3 open tickets, tap one, add a course, list count unchanged |
| O5 | Fire to kitchen (`OPEN→IN_KITCHEN`), append `order_events`, second-course firing with `line.status` | `features/order_flow` | device: fire course 1, add course 2, fire again → only course-2 lines move to kitchen |
| O6 | Void/cancel: whole-void with reason, line-level cancel with qty | `features/order_flow` | device: cancel 1 of 3 biryanis → totals and KDS update; void sets status + reason |

### Phase K — Kitchen Display

| # | Task | Module | Test |
|---|---|---|---|
| K1 | KDS ticket feed from drift `watch()` stream, grouped by status, ageing timer | `features/kds` | device: fire on the take screen → ticket appears with no manual refresh |
| K2 | Ready / served actions + per-line ready + timestamps | `features/kds` | device: mark 2/3 lines ready, ticket stays until all ready |
| K3 | Kitchen label + modifier visibility, prep-time priority sort | `features/kds` | device: item with "no onion" shows the note; slow item sorts up |

### Phase P — Receipt printing (hardware-agnostic first)

| # | Task | Module | Test |
|---|---|---|---|
| P1 | `ReceiptModel` + `ReceiptRenderer` (fixed-width 32/48 cols, header, lines, split-payment rows, totals, thanks) | `features/printing/domain` | pure-Dart: 58 mm and 80 mm fixtures byte-for-byte as expected; long names wrap |
| P2 | `PrintTransport` interface + `FakePrintTransport` (in-app monospace preview + share as file) | `features/printing` | device: close a bill → preview shows exact receipt text, share works |
| P3 | `EscposBuilder` (init, bold, align, 2D barcode, cut; our own encoder) | `features/printing/domain` | unit test: known 3-line receipt ⇒ expected hex sequence |
| P4 | Bluetooth ESC/POS transport, Android 12+ `BLUETOOTH_CONNECT` runtime request, printer picker | `features/printing/transport` | **needs hardware.** device: real print. If vetoed → stays ⏳ behind fake |

### Phase Y — Payments & billing (section 2)

| # | Task | Module | Test |
|---|---|---|---|
| Y1 | Split-ledger repo: multi-payment rows, `paidPaise`/`duePaise` invariants (due ≥ 0, never overpaid) | `features/payments`,`data/daos` | test: ₹1234 bill paid 500+400 → due 334; overpay blocked |
| Y2 | Cash tender UI: keypad, quick notes (₹2000/500/100/50/20/10), auto change, paise rounding | `features/payments/ui` | device: tender ₹600 on ₹575 → change ₹25 shown and stored |
| Y3 | Manual UPI/CARD rows: reference field, no verification, per-row recordedBy/at | `features/payments/ui` | device: "GPay ref 12345" appears in receipt and reports |
| Y4 | Credit / pay-later: create `credit_entries`, due list, settle-a-credit flow | `features/payments` | device: close dine-in with 0 paid → ticket due ₹X, credit list shows party and total |
| Y5 | `TaxCalculator`: per-item %, inclusive/exclusive flag, per-line then bill-level rounding | `features/payments/domain` | test: fixtures for 5%/12%/18%/28% GST incl. half-rupee rounding |
| Y6 | `PAID/PARTIALLY_PAID` transition + bill close, bill-number allocation at close | `features/order_flow`+`payments` | device: settle → status PAID, bill number monotonic, no re-use after restart |

### Phase R — Reports & data export

| # | Task | Module | Test |
|---|---|---|---|
| R1 | Daily totals: bills, covers, gross, discount, tax, net, due | `data/daos/report_dao` | test: seeded fixture day → exact totals |
| R2 | Sales by payment mode + hour-of-day buckets | `features/reports` | device: matches the tickets you actually closed |
| R3 | Item bestsellers + category mix; date-range picker | `features/reports` | device: top item = what you sold most in testing |
| R4 | Due/credit report + CSV export via `share_plus` | `features/reports` | device: CSV opens in a spreadsheet app with correct money columns |

### Phase I — Inventory (kept in v1 because you ranked it; sellable-stock only)

| # | Task | Module | Test |
|---|---|---|---|
| I1 | `stock_items` + `stock_movements` tables/DAH, unit types, migration | `core/db`,`data` | test: open stock, sale decrements, void restores |
| I2 | Deduct-on-fire rule (not on draft) + manual receive/adjust/spoilage | `features/inventory/domain` | test: fire 2×(3 patties) → 6 deducted once, re-fire no double deduct |
| I3 | Stock screen with low-stock flag and adjust UI | `features/inventory/ui` | device: adjust to 0 → item auto sold-out (hooks M6) |

### Phase S — Staff accounts (auth gate — deliberately last per R5)

| # | Task | Module | Test |
|---|---|---|---|
| S1 | `UserDao` + manager bootstrap (first-run PIN) + SHA-256 pinHash + lockout after 5 tries | `features/staff_auth` | test: wrong PIN ×5 ⇒ 60s lock; correct PIN clears |
| S2 | PIN pad login + session (auto-lock on resume after N min) | `features/staff_auth/ui` | device: background 5 min → app re-locks |
| S3 | Roles gate KDS/billing/menu-edit; `openedBy`/`recordedBy` attribution | `features/staff_auth` | device: cashier cannot open menu editor; KDS-only role cannot bill |
| S4 | Shift open/close with cash float + expected-vs-counted variance | `features/staff_auth` | device: close shift → variance ₹X matches your manual count |

### Phase Z — Polish (only after every feature above is ✅, R5)

| # | Task |
|---|---|
| Z1 | Brand: colours/logo assets, app icon, launcher name, adaptive icon |
| Z2 | Theme: typography scale, spacing tokens, dark mode for night counters |
| Z3 | Layout: responsive order grid for tablets, large-thumb touch targets |
| Z4 | Motion: transitions, haptics, skeleton loaders (explicit go-ahead) |
| Z5 | iOS parity pass: entitlements, Bluetooth permission strings, iPad layout, `flutter build ipa` notes |
| Z6 | App store prep: screenshots, privacy policy (staff PIN data), versioning, `pubspec` description |

**Build order = T → M → O → K → P → Y → R → I → S → (v1 done) → Z.**
Printing (P) sits before payments (Y) as you ranked; P1–P3 need no hardware so they never block.

---

## 4. STATUS SUMMARY

| Phase | Tasks | ✅ | ⏳ | ❌ |
|---|---|---|---|---|
| T Foundation | 5 | 1 (T1 ✅) | 4 (T2+T3+T4 code done, **unverified**) | 0 |
| M Menu | 6 | 0 | 6 | 0 |
| O Order taking | 6 | 0 | 6 | 0 |
| K KDS | 3 | 0 | 3 | 0 |
| P Printing | 4 | 0 | 4 | 0 |
| Y Payments | 6 | 0 | 6 | 0 |
| R Reports | 4 | 0 | 4 | 0 |
| I Inventory | 3 | 0 | 3 | 0 |
| S Staff | 4 | 0 | 4 | 0 |
| Z Polish | 6 | 0 | 6 | 0 |
| **Total** | **47** | **0** | **47** | **0** |

▶ **Phase 2 running.** T1 ✅ (passed 2026-09-03, `12/12 PASS` + `flutter test` green).
A task only becomes ✅ when **you** confirm the expected output.
**T2 + T3 + T4 code written, all ⏳ awaiting your Pass/Fail** ("continue" is not a verdict, so none
are marked ✅ — one `flutter test test/` run clears all three). `order.dart` was split at 518 lines → `order_line.dart` (R2 trigger fired as designed).
`pubspec.yaml` + `lib/core/db/` + `lib/data/tables/` + `lib/data/daos/` now exist; still no UI, no `lib/main.dart` wiring.

## 4b. v1 build progress (agent-authored, awaiting external test)

Mode set by the user on 2026-09-04: *"use a different coding agent to test this
codes, so just continue and complete this projects codes."* So no task below is
marked ✅ — every one is ⏳ pending an external run. Static gates I can run here
(`python3 tools/dart_balance.py`, import-path audit, `==`-chain validator) are
green, but they are not a compile.

| Area | Files | Status |
|---|---|---|
| T1 money | `core/money/` | ✅ (device/user-verified earlier) |
| T2 models | `data/models/` | ⏳ |
| T3 schema/DAOs | `core/db/`, `data/daos/`, `data/tables/` | ⏳ schema now **v3** (`sync_outbox.last_error`, T5) |
| T4 backup | `data/backup/` + 3 test files | ⏳ |
| Repositories | `data/repositories/{contract,impl}/` (6 impl, 5 contract) | ⏳ |
| Seed | `data/seed/fast_food_seed.dart` | ⏳ |
| I inventory | `data/models/stock.dart`, `stock_tables.dart`, `StockDao` | ⏳ |
| P printing | `features/printing/` (model, 2 renderers, queue, fake transport) | ⏳ |
| S staff/shift | `pin_hasher.dart`, `StaffDao`, `StaffRepositoryImpl` | ⏳ |
| Y/R data | `PaymentRepositoryImpl` (ledger, credit, reports, CSV) | ⏳ |
| U shell | `app/theme.dart`, `app/main.dart`, `app/kazama_app.dart`, `app/shell.dart`, `app/widgets/number_pad.dart` | ⏳ written |
| Feature screens | sign-in, order+modifier sheet, billing, KDS, stock, menu editor, settings hub, shop/printer, staff/shift, backup | ⏳ written (11 files, all <600 lines) |
| T5 sync outbox | `sync/sync_engine.dart`, `sync/sync_gateway.dart`, `data/daos/outbox_dao.dart`, `data/repositories/impl/sync_journal.dart` | ⏳ written + 2 test files |
| R reports screen | `features/reports/ui/reports_screen.dart` (day totals, shifts, top items, hour strip, CSV→clipboard) | ⏳ written |
| Z2 android config | `tools/apply_android_config.sh` (self-tested against a fake `android/` tree; idempotent) | ⏳ written |
| pubspec | `flutter_test` moved into `dependencies` (so `AppDatabase.memory()` compiles in release); `share_plus` + `intl` removed with their (non-existent) call sites; `path` added | ⏳ written |

Two consistency fixes worth re-checking by eye, because they were made while
auditing invented APIs:
* `currentRoleProvider` (`core/providers.dart`) is now the only way a screen tests a
  role — `kds_screen.dart` used to compare `roleName` against the display strings, and
  the provider accepts both `UserRole.name` and `.label` because `SignInScreen` writes
  the label.
* `roundUpTo` (`features/billing/ui/billing_screen.dart`) and `waitedMinutes`
  (`kds_screen.dart`) are public *for their tests* (`test/features/`), not for
  decoration; `Shift.openingFloat + collected` was replaced by
  `StaffRepository.expectedCashFor` so the cash-up dialog and the shift list cannot
  disagree about what "expected" means.

### What the external tester should run, in this order

```bash
dart run build_runner build --delete-conflicting-outputs   # 1st: nothing here has been parsed by dart yet
flutter analyze                                              # 2nd: expect invented-API errors; they are the bugs to fix
flutter test test/core test/data test/sync test/features    # 3rd: 8 test files
flutter test                                                 # 4th: everything
```

Expected shape of the first failures, so they are not mistaken for architecture problems:
`flutter analyze` is the only tool that can catch a member name this repo has
never type-checked. The most likely class of error is a UI file calling something
the repository does not expose (or an import path across `features/*`). Each such
case is a one-line fix in the *screen*, not a redesign — say which and it gets
fixed on the next loop.

Known deferred items (intentional, not bugs): real Bluetooth transport (P4),
Supabase gateway body behind `NoopSyncGateway`, `share_plus` for sending a
snapshot off-device, `tools/apply_android_config.sh`, and every styling pass (R5
keeps polish after the functionality gate).
