# SKILLS — reusable technique log

Grows with the build. Each entry is written so it can be copied into another project without
reading this conversation. Tag: **[architecture] [dart] [flutter] [data] [device] [process] [licence]**

---

## A. Process patterns (project-level, reused every session)

### A1. Sandbox capability probe before promising verification **[process]**
Never promise a test I cannot run. Probe first, then design the loop around the truth.
```bash
for c in flutter dart node npm java adb; do command -v $c >/dev/null && echo "$c: yes" || echo "$c: NO"; done
for u in https://pub.dev https://registry.npmjs.org https://storage.googleapis.com https://archive.ubuntu.com; do
  printf "%-40s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 $u)"; done   # 000 = blocked
```
Record the result in `MASTER_PROMPT.md` §4 with a date — blocked hosts change per environment.

### A2. Runnable check script instead of an untestable claim **[dart] [process]**
When the toolchain can't run, give the user something with a **single obvious correct output**.
- Keep the logic file **pure Dart**: no `package:flutter`, no drift import, no context.
- Mirror it in `tools/check_<topic>.dart` that prints `PASS`/`FAIL` per case and exits non-zero on failure.
- Command handed to user: `dart run tools/check_money.dart` → expected: `12/12 PASS`.
Benefit: UI bugs and logic bugs get separated before the UI exists at all.

### A3. 600-line discipline as a split *trigger*, not a cleanup chore **[process]**
Watch the count while writing; at ~500 lines split the next addition into a new file. Typical cuts:
`xxx_screen.dart` (layout) / `xxx_widgets.dart` (private subtrees) / `xxx_notifier.dart` (state) /
`xxx_domain.dart` (pure logic). Check: `wc -l lib/**/*.dart | sort -n | tail -5`.

### A4. One-module-per-task testability contract **[process]**
A task is only acceptable if it names exactly one module folder and its test touches no other module.
If a proposed task needs two modules, it is two tasks. This is what keeps "FAIL → debug within the
same module only" possible.

---

## B. Money, tax and rounding

### B1. Integer minor units (paise) — never `double` **[dart]**
```dart
final class Money implements Comparable<Money> {
  final int paise;                                  // ₹12.34 -> 1234
  const Money(this.paise) : assert(paise >= 0, 'negative money is a bug');
  factory Money.rupees(num r) => Money((r * 100).round());
  static const zero = Money(0);
  Money operator +(Money o) => Money(paise + o.paise);
  Money operator -(Money o) => Money(paise - o.paise);
  bool get isZero => paise == 0;
  /// Half-up to the rupee, which is what a cash drawer can physically do.
  Money roundedToRupee() => Money(((paise + 50) ~/ 100) * 100);
  int get rupeePart => paise ~/ 100;
  int get paisePart => paise % 100;
  @override int compareTo(Money o) => paise.compareTo(o.paise);
  @override bool operator ==(Object o) => o is Money && o.paise == paise;
  @override int get hashCode => paise.hashCode;
}
```
Rules: store `int paise` in every column; parse user input with `Money.rupees()` at the UI edge only;
`toStringAsFixed(2)` is a **display** concern (`shared/MoneyText`), never an arithmetic one.
`double` appears nowhere in the ledger.

### B2. Bill-level rounding, per-line tax first **[dart]**
Order of operations that matches Indian counter practice and keeps totals auditable:
1. `lineTotal = unitPrice × qty + Σ(modifierDelta × qty)` (all int paise, no rounding yet)
2. `lineTax  = roundHalfUp(lineTotal × taxPercent / (100 + taxPercent))` if tax-inclusive,
   else `roundHalfUp(lineTotal × taxPercent / 100)` — **round per line, not per bill**
3. `subtotal = Σ (lineTotal - lineTax)` [inclusive] or `Σ lineTotal` [exclusive]
4. `discount` applied on subtotal, then `tax` recomputed on the discounted subtotal
   proportionally per line (avoids the "discount one rupee, tax unchanged" mismatch)
5. `billRounding = roundHalfUp(ΣlineTax + subtotal) - (ΣlineTax + subtotal)` → shown as its own
   `ROUNDING` line so the receipt foots exactly to `totalPaise`.
Every step is int-only; the `ROUNDING` line is why cashiers trust the printed total.

### B3. Split payments as a ledger, never a flag **[data]**
`payments` rows accumulate; `orders.paidPaise` is a **derived cache** recomputed in the same
transaction as any payment insert. Invariants asserted in tests: `paidPaise == Σ payments.amount`,
`duePaise == total - paid >= 0`, no row may make `paid > total` (reject, don't clamp — an
overpayment means the cashier mis-entered an amount).

