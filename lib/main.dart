import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_pet.dart';
import 'pet.dart'; // colors, rnd, Mood, pet, PetPanel (your existing PET + EYES code)

/// Optional hook: lets the app push raw commands (e.g. "LEVEL:2") to the pet.
/// Wire it to whatever write method your ble_pet.dart has, e.g.
///   sendRaw = (s) => blePet.write(s);
void Function(String)? sendRaw;

// ───────────────────────── MODELS ─────────────────────────
typedef J = Map<String, dynamic>;
List<T> _list<T>(dynamic x, T Function(J) f) =>
    ((x ?? []) as List).map((e) => f(Map<String, dynamic>.from(e))).toList();

/// Days since 2000-01-01 in local calendar days (DST safe).
int today() {
  final n = DateTime.now();
  return DateTime.utc(n.year, n.month, n.day).difference(DateTime.utc(2000)).inDays;
}

class Task {
  String title; bool done;
  Task(this.title, [this.done = false]);
  J toJson() => {'t': title, 'd': done};
  factory Task.fromJson(J j) => Task(j['t'], j['d'] ?? false);
}

/// Flashcard with SM-2 style scheduling.
/// grade: 0 Again, 1 Hard, 2 Good, 3 Easy
class Flash {
  String q, a;
  int miss, reps, ivl, due, lapses;
  double ease;
  Flash(this.q, this.a, [this.miss = 0, this.reps = 0, this.ivl = 0, this.due = 0, this.ease = 2.5, this.lapses = 0]);

  bool get isNew => reps == 0 && lapses == 0 && due == 0;
  bool get mastered => ivl >= 21;

  /// Returns [intervalDays, newEase] without changing the card (used for button previews).
  List<num> calc(int g) {
    var e = ease;
    if (g == 0) return [0, max(1.3, e - 0.2)];
    if (g == 1) e = max(1.3, e - 0.15);
    if (g == 3) e += 0.15;
    int i;
    if (reps == 0) {
      i = g == 3 ? 4 : 1;
    } else if (reps == 1) {
      i = g == 1 ? 3 : (g == 2 ? 6 : 9);
    } else {
      final f = g == 1 ? 1.2 : (g == 3 ? e * 1.3 : e);
      i = max(ivl + 1, (ivl * f).round());
    }
    return [i, e];
  }

  /// Applies a grade. Returns true if the card just became "mastered".
  bool review(int g) {
    final wasMastered = mastered;
    final r = calc(g);
    ease = r[1].toDouble();
    if (g == 0) {
      reps = 0; lapses++; ivl = 0; due = today();
    } else {
      reps++; ivl = r[0].toInt(); due = today() + ivl;
    }
    return !wasMastered && mastered;
  }

  J toJson() => {'q': q, 'a': a, 'm': miss, 'r': reps, 'i': ivl, 'u': due, 'e': ease, 'l': lapses};
  factory Flash.fromJson(J j) => Flash(j['q'], j['a'], j['m'] ?? 0, j['r'] ?? 0, j['i'] ?? 0, j['u'] ?? 0,
      (j['e'] as num?)?.toDouble() ?? 2.5, j['l'] ?? 0);
}

class Deck {
  String name; List<Flash> cards;
  Deck(this.name, [List<Flash>? c]) : cards = c ?? [];

  /// Due reviews (oldest first) followed by a limited number of new cards.
  List<Flash> session(int t, {int newLimit = 10}) {
    final rev = cards.where((c) => !c.isNew && c.due <= t).toList()..sort((a, b) => a.due.compareTo(b.due));
    final fresh = cards.where((c) => c.isNew).take(newLimit);
    return [...rev, ...fresh];
  }

  J toJson() => {'n': name, 'c': cards.map((e) => e.toJson()).toList()};
  factory Deck.fromJson(J j) => Deck(j['n'], _list(j['c'], Flash.fromJson));
}

class Entry {
  String mood, text, date;
  Entry(this.mood, this.text, this.date);
  J toJson() => {'m': mood, 't': text, 'd': date};
  factory Entry.fromJson(J j) => Entry(j['m'], j['t'], j['d'] ?? '');
}

class Preset {
  String name; int focus, brk;
  Preset(this.name, this.focus, this.brk);
  J toJson() => {'n': name, 'f': focus, 'b': brk};
  factory Preset.fromJson(J j) => Preset(j['n'], j['f'], j['b']);
}

// ───────────────────────── EVOLUTION ─────────────────────────
const lvKp = [0, 100, 300, 700, 1500];
const lvName = ['Egg', 'Hatchling', 'Buddy', 'Scholar', 'Sage'];
const lvIcon = ['🥚', '🐣', '🐾', '🎓', '✨'];

// ───────────────────────── STORE (saved to device) ─────────────────────────
class Store extends ChangeNotifier {
  List<Task> tasks = [];
  List<Deck> decks = [];
  List<Entry> entries = [];
  List<Preset> presets = [];
  Map<String, double> focus = {};
  Map<String, String> blocked = {}; // package -> app name
  bool blockOn = false;
  int sessions = 0, right = 0, wrong = 0, kp = 0, run = 0, presetIdx = 0, deckIdx = 0;
  Timer? _debounce;

  Deck get deck => decks[deckIdx];
  Preset get preset => presets[presetIdx];

