#!/usr/bin/env python3
"""Reference audit for a repo that has never been compiled (see SESSION_LOG).

This is NOT a type checker and cannot replace one. It is a cheap name-existence
sweep: every `receiver.member` in the files it scans must have SOME declaration
somewhere in `lib/`, otherwise it is printed as "unresolved". It exists because a
long run of this project's bugs were invented member names (`Money * int`,
`item.noteHint`, a whole `OutboxDao` class that never existed,
`RadioListTile(groupValue:)`) which no amount of brace-counting catches.

Expect a LOT of noise: without a resolved type, `theme.textTheme`, `Icons.close`
and `MediaQuery.viewInsets` are indistinguishable from a real typo, so Flutter's
own surface is whitelisted by name. The signal to read is a *domain* name in the
output (something like `line.unitPriceSnapshot`), not the 100 `textTheme` lines.

Usage:
    python3 tools/dart_refs.py            # features + app + tests, one report
    python3 tools/dart_refs.py --quiet    # skip the obvious Flutter-receiver lines
"""
import os
import re
import sys

QUIET = "--quiet" in sys.argv
LIB = "lib"
SCAN = ["lib/features", "lib/app", "lib/sync", "lib/data/repositories", "lib/data/daos", "test"]

FLUTTERISH = set(
    """Text Icon Icons Card Row Column Padding SizedBox Theme MediaQuery Navigator Scaffold
BoxDecoration Border Radius EdgeInsets EdgeInsetsDirectional CrossAxisAlignment MainAxisSize
TextAlign TextAlign Center FontWeight TextStyle ChoiceChip CircleAvatar FilledButton TextButton
OutlinedButton ButtonStyle IconButton ListView RefreshIndicator Divider Wrap Align Expanded
GestureDetector Opacity StatefulWidget StatelessWidget ConsumerWidget ConsumerStatefulWidget
ConsumerState State FutureBuilder StreamBuilder TextField ToggleButtons Switch Checkbox Radio
LinearProgressIndicator CircularProgressIndicator AppBar NavigationBar Badge SnackBar
SnackBarBehavior ScaffoldMessenger SelectableText FractionallySizedBox Container SingleChildScrollView
IndexedStack NavigationDestination VisualDensity ListTile CheckboxListTile SwitchListTile
RadioListTile Slider Tooltip ExpansionTile DataTable DataRow DataColumn TableRow
FlutterError Colors Color ColorScheme AppLifecycleState WidgetsBinding SystemNavigator
TextInputType TextInputDecoration InputDecoration OutlineInputBorder EdgeInsetsGeometry
Tween Animatable Curves Interval Size EdgeInsets only symmetric fromLTRB horizontal vertical
bottom top left right min max infinity axis
bodyLarge bodyMedium bodySmall titleLarge titleMedium titleSmall labelLarge labelSmall labelMedium
headlineSmall headlineMedium displaySmall errorContainer secondaryContainer surfaceContainerHighest
onSurface primaryContainer surfaceVariant outlineVariant inversePrimary tertiaryContainer
lineThrough overline italic bold w400 w500 w600 w700 w900
styleFrom shrink square stretch center centerLeft bottomCenter baseline
colorScheme textTheme appBar dividerTheme cardTheme scaffoldBackgroundColor
tonal icon outlined filledTonal
data dataOrError error hasData hasError maybeWhen when
read watch listen refresh value state notifier call clear append backspace
first last length isEmpty isNotEmpty map where toList toSet fold cast single singleOrNull
any every sort reduce join split trim contains replaceAll substring toString toStringAsFixed
padLeft padRight toIso8601String difference add subtract multiply round ceil floor abs clamp
toInt toDouble parse tryParse now utc fromMillisecondsSinceEpoch microsecondsSinceEpoch
millisecondsSinceEpoch year month day hour minute second weekday
writeAsString readAsString writeAsBytes create write delete exists length stat
writeAsStringSync readAsStringSync existsSync listSync statSync lengthSync deleteSync
createSync path uri segments pathSegments name isDirectory isFile
entries keys values reversed take skip whereType expand followedBy forEach
dispose setState mounted context showSnackBar hideCurrentSnackBar push pushReplacement pop
popAndPushNamed canPop maybePop of
Future Timer Completer Stream unawaited delayed wait
List Map Set Iterable Object Num int double bool String Symbol RegExp StringBuffer StringBuilder
Never dynamic VoidCallback Function
groups_outlined restaurant_menu storefront_outlined settings_backup_restore query_stats_outlined
local_fire_department_outlined note_add_outlined note_outlined remove_circle_outline
add_circle_outline pause_outlined undo check_circle_outline bolt search close info_outline
print_outlined copy_all_outlined save_alt merge_outlined dangerous_outlined lock_outline
lock_open_outlined shield_outlined person_add_alt payments_outlined chevron_left chevron_right
chevron_ellipsis refresh sync sync_alt print error_outline warning_amber
numberWithOptions decimalSigned visiblePassword
fromName toName copyWith jsonEncode jsonDecode
schemaVersion transaction getSingle getSingleOrNull getOrNull
memory syncOutbox orderEvents creditEntries
""".split()
)