---

## C. Offline-first data patterns

### C1. Outbox pattern with a single committed transaction **[data]**
```dart
await db.transaction(() async {
  await into(orders).insert(order);
  await into(syncOutbox).insert(Mutation(
    entity: 'order', entityId: order.id, op: Op.insert,
    payloadJson: jsonEncode(order.toJson()),
    idempotencyKey: newUuid(), queuedAt: DateTime.now().toUtc(),
  ).toInsertable());
});
```
Never write business data and queue the mutation in two separate transactions — a crash between
them silently loses a sale. The repository owns the transaction; DAOs stay dumb.

### C2. Local bill number, never server-issued **[data]**
`app_meta['bill.seq']` is incremented inside the order-close transaction. Server-issued numbers
require connectivity and reordering; local numbers survive outages and can be reconciled later by
`(deviceId, seq)` uniqueness. Gapless-ness is a legal requirement in some tax regimes → surface a
warning if `seq != lastSeq + 1`, don't block the sale.

### C3. Drift reactive streams replace any event bus **[data] [flutter]**
`select(tickets).watch()` re-emits on any write to those tables. KDS, due-list and reports are then
plain `StreamBuilder`/Riverpod stream providers — no `EventBus`, no `ValueNotifier` fan-out, no
manual refresh button, no polling. Cross-feature "notifications" are therefore DB writes.

### C4. Sync seam with a no-op implementation **[architecture]**
Define `abstract class SyncGateway { Future<SyncResult> push(List<Mutation> m); }` and ship
`NoopSyncGateway` returning `accepted`. `SyncEngine` (drain batches of 50, `attempts++`,
`stuck` at 10) is real code with real tests from day one; adding Supabase later implements the
interface and changes one DI line. Cheaper than pretending a cloud exists, cheaper than
retrofitting the seam.

### C5. Append-only event table for till forensics **[data]**
`order_events(id, orderId, type, payloadJson, actorId, at)` — insert-only, no updates, no deletes,
no FK cascade. Every state change, price override, void, discount and fire records one row. This
is what lets you reconstruct a shift when a cashier and an owner disagree, and it doubles as the
sync payload source for a future server.

---

## D. Flutter/Dart structure

### D1. Feature folder = domain / application / ui **[architecture]**
```
features/<f>/domain/       pure Dart, no Flutter import, 100% unit-testable   ← put logic HERE
features/<f>/application/  Riverpod notifier + repository binding
features/<f>/ui/           widgets only; read state, dispatch intents; no business rules
```
Smell test: if `domain/` imports `package:flutter/...`, the logic leaked. Move it out.

### D2. `sealed class` state machines give compile-time exhaustiveness **[dart]**
```dart
sealed class TicketStatus { const TicketStatus(); }
class Draft extends TicketStatus {}  class Open extends TicketStatus {}
class InKitchen extends TicketStatus {}  // ... etc
const allowed = {Draft: {Open, Voided}, Open: {InKitchen, Voided}, /* ... */};
```
`switch` over the sealed type in UI means a new state breaks the build everywhere it matters —
which is exactly what you want in a POS.

### D3. `flutter create .` inside an existing repo **[flutter]**
`flutter create --org com.kazama --project-name kazama_pos --platforms=android,ios .` scaffolds
Android/iOS folders around existing files. Root-level docs (`*.md`) survive untouched. If it
refuses on a dirty tree, scaffold in a temp dir and move `lib/ pubspec.yaml android/ ios/ test/`.

### D4. Placeholder UI that is still operable **[flutter] [process]**
"Functionality first" must not mean "unusable". Use plain `ListTile`/`TextButton`/`TextField` with
default theme — no custom colours, radii, shadows or animations — but keep every affordance the
task's test needs, otherwise the Pass/Fail gate can't distinguish a missing feature from missing styling.

### D5. `Result`/sealed failures instead of stringly-typed exceptions **[dart]**
Domain returns `Result<T>` (`Ok(value)` / `Err(AppFailure)`); UI maps `AppFailure` to a message.
Prevents `catch (e) { snackbar(e.toString()) }`, which leaks stack traces to cashiers and hides
the actual bug from the Pass/Fail report.

---

## E. Device / hardware

### E1. Transport interface so hardware absence never blocks logic **[architecture] [device]**
`abstract class PrintTransport { Future<void> send(Uint8List bytes); }` + `FakePrintTransport`
(render monospace in-app, `share_plus` the text) + `EscposBluetoothTransport` later. The renderer,
queue, and "which bills printed" state get tested with zero hardware.