  int get level {
    var l = 0;
    for (var k = 0; k < lvKp.length; k++) { if (kp >= lvKp[k]) l = k; }
    return l;
  }

  int get dueCount => decks.fold(0, (s, d) => s + d.session(today()).length);
  int get masteredCount => decks.fold(0, (s, d) => s + d.cards.where((c) => c.mastered).length);

  /// Adds knowledge points and triggers the evolution celebration on level-up.
  void addKp(int n) {
    if (n <= 0) return;
    final before = level;
    kp += n;
    if (level > before) {
      pet.react(Mood.excited, 'LEVEL UP! I evolved: ${lvName[level]} ${lvIcon[level]}', ms: 5000);
    }
    pushLevel();
  }

  void pushLevel() => sendRaw?.call('LEVEL:$level');

  static String key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int get streak {
    var d = DateTime.now();
    if ((focus[key(d)] ?? 0) == 0) d = d.subtract(const Duration(days: 1));
    var n = 0;
    while ((focus[key(d)] ?? 0) > 0) { n++; d = d.subtract(const Duration(days: 1)); }
    return n;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('data');
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as J;
        tasks = _list(j['tasks'], Task.fromJson);
        decks = _list(j['decks'], Deck.fromJson);
        entries = _list(j['entries'], Entry.fromJson);
        presets = _list(j['presets'], Preset.fromJson);
        focus = Map<String, double>.from((j['focus'] ?? {}).map((k, v) => MapEntry(k, (v as num).toDouble())));
        blocked = Map<String, String>.from(j['blocked'] ?? {});
        blockOn = j['blockOn'] ?? false;
        sessions = j['sessions'] ?? 0; right = j['right'] ?? 0; wrong = j['wrong'] ?? 0;
        kp = j['kp'] ?? 0; presetIdx = j['presetIdx'] ?? 0; deckIdx = j['deckIdx'] ?? 0;
      } catch (_) {}
    } else {
      tasks = [Task('Solve 5 calculus problems'), Task('Write Shakespeare essay outline')];
    }
    if (presets.isEmpty) presets = [Preset('Classic', 25, 5), Preset('Short', 15, 3), Preset('Deep work', 50, 10)];
    if (decks.isEmpty) {
      decks = [Deck('General', [Flash('Derivative of x²?', '2x'), Flash('Powerhouse of the cell?', 'mitochondria'), Flash('Capital of the Philippines?', 'manila')])];
    }
    presetIdx = presetIdx.clamp(0, presets.length - 1);
    deckIdx = deckIdx.clamp(0, decks.length - 1);
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('data', jsonEncode({
      'tasks': tasks.map((e) => e.toJson()).toList(),
      'decks': decks.map((e) => e.toJson()).toList(),
      'entries': entries.map((e) => e.toJson()).toList(),
      'presets': presets.map((e) => e.toJson()).toList(),
      'focus': focus, 'blocked': blocked, 'blockOn': blockOn,
      'sessions': sessions, 'right': right, 'wrong': wrong,
      'kp': kp, 'presetIdx': presetIdx, 'deckIdx': deckIdx,
    }));
  }

  /// Call after every change: updates the UI and saves (debounced).
  void changed() {
    notifyListeners();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), save);
  }
}

final store = Store();

// ───────────────────────── APP BLOCKER (Android bridge) ─────────────────────────
class Blocker {
  static const _ch = MethodChannel('deskpet/blocker');

  static Future<T?> _call<T>(String m, [dynamic args]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<T>(m, args);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> enabled() async => (await _call<bool>('enabled')) ?? false;
  static Future<void> openSettings() async { await _call<void>('openSettings'); }

  static Future<List<Map<String, String>>> apps() async {
    final r = await _call<List<dynamic>>('apps');
    return (r ?? []).map((e) => Map<String, String>.from(e as Map)).toList();
  }

  static Future<void> start(DateTime until) async {
    if (!store.blockOn || store.blocked.isEmpty) return stop();
    await _call<void>('block', {
      'packages': store.blocked.keys.toList(),
      'until': until.millisecondsSinceEpoch,
      // {m} is replaced natively with the minutes left.
      'messages': [
        "Hey! We're focusing together, remember? 🐾 Only {m} min to go!",
        'I believe in you! Leave this app and come back to me.',
        'Not now, friend! Just {m} more minutes. You got this! 💪',
        "Psst... that app can wait. I'll be so proud if you leave! 🥺",
      ],
    });
  }

  static Future<void> stop() async { await _call<void>('unblock'); }
}

// ───────────────────────── POMODORO ─────────────────────────
class Pomo extends ChangeNotifier {
  bool focus = true, running = false, fast = false, half = false;
  int left = 1500, total = 1500, _since = 0;
  DateTime? _last;
  Timer? _t;

  /// Keeps the app-blocking layer in sync with the timer.
  void shield() {
    if (running && focus) {
      Blocker.start(DateTime.now().add(Duration(seconds: fast ? (left / 60).ceil() : left)));
    } else {
      Blocker.stop();
    }
  }

  void setFast(bool v) { fast = v; shield(); notifyListeners(); }

  void reset() {
    _t?.cancel();
    if (running) pet.setBase(Mood.idle);
    running = false; focus = true; half = false;
    left = total = store.preset.focus * 60;
    shield();
    notifyListeners();
  }

  void selectPreset(int i) {
    store.presetIdx = i;
    store.changed();
    reset();
  }