# In `--quiet`, receiver names whose members are almost always Flutter's own.
# Kept separate from the member whitelist so a genuine domain bug on a variable
# called `theme`/`row` still prints in the noisy mode.
FLUTTER_RECEIVERS = {
    "theme", "Icons", "Colors", "MediaQuery", "ScaffoldMessenger", "Navigator", "Theme",
    "context", "ref", "state", "widget", "snap", "data", "text", "style", "box", "border",
    "route", "args", "uri", "path", "line", "row", "e", "f", "s", "t", "m", "c", "d", "p",
}


def declarations():
    decl = set()
    for dp, _, fs in os.walk(LIB):
        for f in fs:
            if not f.endswith(".dart"):
                continue
            src = open(os.path.join(dp, f)).read()
            decl |= set(re.findall(r"\bget\s+(\w+)", src))
            decl |= set(re.findall(r"\b(?:final|const|late)\s+(?:[\w<>?,\s]+\s+)?(\w+)\s*[=;]", src))
            decl |= set(re.findall(r"^\s*(?:static\s+)?(?:const\s+)?[\w<>?,\s]+?\s+(\w+)\s*\(", src, re.M))
            decl |= set(re.findall(r"^(?:final\s+)?(?:abstract\s+)?(?:interface\s+)?class\s+(\w+)", src, re.M))
            decl |= set(re.findall(r"^\s*(\w+)\s*(?:\([^)]*\))?\s*[;,]\s*$", src, re.M))  # enum members
            decl |= set(re.findall(r"\b(\w+)\s*=>", src))
            decl |= set(re.findall(r"\b(\w+)\s*=\s*(?:Provider|FutureProvider|StreamProvider|StateProvider)", src))
            # constructor named parameters (`this.foo` and `required this.foo`)
            decl |= set(re.findall(r"this\.(\w+)", src))
    # drift generates a getter per table (`db.syncOutbox`, `db.receipts`) and per DAO
    # mixin; none of that exists in handwritten source, so every table/DAO name is
    # declared by its class. Without this, the whole generated layer reads as missing.
    for dp, _, fs in os.walk(os.path.join(LIB, "data")):
        for f in fs:
            if not f.endswith(".dart"):
                continue
            src = open(os.path.join(dp, f)).read()
            for m in re.finditer(r"^(?:final )?class (\w+)", src, re.M):
                name = m.group(1)
                if name.endswith(("Dao", "Mixin")) or "Table" in name:
                    decl.add(name[0].lower() + name[1:])
                decl.add(name)
    for f in os.listdir(os.path.join(LIB, "data", "tables")):
        src = open(os.path.join(LIB, "data", "tables", f)).read()
        for m in re.finditer(r"^class (\w+) extends Table", src, re.M):
            # drift's lowerCamel getter for `class SyncOutbox` is `syncOutbox`
            decl.add(m.group(1)[0].lower() + m.group(1)[1:])
    return decl


def main():
    decl = declarations()
    unresolved = {}
    for root in SCAN:
        if not os.path.isdir(root):
            continue
        for dp, _, fs in os.walk(root):
            if ".g.dart" in dp:
                continue
            for f in fs:
                if not f.endswith(".dart") or f.endswith(".g.dart"):
                    continue
                p = os.path.join(dp, f)
                for i, line in enumerate(open(p).read().splitlines(), 1):
                    line = re.sub(r"//.*", "", line)
                    line = re.sub(r"'[^']*'", "", line)
                    line = re.sub(r'"[^"]*"', "", line)
                    for m in re.finditer(r"\b([a-zA-Z_]\w*)\.([a-zA-Z_]\w*)", line):
                        recv, mem = m.group(1), m.group(2)
                        if mem in decl or mem in FLUTTERISH:
                            continue
            
                        unresolved.setdefault(mem, []).append(f"{p}:{i} ({recv}.{mem})")
    if not unresolved:
        print("no unresolved member names (see the docstring: this is not a type check)")
        return 0
    for mem in sorted(unresolved):
        locs = unresolved[mem]
        print(f"{mem:26} {len(locs):3}x   {locs[0]}")
    print(f"\n{len(unresolved)} distinct names. Domain names here are real bugs; "
          f"Icons/Theme/MediaQuery entries are the whitelist's blind spots.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
