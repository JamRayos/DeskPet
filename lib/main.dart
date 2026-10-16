import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble_pet.dart';
import 'pet.dart'; // colors, rnd, Mood, pet, PetPanel (your existing PET + EYES code)

// ───────────────────────── MODELS ─────────────────────────
typedef J = Map<String, dynamic>;
List<T> _list<T>(dynamic x, T Function(J) f) =>
    ((x ?? []) as List).map((e) => f(Map<String, dynamic>.from(e))).toList();

class Task {
  String title; bool done;
  Task(this.title, [this.done = false]);
  J toJson() => {'t': title, 'd': done};
  factory Task.fromJson(J j) => Task(j['t'], j['d'] ?? false);
}

class Flash {
  String q, a; int miss;
  Flash(this.q, this.a, [this.miss = 0]);
  J toJson() => {'q': q, 'a': a, 'm': miss};
  factory Flash.fromJson(J j) => Flash(j['q'], j['a'], j['m'] ?? 0);
}

class Deck {
  String name; List<Flash> cards;
  Deck(this.name, [List<Flash>? c]) : cards = c ?? [];
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

// ───────────────────────── STORE (saved to device) ─────────────────────────
class Store extends ChangeNotifier {
  List<Task> tasks = [];
  List<Deck> decks = [];
  List<Entry> entries = [];
  List<Preset> presets = [];
  Map<String, double> focus = {}; 
  int sessions = 0, right = 0, wrong = 0, kp = 0, run = 0, presetIdx = 0, deckIdx = 0;
  Timer? _debounce;

  Deck get deck => decks[deckIdx];
  Preset get preset => presets[presetIdx];

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
      'focus': focus, 'sessions': sessions, 'right': right, 'wrong': wrong,
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

// ───────────────────────── POMODORO ─────────────────────────
class Pomo extends ChangeNotifier {
  bool focus = true, running = false, fast = false, half = false;
  int left = 1500, total = 1500, _since = 0;
  DateTime? _last;
  Timer? _t;

  void reset() {
    _t?.cancel();
    if (running) pet.setBase(Mood.idle);
    running = false; focus = true; half = false;
    left = total = store.preset.focus * 60;
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
    pet.setBase(focus ? Mood.focused : Mood.relaxed);
    pet.react(Mood.happy, focus ? "Let's focus together!" : 'Break time. Stretch!', ms: 3000);
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _step());
    notifyListeners();
  }

  void pause() {
    running = false;
    _t?.cancel();
    pet.setBase(Mood.idle);
    pet.react(Mood.sad, "Paused... I'll wait for you!");
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
      store.kp += 25;
      pet.react(Mood.excited, 'Session complete! +25 KP', ms: 4000);
      focus = false;
      left = total = store.preset.brk * 60;
      pet.setBase(Mood.relaxed);
    } else {
      focus = true;
      left = total = store.preset.focus * 60;
      pet.setBase(Mood.focused);
      pet.react(Mood.startled, 'Break over! Back to it!');
    }
    store.changed();
    notifyListeners();
  }
}

final pomo = Pomo();

// ───────────────────────── APP ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  pomo.reset();
  runApp(const DeskPetApp());
  blePet.init(); // auto-reconnects to the saved pet
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

BoxDecoration box() => BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20));
InputDecoration field(String hint) => InputDecoration(
    hintText: hint, filled: true, fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none));
String mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

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
              onChanged: (v) { pomo.fast = v; pomo.notifyListeners(); },
            ),
            const Divider(height: 32),
            const BluetoothPanel(),
          ],
        ),
      );
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
                    store.kp += 10;
                    final all = store.tasks.every((x) => x.done);
                    pet.react(all ? Mood.excited : Mood.happy, all ? 'ALL tasks done! Amazing!' : 'Task done! +10 KP');
                  }
                  store.changed();
                },
              ),
            ),
        ]),
      );
}

// ── Flashcards with decks ──
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
                ? const Center(child: Text('No cards yet. Tap + to add one.'))
                : ListView(children: [
                    for (final f in d.cards)
                      ListTile(
                        title: Text(f.q),
                        subtitle: Text(f.a),
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
  int i = 0;
  bool? ok;
  final ans = TextEditingController();

  void resetStudy() { i = 0; ok = null; ans.clear(); }

  void check() {
    final f = store.deck.cards[i];
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

  void next() => setState(() { i = (i + 1) % store.deck.cards.length; ok = null; ans.clear(); });

  Future<void> newDeck() async {
    final n = await askText(context, 'New deck name');
    if (n == null || n.isEmpty) return;
    store.decks.add(Deck(n));
    store.deckIdx = store.decks.length - 1;
    setState(resetStudy);
    store.changed();
    if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const DeckEditor()));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final d = store.deck;
          if (i >= d.cards.length) i = 0;
          final f = d.cards.isEmpty ? null : d.cards[i];
          return ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: store.deckIdx,
                  items: [for (var k = 0; k < store.decks.length; k++) DropdownMenuItem(value: k, child: Text('${store.decks[k].name} (${store.decks[k].cards.length})'))],
                  onChanged: (v) { store.deckIdx = v!; setState(resetStudy); store.changed(); },
                ),
              ),
              IconButton(tooltip: 'New deck', icon: const Icon(Icons.create_new_folder_outlined), onPressed: newDeck),
              IconButton(tooltip: 'Edit deck', icon: const Icon(Icons.edit_note), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DeckEditor()))),
            ]),
            if (f == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('This deck is empty. Tap the edit icon to add cards.')))
            else ...[
              Text('Card ${i + 1}/${d.cards.length}', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(24), decoration: box(),
                child: Text(f.q, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink)),
              ),
              const SizedBox(height: 12),
              TextField(controller: ans, enabled: ok == null, onSubmitted: (_) => check(), decoration: field('Type your answer')),
              const SizedBox(height: 12),
              if (ok == null)
                FilledButton(style: FilledButton.styleFrom(backgroundColor: sage, foregroundColor: ink), onPressed: check, child: const Text('Check'))
              else ...[
                Text(ok! ? '✅ Correct!' : '❌ Answer: ${f.a}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                FilledButton(style: FilledButton.styleFrom(backgroundColor: butter, foregroundColor: ink), onPressed: next, child: const Text('Next card')),
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
              tile('Current streak', '${store.streak} days 🔥'),
              tile('Total focus', '${total ~/ 60}h ${total % 60}m'),
              tile('Sessions', '${store.sessions}'),
              tile('Quiz accuracy', n == 0 ? '—' : '${(store.right * 100 / n).round()}%'),
              tile('Knowledge points', '${store.kp} KP'),
            ]),
          ]);
        },
      );
}