  void toggle() => running ? pause() : start();

  void start() {
    running = true;
    _last = DateTime.now();
    store.pushLevel();
    pet.setBase(focus ? Mood.focused : Mood.relaxed);
    pet.react(Mood.happy, focus ? "Let's focus together!" : 'Break time. Stretch!', ms: 3000);
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _step());
    shield();
    notifyListeners();
  }

  void pause() {
    running = false;
    _t?.cancel();
    pet.setBase(Mood.idle);
    pet.react(Mood.sad, "Paused... I'll wait for you!");
    shield();
    notifyListeners();
  }

  // Uses the wall clock, so the timer catches up if Android throttles it.
  void _step() {
    final secs = DateTime.now().difference(_last!).inSeconds;
    if (secs < 1) return;
    _last = _last!.add(Duration(seconds: secs));
    left -= secs * (fast ? 60 : 1);
    _since += secs;
    if (left <= 0) return _done();
    if (focus && !half && left * 2 <= total) {
      half = true;
      pet.react(Mood.excited, 'Halfway there! Keep going!');
    } else if (_since >= (fast ? 4 : 20)) {
      _since = 0;
      final m = focus ? [Mood.curious, Mood.happy, Mood.focused] : [Mood.curious, Mood.sleepy, Mood.happy];
      final msg = focus ? ['What are you working on?', "You're doing great!", 'Deep focus mode...'] : ['Nice break!', 'Hydrate!', 'Zzz... so relaxing'];
      final i = rnd.nextInt(3);
      pet.react(m[i], msg[i]);
    }
    notifyListeners();
  }

  void _done() {
    _t?.cancel();
    running = false;
    half = false;
    if (focus) {
      final k = Store.key(DateTime.now());
      store.focus[k] = (store.focus[k] ?? 0) + total / 60;
      store.sessions++;
      pet.react(Mood.excited, 'Session complete! +25 KP', ms: 4000);
      store.addKp(25); // may override the message with a LEVEL UP
      focus = false;
      left = total = store.preset.brk * 60;
      pet.setBase(Mood.relaxed);
    } else {
      focus = true;
      left = total = store.preset.focus * 60;
      pet.setBase(Mood.focused);
      pet.react(Mood.startled, 'Break over! Back to it!');
    }
    shield(); // running is false now → removes the blocking layer
    store.changed();
    notifyListeners();
  }
}

final pomo = Pomo();

// ───────────────────────── IDLE BUDDY (app-side playfulness) ─────────────────────────
class Buddy {
  Timer? _t;
  DateTime _next = DateTime.now().add(const Duration(seconds: 20));

  static final lines = <List<Object>>[
    [Mood.excited, 'Zoomies! 💨'],
    [Mood.curious, 'Psst... wanna play?'],
    [Mood.happy, 'I love hanging out with you!'],
    [Mood.sleepy, '*yawn* ...I\'m awake! Promise.'],
    [Mood.startled, 'Boop! Did you see that?'],
    [Mood.curious, 'What\'s that over there? 👀'],
    [Mood.excited, 'Let\'s learn something new!'],
    [Mood.happy, 'Stretch break? Roll those shoulders!'],
    [Mood.relaxed, 'Water time! 💧'],
  ];

  void start() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
      if (pomo.running || DateTime.now().isBefore(_next)) return;
      _next = DateTime.now().add(Duration(seconds: 25 + rnd.nextInt(35)));
      final due = store.dueCount;
      if (due > 0 && rnd.nextInt(3) == 0) {
        pet.react(Mood.curious, 'I have $due cards waiting! Wanna play?', ms: 3000);
        return;
      }
      final l = lines[rnd.nextInt(lines.length)];
      pet.react(l[0] as Mood, l[1] as String, ms: 2500);
    });
  }
}

final buddy = Buddy();

// ───────────────────────── APP ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  pomo.reset();
  runApp(const DeskPetApp());
  blePet.init(); // auto-reconnects to the saved pet
  buddy.start();
}

class DeskPetApp extends StatelessWidget {
  const DeskPetApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Desk Pet',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: sage, surface: cream),
          scaffoldBackgroundColor: cream,
        ),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;
  static const hello = ['Timer time!', 'Your tasks!', 'Quiz time!', 'How was it?', 'Your progress!'];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            const PetPanel(),
            const EvoBar(),
            Expanded(child: IndexedStack(index: i, children: const [TimerPage(), TasksPage(), CardsPage(), ReviewPage(), StatsPage()])),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) {
            setState(() => i = v);
            pet.react(Mood.curious, hello[v], ms: 2000);
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.timer_outlined), label: 'Timer'),
            NavigationDestination(icon: Icon(Icons.checklist), label: 'Tasks'),
            NavigationDestination(icon: Icon(Icons.style_outlined), label: 'Cards'),
            NavigationDestination(icon: Icon(Icons.favorite_border), label: 'Review'),
            NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Stats'),
          ],
        ),
      );
}