### E2. ESC/POS character budget drives the whole template **[device]**
58 mm ≈ 32 chars/line, 80 mm ≈ 48 (Font A). Column layout for a receipt line:
`name 20/30 · qty 4 · amount 7/9`, then right-padded totals. Fixed-width **text** renderer first,
ESC/POS bytes second, so a template fix is one function, not a printer session.

### E3. Android 12+ Bluetooth needs runtime permission *and* system pairing **[device]**
`BLUETOOTH_CONNECT` (runtime) for classic SPP; pair in Settings first — apps can't pair SPP printers
themselves. Expect a per-model quirk list; keep a `printerName` allowlist in `app_meta`.

### E4. realme/ColorOS background killing hits sync **[device]
Disable battery optimisation for the app or the drain job dies with the screen off. `adb shell
dumpsys deviceidle whitelist +com.kazama.kazama_pos`. Also relevant to any "app paused mid-sale" report.

---

## F. Licence vetting (R6)

### F1. The 30-second check per dependency **[licence]**
`https://pub.dev/packages/<name>/license` + repo `LICENSE` file. Watch for: (a) **version-specific
relicensing** (`flutter_bloc` v9 → commercial licence for the DevTools extension; `provider`/`get_it`
are clean), (b) **GPL/AGPL** = disqualifying for a distributable app, (c) "free tier" SDKs whose
*server* is proprietary (all payment gateways) — the package licence tells you nothing about that.
Then: `flutter licenses` / `flutter gen-l10n`-style audit → commit `LICENSES.md` with one line per
package and the exact licence string observed.

### F2. Dev-time vs shipped packages **[licence]**
`build_runner`, `drift_dev`, `lints` are not linked into the app, so MPL/BSD noise there is
acceptable — but say so explicitly in the audit rather than letting a reviewer assume the worst.

### B4. Largest-remainder allocation for any per-line share **[dart]**
Whenever a bill-level number must be pushed down onto lines (discount share, tax share, a tip split),
never round per line — the rounded parts will not sum back to the total.
```
floors[i]      = (total * weight[i]) ~/ weightSum          // integer, exact
remainder[i]   = (total * weight[i])  % weightSum          // bigger = "closer to another unit"
leftover       = total - Σ floors                          // always < count(weights)
hand out 1 unit at a time to the largest remainder (ties -> lower index, for reproducibility)
```
Property to assert in tests: `Σ parts == total` for randomised inputs, not just for one fixture.
Cost of the naive version: a lost paisa per bill that no report can explain, discovered months later.

### B5. A non-negative money type cannot express signed quantities — decide this in Task 1 **[dart] [architecture]**
`Money` invariant `paise >= 0` kills float bugs, but three real POS quantities are **legitimately signed**:
the ROUNDING line on a receipt, a refund/adjustment row, and a stock delta. Two options, pick deliberately:
1. **Split type** — `Money` unsigned + `MoneyDelta` signed (`int deltaPaise`), with `Money + MoneyDelta -> Money`
   guarded so a negative delta can never underflow a balance. *(chosen for Kazama: keeps 95% of call sites
   simple and makes a negative ledger mutation a type error.)*
2. Signed `Money` + `assert` at every aggregate boundary — fewer types, but every `+`/`-` needs a review.
Whatever you choose, document it next to the class, or the next module invents option 2 and the invariant is gone.

## G. Dart traps that only appear at runtime (found while writing T2 — self-caught, still worth memorising)

### G1. `as List<dynamic>?` throws on decoded JSON lists **[dart]**
`jsonDecode('{"a":[1,2]}')` yields `List<dynamic>`, but a hand-built `{'a': <String>[...]}` yields
`List<String>`. Casting the latter with `as List<dynamic>?` **throws** (`String` is not `dynamic`).
Always write:
```dart
for (final raw in (j['lines'] as List<Object?>? ?? const <Object?>[])) Item.fromJson(raw! as Map<String, Object?>)
```
`List<Object?>` accepts every list type. Same trap on maps: use `as Map<String, Object?>?`, never
`Map<dynamic,dynamic>`. Unit tests that only ever round-trip through `jsonEncode` will **not** catch
this if the object came from code rather than a string — assert `fromJson(decode(encode(x)))` explicitly.