/// Shows the pet's evolution stage and progress to the next one.
class EvoBar extends StatelessWidget {
  const EvoBar({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final l = store.level;
          final isMax = l >= lvKp.length - 1;
          final lo = lvKp[l];
          final hi = isMax ? lo : lvKp[l + 1];
          final p = isMax ? 1.0 : (store.kp - lo) / (hi - lo);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(children: [
              Text(lvIcon[l], style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Text(lvName[l], style: const TextStyle(fontWeight: FontWeight.bold, color: ink)),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: p.clamp(0.0, 1.0), minHeight: 10, color: sage, backgroundColor: Colors.black12),
                ),
              ),
              const SizedBox(width: 12),
              Text(isMax ? '${store.kp} KP · MAX' : '${store.kp}/$hi KP', style: const TextStyle(fontSize: 12)),
            ]),
          );
        },
      );
}

BoxDecoration box() => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20));
InputDecoration field(String hint) => InputDecoration(
    hintText: hint, filled: true, fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none));
String mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
String fmtDays(int d) => d <= 0 ? '<1d' : d < 30 ? '${d}d' : d < 365 ? '${(d / 30).round()}mo' : '${(d / 365).toStringAsFixed(1)}y';

Future<String?> askText(BuildContext c, String title, {String initial = '', int lines = 1}) {
  final t = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: t, autofocus: true, maxLines: lines),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, t.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

// ── CSV import ──
/// Parses CSV/TSV text (quotes, escaped quotes, newlines inside quotes, auto delimiter).
List<List<String>> parseCsv(String s) {
  if (s.startsWith('\uFEFF')) s = s.substring(1);
  final firstLine = s.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  var d = ',';
  var best = -1;
  for (final c in [',', ';', '\t']) {
    final n = c.allMatches(firstLine).length;
    if (n > best) { best = n; d = c; }
  }
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var inQ = false;
  for (var k = 0; k < s.length; k++) {
    final c = s[k];
    if (inQ) {
      if (c == '"') {
        if (k + 1 < s.length && s[k + 1] == '"') { f.write('"'); k++; } else { inQ = false; }
      } else { f.write(c); }
    } else if (c == '"') { inQ = true; }
    else if (c == d) { row.add(f.toString()); f.clear(); }
    else if (c == '\n' || c == '\r') {
      if (c == '\r' && k + 1 < s.length && s[k + 1] == '\n') k++;
      row.add(f.toString()); f.clear();
      rows.add(row); row = [];
    } else { f.write(c); }
  }
  if (f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
  return rows;
}

/// Lets the user pick a CSV (question,answer) and turns it into a deck.
/// Returns the number of cards added (0 if cancelled / nothing valid).
Future<int> importCsv() async {
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom, allowedExtensions: ['csv', 'tsv', 'txt'], withData: true);
  if (res == null || res.files.isEmpty || res.files.first.bytes == null) return 0;
  final file = res.files.first;
  final rows = parseCsv(utf8.decode(file.bytes!, allowMalformed: true));

  const qHead = {'question', 'questions', 'q', 'front', 'term', 'prompt'};
  const aHead = {'answer', 'answers', 'a', 'back', 'definition', 'response'};
  final cards = <Flash>[];
  for (var k = 0; k < rows.length; k++) {
    final r = rows[k];
    if (r.length < 2) continue;
    final q = r[0].trim(), a = r[1].trim();
    if (q.isEmpty || a.isEmpty) continue;
    if (k == 0 && qHead.contains(q.toLowerCase()) && aHead.contains(a.toLowerCase())) continue; // header row
    cards.add(Flash(q, a));
  }
  if (cards.isEmpty) return 0;

  var name = file.name.replaceAll(RegExp(r'\.[^.]*$'), '').trim();
  if (name.isEmpty) name = 'Imported';
  var idx = store.decks.indexWhere((d) => d.name == name);
  if (idx < 0) { store.decks.add(Deck(name)); idx = store.decks.length - 1; }
  final deck = store.decks[idx];
  final seen = deck.cards.map((c) => c.q.toLowerCase()).toSet();
  var added = 0;
  for (final c in cards) {
    if (seen.add(c.q.toLowerCase())) { deck.cards.add(c); added++; }
  }
  store.deckIdx = idx;
  store.changed();
  pet.react(Mood.excited, 'New deck "$name"! $added cards to learn!', ms: 3500);
  return added;
}

// ── Timer ──
void presetDialog(BuildContext ctx, {int? idx}) {
  final p = idx == null ? null : store.presets[idx];
  final n = TextEditingController(text: p?.name ?? '');
  final f = TextEditingController(text: '${p?.focus ?? 25}');
  final b = TextEditingController(text: '${p?.brk ?? 5}');
  showDialog(
    context: ctx,
    builder: (d) => AlertDialog(
      title: Text(p == null ? 'New timer' : 'Edit timer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: f, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Focus (minutes)')),
        TextField(controller: b, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Break (minutes)')),
      ]),
      actions: [
        if (p != null && store.presets.length > 1)
          TextButton(
            onPressed: () {
              store.presets.removeAt(idx!);
              store.presetIdx = 0;
              store.changed();
              pomo.reset();
              Navigator.pop(d);
            },
            child: const Text('Delete'),
          ),
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final fm = (int.tryParse(f.text) ?? 25).clamp(1, 180).toInt();
            final bm = (int.tryParse(b.text) ?? 5).clamp(1, 60).toInt();
            final name = n.text.trim().isEmpty ? '$fm/$bm' : n.text.trim();
            if (p == null) {
              store.presets.add(Preset(name, fm, bm));
              store.presetIdx = store.presets.length - 1;
            } else {
              p.name = name; p.focus = fm; p.brk = bm;
            }
            store.changed();
            pomo.reset();
            Navigator.pop(d);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class TimerPage extends StatelessWidget {
  const TimerPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([pomo, store]),
        builder: (_, __) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
              for (var k = 0; k < store.presets.length; k++)
                ChoiceChip(
                  label: Text('${store.presets[k].name} · ${store.presets[k].focus}/${store.presets[k].brk}'),
                  selected: store.presetIdx == k,
                  onSelected: pomo.running ? null : (_) => pomo.selectPreset(k),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Custom'),
                onPressed: pomo.running ? null : () => presetDialog(context),
              ),
            ]),
            Center(
              child: TextButton.icon(
                onPressed: pomo.running ? null : () => presetDialog(context, idx: store.presetIdx),
                icon: const Icon(Icons.edit, size: 16),
                label: Text('Edit "${store.preset.name}"'),
              ),
            ),
            Center(child: Text(pomo.focus ? 'Focus Session' : 'Break', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: ink))),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 200, height: 200,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: (pomo.left / pomo.total).clamp(0.0, 1.0),
                      strokeWidth: 12,
                      color: pomo.focus ? sage : butter,
                      backgroundColor: Colors.black12,
                    ),
                  ),
                  Text(mmss(max(pomo.left, 0)), style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: ink)),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: sage, foregroundColor: ink, padding: const EdgeInsets.all(16)),
                  onPressed: pomo.toggle,
                  icon: Icon(pomo.running ? Icons.pause : Icons.play_arrow),
                  label: Text(pomo.running ? 'Pause' : 'Start ${pomo.focus ? "${store.preset.focus}m focus" : "${store.preset.brk}m break"}'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(onPressed: pomo.reset, icon: const Icon(Icons.restart_alt), tooltip: 'Reset'),
            ]),
            SwitchListTile(
              title: const Text('Demo speed (×60) – see all reactions fast'),
              value: pomo.fast,
              onChanged: pomo.setFast,
            ),
            const Divider(height: 32),
            const ShieldPanel(),
            const SizedBox(height: 12),
            const BluetoothPanel(),
          ],
        ),
      );
}

// ── Focus Shield (blocks chosen apps during focus sessions) ──
class ShieldPanel extends StatefulWidget {
  const ShieldPanel({super.key});
  @override
  State<ShieldPanel> createState() => _ShieldState();
}

class _ShieldState extends State<ShieldPanel> with WidgetsBindingObserver {
  bool allowed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final e = await Blocker.enabled();
    if (mounted) setState(() => allowed = e);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Focus Shield', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              if (!Platform.isAndroid)
                const Text('App blocking is available on Android only.')
              else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Block chosen apps during focus'),
                  subtitle: const Text("Your pet will cover them and ask you to leave."),
                  value: store.blockOn,
                  onChanged: (v) { store.blockOn = v; store.changed(); pomo.shield(); },
                ),
                if (!allowed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: Blocker.openSettings,
                      icon: const Icon(Icons.accessibility_new),
                      label: const Text('Allow in Accessibility settings'),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppPicker())),
                  icon: const Icon(Icons.apps),
                  label: Text(store.blocked.isEmpty ? 'Choose apps to block' : 'Blocked apps: ${store.blocked.length}'),
                ),
              ],
            ]),
          ),
        ),
      );
}

class AppPicker extends StatefulWidget {
  const AppPicker({super.key});
  @override
  State<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<AppPicker> {
  List<Map<String, String>> apps = [];
  bool loading = true;
  String q = '';

  @override
  void initState() {
    super.initState();
    Blocker.apps().then((a) { if (mounted) setState(() { apps = a; loading = false; }); });
  }

  @override
  Widget build(BuildContext context) {
    final shown = apps.where((a) => a['name']!.toLowerCase().contains(q.toLowerCase())).toList()
      ..sort((a, b) {
        final sa = store.blocked.containsKey(a['package']) ? 0 : 1;
        final sb = store.blocked.containsKey(b['package']) ? 0 : 1;
        return sa != sb ? sa - sb : a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase());
      });
    return Scaffold(
      appBar: AppBar(title: const Text('Apps to block while focusing')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(onChanged: (v) => setState(() => q = v), decoration: field('Search apps')),
              ),
              Expanded(
                child: ListView(children: [
                  for (final a in shown)
                    CheckboxListTile(
                      value: store.blocked.containsKey(a['package']),
                      title: Text(a['name']!),
                      subtitle: Text(a['package']!, style: const TextStyle(fontSize: 11)),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) { store.blocked[a['package']!] = a['name']!; } else { store.blocked.remove(a['package']); }
                        });
                        store.changed();
                        pomo.shield();
                      },
                    ),
                ]),
              ),
            ]),
    );
  }
}