### G2. `copyWith(field: false)` cannot mean "set to false" if the fallback is `?? this.field` **[dart]**
```dart
// broken: activeSet==true only ever happens when the caller passed `true`
active: activeSet == true ? active : (active ?? this.active)
// fix: a separate override parameter whose *presence* is the signal
bool? activeOverride,  ->  active: activeOverride ?? active
```
Nullable bools carry three states (null/true/false) but copyWith needs four (unset / true / false / clear).
For "can be cleared" fields (e.g. `note`) use an explicit sentinel: `String? note, bool? noteSet`.
For enums/ids, `x ?? this.x` is fine — null can't be a legitimate value there.

### G3. Model files must have no cycle even via `export` **[architecture]**
`payment.dart` imports `order.dart` (for `assertPaidConsistency(OrderTicket, …)`) while `order.dart`
does **not** import `payment.dart` — a directed graph, so `part`/`export` tricks stay legal. If the assert
needs both directions, move it to `data/repositories/` and keep models leaf-only. Check with:
`grep -rn "^import" lib/data/models/ | sed 's/.*models\///'` and eyeball for a loop.

### G4. Pin timestamps in codec tests **[process]**
`OrderTicket._copy` stamps `updatedAt: DateTime.now()`. A round-trip assertion that compares `==` on a
local-time DateTime can flake by microseconds/timezone. Fix at the fixture (construct with `updatedAt:`
pinned and a UTC clock), not by loosening the assertion.

## H. drift patterns (learned writing T3 — all of these are version-sensitive)

### H1. Name a column getter `active`/`available`/`required` and you shadow drift's generated member **[dart] [data]**
In a `class X extends Table`, the *getter you write* **is** the column. A Dart field on the row class
that drift also wants to call `active` produces a duplicate-member error in generated code. Pattern used:
Dart-side `isActive` / `isAvailable` / `isRequired` + `.named('active')` / `.named('available')` /
`.named('is_required')` so raw SQL stays readable and `required` avoids the reserved word.

### H2. Every companion field needs `Value(...)` except truly required ones **[data]**
`into(t).insert(TCompanion.insert(id: id, pricePaise: 100, updatedAt: Value(now)))`.
Wrap optional-with-default and nullable fields; don't wrap `required` ones. `updatedAt` can never be
`const`, so a `const TCompanion.insert(...)` with a timestamp is an instant compile error — build it in
a helper (`static Companion _meta(k, v) => TCompanion.insert(..., updatedAt: DateTime.now())`).

### H3. insertOnConflictUpdate is a no-op when the row doesn't exist **[data]**
It emits `INSERT` then `DO UPDATE SET` — on SQLite that resolves to an UPDATE-only path, so a
"seed/restore must be idempotent" upsert needs the row read first. Two patterns that work:
read-then-write inside one `transaction()` (menu item: preserves the sold-out flag), or
`into(t).insert(companion, onConflict: DoUpdate((old) => {...}))` when you must control *which*
columns get overwritten. Prefer the first for small tables (simpler API, version-robust) and the
second only on a hot path.

### H4. `PRAGMA foreign_keys` and the cascade decision **[data]**
Drift enables FK enforcement for `NativeDatabase` on modern versions; still state it in `beforeOpen`/test
`setUp` so a cascade assertion tests what you think it tests. Kazama policy: `order_lines → orders`
cascades (deleting a draft removes its lines); **payments, credit and receipts carry a plain indexed
`order_id` with NO FK**, because a money record must outlive any later ticket cleanup.

### H5. `.first` on a drift stream never completes when the result is empty **[process]**
`expect(await db.watchItems().first, isEmpty)` **hangs until the test times out**. Query streams emit on
open, so this only bites on the very first read of a fresh DB. Guard with a one-shot
`await db.findItem(id)` for "expect empty", and use the stream only to prove re-emission.

### H6. Test the environment before believing a code failure **[process] [device]**
First task that needs `pub get` + codegen is the first where the *machine* can fail. Ship
`tools/setup_check.sh` with the task: it checks flutter/dart, **reachability of pub.dev**, adb/java,
attached device, repo files, and generated-file presence, and exits non-zero with the fix for each gap.
Rule it prints: "do NOT report a code FAIL until this script is clean."

### A5. A sanity script must be right, or it is worse than nothing **[process]**
With no compiler available, structural checks are the only filter — and a naive one
(`count('{') - count('}')`) counts braces inside comments, strings and `${...}`, so it reported 16 healthy
files as broken. `tools/dart_balance.py` skips comments/strings properly, ignores generated `*.g.dart`,
and states its own limit in the docstring: balanced delimiters only, types/names/nullability still need
`dart analyze`. Rule for any verification tool you write under time pressure: **prove it discriminates** —
feed it one deliberately broken file and confirm it reports exactly that one.