// ── Bluetooth ──
class BluetoothPanel extends StatelessWidget {
  const BluetoothPanel({super.key});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Desk Pet (Bluetooth)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(valueListenable: blePet.status, builder: (_, s, __) => Text('Status: $s')),
            const SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: blePet.connected,
              builder: (_, on, __) => on
                  ? FilledButton.icon(onPressed: blePet.disconnect, icon: const Icon(Icons.bluetooth_disabled), label: const Text('Disconnect & forget'))
                  : ValueListenableBuilder<bool>(
                      valueListenable: blePet.scanning,
                      builder: (_, sc, __) => FilledButton.icon(
                        onPressed: sc ? null : blePet.scan,
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(sc ? 'Scanning…' : 'Scan for pet'),
                      ),
                    ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: blePet.connected,
              builder: (_, on, __) => on
                  ? const SizedBox.shrink()
                  : ValueListenableBuilder<List<ScanResult>>(
                      valueListenable: blePet.results,
                      builder: (_, list, __) => Column(children: [
                        for (final r in list)
                          ListTile(
                            leading: const Icon(Icons.pets),
                            title: Text(r.advertisementData.advName.isEmpty ? 'DeskPet' : r.advertisementData.advName),
                            subtitle: Text(r.device.remoteId.str),
                            trailing: Text('${r.rssi} dBm'),
                            onTap: () => blePet.connect(r.device),
                          ),
                      ]),
                    ),
            ),
          ]),
        ),
      );
}

// ── Tasks ──
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});
  @override
  State<TasksPage> createState() => _TasksState();
}

class _TasksState extends State<TasksPage> {
  final c = TextEditingController();
  void add() {
    if (c.text.trim().isEmpty) return;
    store.tasks.add(Task(c.text.trim()));
    c.clear();
    store.changed();
    pet.react(Mood.curious, 'New task! We can do it.');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) => ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(child: TextField(controller: c, onSubmitted: (_) => add(), decoration: field('Add a task'))),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: add, icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 8),
          for (final t in store.tasks)
            Card(
              elevation: 0, color: Colors.white,
              child: CheckboxListTile(
                value: t.done,
                title: Text(t.title, style: TextStyle(decoration: t.done ? TextDecoration.lineThrough : null)),
                secondary: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { store.tasks.remove(t); store.changed(); }),
                onChanged: (v) {
                  t.done = v!;
                  if (v) {
                    final all = store.tasks.every((x) => x.done);
                    pet.react(all ? Mood.excited : Mood.happy, all ? 'ALL tasks done! Amazing!' : 'Task done! +10 KP');
                    store.addKp(10);
                  }
                  store.changed();
                },
              ),
            ),
        ]),
      );
}

// ── Flashcards with decks + spaced repetition ──
void cardDialog(BuildContext ctx, {Flash? f}) {
  final q = TextEditingController(text: f?.q), a = TextEditingController(text: f?.a);
  showDialog(
    context: ctx,
    builder: (d) => AlertDialog(
      title: Text(f == null ? 'New flashcard' : 'Edit flashcard'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: q, decoration: const InputDecoration(labelText: 'Question')),
        TextField(controller: a, decoration: const InputDecoration(labelText: 'Answer')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final qq = q.text.trim(), aa = a.text.trim();
            if (qq.isNotEmpty && aa.isNotEmpty) {
              if (f == null) { store.deck.cards.add(Flash(qq, aa)); } else { f.q = qq; f.a = aa; }
              store.changed();
            }
            Navigator.pop(d);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class DeckEditor extends StatelessWidget {
  const DeckEditor({super.key});

  String status(Flash f) {
    if (f.isNew) return 'new';
    final d = f.due - today();
    return d <= 0 ? 'due now' : 'due in ${fmtDays(d)}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (ctx, __) {
          final d = store.deck;
          return Scaffold(
            appBar: AppBar(title: Text(d.name), actions: [
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.drive_file_rename_outline),
                onPressed: () async {
                  final n = await askText(ctx, 'Rename deck', initial: d.name);
                  if (n != null && n.isNotEmpty) { d.name = n; store.changed(); }
                },
              ),
              IconButton(
                tooltip: 'Import CSV',
                icon: const Icon(Icons.upload_file),
                onPressed: () async {
                  final n = await importCsv();
                  if (ctx.mounted && n > 0) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Imported $n cards')));
                  }
                },
              ),
              IconButton(
                tooltip: 'Bulk add',
                icon: const Icon(Icons.playlist_add),
                onPressed: () async {
                  final t = await askText(ctx, 'One card per line:  question | answer', lines: 8);
                  if (t == null) return;
                  for (final line in t.split('\n')) {
                    final p = line.split('|');
                    if (p.length >= 2 && p[0].trim().isNotEmpty && p[1].trim().isNotEmpty) {
                      d.cards.add(Flash(p[0].trim(), p.sublist(1).join('|').trim()));
                    }
                  }
                  store.changed();
                },
              ),
              if (store.decks.length > 1)
                IconButton(
                  tooltip: 'Delete deck',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final yes = await showDialog<bool>(
                      context: ctx,
                      builder: (x) => AlertDialog(
                        title: Text('Delete "${d.name}"?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(x, true), child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (yes == true && ctx.mounted) {
                      Navigator.pop(ctx);
                      store.decks.remove(d);
                      store.deckIdx = 0;
                      store.changed();
                    }
                  },
                ),
            ]),
            floatingActionButton: FloatingActionButton(onPressed: () => cardDialog(ctx), child: const Icon(Icons.add)),
            body: d.cards.isEmpty
                ? const Center(child: Text('No cards yet. Tap + to add one,\nor import a CSV (question,answer).', textAlign: TextAlign.center))
                : ListView(children: [
                    for (final f in d.cards)
                      ListTile(
                        title: Text(f.q),
                        subtitle: Text('${f.a}  ·  ${status(f)}'),
                        onTap: () => cardDialog(ctx, f: f),
                        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { d.cards.remove(f); store.changed(); }),
                      ),
                  ]),
          );
        },
      );
}

class CardsPage extends StatefulWidget {
  const CardsPage({super.key});
  @override
  State<CardsPage> createState() => _CardsState();
}

class _CardsState extends State<CardsPage> {
  List<Flash> queue = [];
  bool cram = false; // practice-all mode: doesn't change the schedule
  bool? ok;
  int done = 0;
  final ans = TextEditingController();

  @override
  void initState() {
    super.initState();
    begin();
  }

  void begin({bool cramMode = false}) {
    cram = cramMode;
    ok = null;
    done = 0;
    ans.clear();
    queue = cramMode ? ([...store.deck.cards]..shuffle()) : store.deck.session(today());
  }

  void check() {
    final f = queue.first;
    final good = ans.text.trim().toLowerCase() == f.a.toLowerCase();
    setState(() => ok = good);
    if (good) {
      store.right++;
      store.run++;
      store.run >= 3 ? pet.react(Mood.excited, 'Streak of ${store.run}! Genius!') : pet.react(Mood.happy, 'Correct! Smart human!');
    } else {
      store.wrong++;
      store.run = 0;
      f.miss++;
      pet.react(Mood.sad, 'Oh no... it was "${f.a}"', ms: 3500);
    }
    store.changed();
  }

  /// g: 0 Again, 1 Hard, 2 Good, 3 Easy
  void grade(int g) {
    final f = queue.removeAt(0);
    if (!cram) {
      final mastered = f.review(g);
      store.addKp(const [0, 3, 5, 7][g] + (mastered ? 10 : 0));
      if (mastered) pet.react(Mood.excited, 'You mastered "${f.q}"! +10 KP', ms: 3000);
      if (g == 0) { queue.add(f); } else { done++; }
    } else {
      done++;
    }
    ok = null;
    ans.clear();
    if (queue.isEmpty) pet.react(Mood.excited, cram ? 'Practice complete!' : 'All reviews done for today!', ms: 3500);
    store.changed();
    setState(() {});
  }

  Future<void> newDeck() async {
    final n = await askText(context, 'New deck name');
    if (n == null || n.isEmpty) return;
    store.decks.add(Deck(n));
    store.deckIdx = store.decks.length - 1;
    setState(() => begin());
    store.changed();
    if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const DeckEditor()));
    if (mounted) setState(() => begin());
  }

  Future<void> doImport() async {
    final n = await importCsv();
    if (!mounted) return;
    setState(() => begin());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n > 0 ? 'Imported $n cards into "${store.deck.name}"' : 'No valid question,answer rows found')));
  }

  Widget gradeBtn(String label, int g, Flash f, Color c) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c, foregroundColor: ink, padding: const EdgeInsets.symmetric(vertical: 10)),
            onPressed: () => grade(g),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(fmtDays(f.calc(g)[0].toInt()), style: const TextStyle(fontSize: 11)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final d = store.deck;
          queue.removeWhere((c) => !d.cards.contains(c)); // card deleted in editor
          final f = queue.isEmpty ? null : queue.first;
          final totalNow = done + queue.length;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: store.deckIdx,
                  items: [for (var k = 0; k < store.decks.length; k++) DropdownMenuItem(value: k, child: Text('${store.decks[k].name} (${store.decks[k].cards.length})'))],
                  onChanged: (v) { store.deckIdx = v!; setState(() => begin()); store.changed(); },
                ),
              ),
              IconButton(tooltip: 'New deck', icon: const Icon(Icons.create_new_folder_outlined), onPressed: newDeck),
              IconButton(tooltip: 'Import CSV', icon: const Icon(Icons.upload_file), onPressed: doImport),
              IconButton(
                tooltip: 'Edit deck',
                icon: const Icon(Icons.edit_note),
                onPressed: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const DeckEditor()));
                  if (mounted) setState(() => begin());
                },
              ),
            ]),
            if (d.cards.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('This deck is empty. Import a CSV or tap the edit icon to add cards.', textAlign: TextAlign.center)))
            else if (f == null) ...[
              Container(
                margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(24), decoration: box(),
                child: Column(children: [
                  const Text('🎉', style: TextStyle(fontSize: 40)),
                  const SizedBox(height: 8),
                  Text(cram ? 'Practice finished!' : 'All caught up!', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ink)),
                  const SizedBox(height: 6),
                  Text(() {
                    final up = d.cards.where((c) => !c.isNew).map((c) => c.due).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
                    if (up == null) return 'Add cards to get started.';
                    final days = up - today();
                    return days <= 0 ? 'Cards are due now.' : 'Next review in ${fmtDays(days)}.';
                  }(), style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: butter, foregroundColor: ink),
                    onPressed: () => setState(() => begin(cramMode: true)),
                    child: const Text('Practice all cards anyway'),
                  ),
                  TextButton(onPressed: () => setState(() => begin()), child: const Text('Check for due cards')),
                ]),
              ),
            ] else ...[
              Row(children: [
                Text(cram ? 'Practice' : 'Due today', style: const TextStyle(color: Colors.black54)),
                const Spacer(),
                Text('${done + 1}/$totalNow', style: const TextStyle(color: Colors.black54)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: totalNow == 0 ? 0 : done / totalNow, minHeight: 6, color: sage, backgroundColor: Colors.black12),
              ),
              if (!cram && f.isNew) const Padding(padding: EdgeInsets.only(top: 8), child: Text('✨ New card', style: TextStyle(color: Colors.black54))),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(24), decoration: box(),
                child: Text(f.q, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink)),
              ),
              const SizedBox(height: 12),
              TextField(controller: ans, enabled: ok == null, onSubmitted: (_) => ok == null ? check() : null, decoration: field('Type your answer')),
              const SizedBox(height: 12),
              if (ok == null)
                FilledButton(style: FilledButton.styleFrom(backgroundColor: sage, foregroundColor: ink), onPressed: check, child: const Text('Check'))
              else ...[
                Text(ok! ? '✅ Correct!' : '❌ Answer: ${f.a}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                if (cram)
                  FilledButton(style: FilledButton.styleFrom(backgroundColor: butter, foregroundColor: ink), onPressed: () => grade(2), child: const Text('Next card'))
                else if (!ok!)
                  FilledButton(style: FilledButton.styleFrom(backgroundColor: butter, foregroundColor: ink), onPressed: () => grade(0), child: const Text('Again – show me soon'))
                else
                  Row(children: [
                    gradeBtn('Hard', 1, f, const Color(0xFFF2D6C8)),
                    gradeBtn('Good', 2, f, sage),
                    gradeBtn('Easy', 3, f, butter),
                  ]),
              ],
            ],
          ]);
        },
      );
}

// ── Review ──
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});
  @override
  State<ReviewPage> createState() => _ReviewState();
}

class _ReviewState extends State<ReviewPage> {
  String feel = 'Calm';
  final note = TextEditingController();
  static const feels = {
    'Calm': [Mood.relaxed, 'So peaceful...'],
    'Happy': [Mood.excited, 'Yay! Me too!'],
    'Tired': [Mood.sleepy, 'Rest up, you earned it.'],
    'Sad': [Mood.sad, "I'm here for you."],
    'Stressed': [Mood.startled, 'Deep breath. We got this.'],
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final missed = [for (final d in store.decks) for (final c in d.cards) if (c.miss > 0) MapEntry(d.name, c)];
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Text('How are you feeling after that session?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Wrap(spacing: 8, children: [
              for (final k in feels.keys)
                ChoiceChip(
                  label: Text(k), selected: feel == k,
                  onSelected: (_) { setState(() => feel = k); pet.react(feels[k]![0] as Mood, feels[k]![1] as String); },
                ),
            ]),
            const SizedBox(height: 8),
            TextField(controller: note, maxLines: 2, decoration: field("One thing I'm grateful for today...")),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: sage, foregroundColor: ink),
              onPressed: () {
                if (note.text.isEmpty) return;
                store.entries.insert(0, Entry(feel, note.text, Store.key(DateTime.now())));
                note.clear();
                store.changed();
                pet.react(Mood.happy, 'Great job studying! Proud of you!');
              },
              child: const Text('Save entry'),
            ),
            const SizedBox(height: 16),
            const Text('Cards to review (missed)', style: TextStyle(fontWeight: FontWeight.w600)),
            if (missed.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing missed yet 🎉')),
            for (final m in missed)
              Container(margin: const EdgeInsets.only(top: 8), decoration: box(), child: ListTile(title: Text(m.value.q), subtitle: Text('${m.key} · Answer: ${m.value.a}'), trailing: Text('✗ ${m.value.miss}'))),
            const SizedBox(height: 16),
            const Text('Previous entries', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final e in store.entries)
              Container(margin: const EdgeInsets.only(top: 8), decoration: box(), child: ListTile(title: Text(e.text), subtitle: Text(e.date), trailing: Text(e.mood))),
          ]);
        },
      );
}

// ── Analytics ──
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  static const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  Widget tile(String a, String b) => Container(
        width: 150, padding: const EdgeInsets.all(14), decoration: box(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(b, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ]),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final days = [for (var k = 6; k >= 0; k--) DateTime.now().subtract(Duration(days: k))];
          final mins = [for (final d in days) store.focus[Store.key(d)] ?? 0.0];
          final peak = max(mins.reduce(max), 30.0);
          final total = store.focus.values.fold<double>(0, (a, b) => a + b).round();
          final n = store.right + store.wrong;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Container(
              padding: const EdgeInsets.all(16), decoration: box(),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Focus minutes (last 7 days)', style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(
                  height: 150,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                          Text('${mins[d].round()}', style: const TextStyle(fontSize: 10)),
                          Container(
                            height: (mins[d] / peak * 100).clamp(2.0, 100.0),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(color: d == 6 ? sage : butter, borderRadius: BorderRadius.circular(6)),
                          ),
                          Text(wd[days[d].weekday - 1], style: const TextStyle(fontSize: 11)),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              tile('Pet stage', '${lvIcon[store.level]} ${lvName[store.level]}'),
              tile('Knowledge points', '${store.kp} KP'),
              tile('Current streak', '${store.streak} days 🔥'),
              tile('Total focus', '${total ~/ 60}h ${total % 60}m'),
              tile('Sessions', '${store.sessions}'),
              tile('Quiz accuracy', n == 0 ? '—' : '${(store.right * 100 / n).round()}%'),
              tile('Cards due', '${store.dueCount}'),
              tile('Mastered cards', '${store.masteredCount}'),
            ]),
          ]);
        },
      );
}