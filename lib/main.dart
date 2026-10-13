import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'serial_pet.dart';

const cream = Color(0xFFFAF7F2), sage = Color(0xFFA6C1AB), butter = Color(0xFFF7DE9C);
const ink = Color(0xFF2B2D42), cyan = Color(0xFF00E5FF);
final rnd = Random();

// ───────────────────────── PET ─────────────────────────
enum Mood { idle, focused, happy, excited, curious, startled, sad, annoyed, sleepy, sleeping, relaxed }

class Look {
  final double w, h, r, dx, dy, tired, angry, happy;
  const Look(this.w, this.h, {this.r = 12, this.dx = 0, this.dy = 0, this.tired = 0, this.angry = 0, this.happy = 0});
  static Look lerp(Look a, Look b, double t) {
    double l(double x, double y) => x + (y - x) * t;
    return Look(l(a.w, b.w), l(a.h, b.h), r: l(a.r, b.r), dx: l(a.dx, b.dx), dy: l(a.dy, b.dy),
        tired: l(a.tired, b.tired), angry: l(a.angry, b.angry), happy: l(a.happy, b.happy));
  }
}

const looks = {
  Mood.idle: Look(55, 65),
  Mood.focused: Look(58, 48, angry: .25),
  Mood.happy: Look(55, 62, happy: .4),
  Mood.excited: Look(62, 72, happy: .45),
  Mood.curious: Look(60, 72),
  Mood.startled: Look(68, 84, r: 18, dy: -14),
  Mood.sad: Look(55, 56, tired: .6, dy: 8),
  Mood.annoyed: Look(58, 50, angry: .6),
  Mood.sleepy: Look(55, 36, tired: .5, dy: 10),
  Mood.sleeping: Look(55, 4, r: 2, dy: 12),
  Mood.relaxed: Look(55, 42, happy: .55, dy: 4),
};

class Pet extends ChangeNotifier {
  Mood base = Mood.idle, mood = Mood.idle;
  String say = "Let's study together!";
  final log = <String>[];
  Timer? _t;

  void setBase(Mood m) {
    base = m;
    if (_t == null || !_t!.isActive) _apply(m, null);
  }

  void react(Mood m, String s, {int ms = 2500}) {
    _t?.cancel();
    _apply(m, s);
    _t = Timer(Duration(milliseconds: ms), () => _apply(base, null));
  }

  void _apply(Mood m, String? s) {
  mood = m;

  if (s != null) say = s;

  log.insert(0, 'MOOD:${m.name.toUpperCase()}');
  if (log.length > 6) log.removeLast();

  // Send the same mood to the physical desk pet.
  serialPet.sendMood(m.name);

  notifyListeners();
}
}

final pet = Pet();

// ───────────────────────── DATA ─────────────────────────
class Task { String title; bool done = false; Task(this.title); }
class Flash { String q, a; int miss = 0; Flash(this.q, this.a); }
class Entry { String mood, text; Entry(this.mood, this.text); }

class Store extends ChangeNotifier {
  final tasks = [Task('Solve 5 calculus problems'), Task('Write Shakespeare essay outline')];
  final cards = [Flash('Derivative of x²?', '2x'), Flash('Powerhouse of the cell?', 'mitochondria'), Flash('Capital of the Philippines?', 'manila')];
  final entries = <Entry>[];
  final focusMin = <double>[40, 55, 30, 70, 45, 20, 10]; // Mon..Sun
  int sessions = 28, streak = 7, right = 0, wrong = 0, kp = 342, run = 0;
  void changed() => notifyListeners();
}

final store = Store();

class Pomo extends ChangeNotifier {
  bool focus = true, running = false, fast = false, half = false;
  int left = 1500, total = 1500, _tick = 0;
  Timer? _t;

  void toggle() => running ? pause() : start();

  void start() {
    running = true;
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

  void _step() {
    left -= fast ? 60 : 1;
    _tick++;
    if (left <= 0) return _done();
    if (focus && !half && left * 2 <= total) {
      half = true;
      pet.react(Mood.excited, 'Halfway there! Keep going!');
    } else if (_tick % (fast ? 4 : 20) == 0) {
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
      store.focusMin[DateTime.now().weekday - 1] += total / 60;
      store.sessions++;
      store.kp += 25;
      pet.react(Mood.excited, 'Session complete! +25 KP', ms: 4000);
      focus = false;
      left = total = 300;
      pet.setBase(Mood.relaxed);
    } else {
      focus = true;
      left = total = 1500;
      pet.setBase(Mood.focused);
      pet.react(Mood.startled, 'Break over! Back to it!');
    }
    store.changed();
    notifyListeners();
  }
}

final pomo = Pomo();

// ───────────────────────── EYES ─────────────────────────
class PetView extends StatefulWidget {
  const PetView({super.key});
  @override
  State<PetView> createState() => _PetViewState();
}

class _PetViewState extends State<PetView> with SingleTickerProviderStateMixin {
  late final Ticker _tk;
  Look cur = looks[Mood.idle]!;
  Duration last = Duration.zero;
  double t = 0, blinkT = -1, nextBlink = 2, nextGlance = 3, gx = 0, gy = 0, tgx = 0, tgy = 0;
  Mood _prev = Mood.idle;

  @override
  void initState() {
    super.initState();
    _tk = createTicker(_tick)..start();
  }

  void _tick(Duration el) {
    final dt = (el - last).inMicroseconds / 1e6;
    last = el;
    t = el.inMicroseconds / 1e6;
    final m = pet.mood;

    if (m != _prev) {                       // mood just changed
      _prev = m;
      if (m == Mood.curious) {              // look to a side now, back to center after ~0.9 s
        tgx = (rnd.nextBool() ? 1 : -1) * 18;
        tgy = 0;
        nextGlance = t + .9;
      }
    }

    cur = Look.lerp(cur, looks[m]!, 1 - pow(0.001, dt).toDouble()); // smooth tween
    if (t >= nextBlink && m != Mood.sleeping) {
      blinkT = t;
      nextBlink = t + 2 + rnd.nextDouble() * 3;
    }
    final calm = m == Mood.idle || m == Mood.focused || m == Mood.curious || m == Mood.relaxed;
    if (!calm) {
      tgx = 0; tgy = 0;
    } else if (t >= nextGlance) {
      if (tgx != 0 || tgy != 0) {
        tgx = 0; tgy = 0;
        nextGlance = t + 3 + rnd.nextDouble() * 5;      // mostly centered
      } else if (m == Mood.curious || rnd.nextInt(3) == 0) {
        tgx = (rnd.nextBool() ? 1 : -1) * 18;
        tgy = rnd.nextBool() ? -10 : 0;
        nextGlance = t + .9 + rnd.nextDouble();
      } else {
        nextGlance = t + 2;
      }
    }
    gx += (tgx - gx) * .12;
    gy += (tgy - gy) * .12;
    setState(() {});
  }

  @override
  void dispose() {
    _tk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = pet.mood;
    final blink = (blinkT >= 0 && t - blinkT < .18) ? sin(pi * (t - blinkT) / .18) : 0.0;
    final bounce = m == Mood.excited ? sin(t * 16) * 5 : 0.0;
    final shake = m == Mood.annoyed ? sin(t * 45) * 2.5 : 0.0;
    return CustomPaint(painter: _EyePainter(cur, gx + shake, gy + bounce, blink), size: Size.infinite);
  }
}

class _EyePainter extends CustomPainter {
  final Look l;
  final double dx, dy, blink;
  _EyePainter(this.l, this.dx, this.dy, this.blink);

  @override
  void paint(Canvas c, Size s) {
    final k = s.height / 150;
    final h = (l.h * (1 - blink) + 3 * blink) * k, w = l.w * k, gap = 20 * k;
    final cx = s.width / 2 + dx * k, cy = s.height / 2 + (l.dy + dy) * k;
    final p = Paint()..color = cyan, bg = Paint()..color = Colors.black;
    for (var i = 0; i < 2; i++) {
      final x = cx - gap / 2 - w + i * (w + gap), y = cy - h / 2, left = i == 0;
      final rr = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(min(l.r * k, h / 2)));
      c.save();
      c.clipRRect(rr);
      c.drawRRect(rr, p);
      if (l.tired > 0) c.drawPath(Path()..moveTo(x, y)..lineTo(x + w, y)..lineTo(left ? x : x + w, y + l.tired * h)..close(), bg);
      if (l.angry > 0) c.drawPath(Path()..moveTo(x, y)..lineTo(x + w, y)..lineTo(left ? x + w : x, y + l.angry * h)..close(), bg);
      if (l.happy > 0) c.drawRRect(RRect.fromLTRBR(x - 4, y + h * (1 - l.happy), x + w + 4, y + h + 40, Radius.circular(w / 2)), bg);
      c.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class PetPanel extends StatelessWidget {
  const PetPanel({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pet,
        builder: (_, __) => Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(28), border: Border.all(color: sage, width: 4)),
          child: Column(children: [
            const SizedBox(height: 150, width: double.infinity, child: PetView()),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(children: [
                Expanded(child: Text(pet.say, style: const TextStyle(color: butter, fontWeight: FontWeight.w600))),
                ValueListenableBuilder<bool>(
                  valueListenable: serialPet.connected,
                  builder: (_, on, __) => Text('${on ? "● USB" : "○ not connected"}  → ${pet.log.first}',
                                                 style: TextStyle(color: on ? cyan : Colors.redAccent, fontFamily: 'monospace', fontSize: 11),
  ),
),
              ]),
            ),
          ]),
        ),
      );
}

// ───────────────────────── APP ─────────────────────────
void main() => runApp(const DeskPetApp());

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
            Expanded(
              child: IndexedStack(index: i, children: const [TimerPage(), TasksPage(), CardsPage(), ReviewPage(), StatsPage()]),
            ),
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


// ── Timer ──
class TimerPage extends StatelessWidget {
  const TimerPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pomo,
        builder: (_, __) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Text(
                pomo.focus ? 'Focus Session' : 'Break',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Existing timer display
            Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: pomo.left / pomo.total,
                        strokeWidth: 12,
                        color: pomo.focus ? sage : butter,
                        backgroundColor: Colors.black12,
                      ),
                    ),
                    Text(
                      mmss(pomo.left),
                      style: const TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.bold,
                        color: ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Existing Start/Pause button
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: sage,
                foregroundColor: ink,
                padding: const EdgeInsets.all(16),
              ),
              onPressed: pomo.toggle,
              icon: Icon(
                pomo.running ? Icons.pause : Icons.play_arrow,
              ),
              label: Text(
                pomo.running
                    ? 'Pause'
                    : 'Start ${pomo.focus ? "25m Pomodoro" : "5m Break"}',
              ),
            ),

            // Existing Demo Speed switch
            SwitchListTile(
              title: const Text(
                'Demo speed (×60) – see all reactions fast',
              ),
              value: pomo.fast,
              onChanged: (v) {
                pomo.fast = v;
                pomo.notifyListeners();
              },
            ),

            // NEW: Arduino connection section
            const Divider(height: 32),

            const ArduinoConnectionPanel(),
          ],
        ),
      );
}

class ArduinoConnectionPanel extends StatefulWidget {
  const ArduinoConnectionPanel({super.key});

  @override
  State<ArduinoConnectionPanel> createState() =>
      _ArduinoConnectionPanelState();
}

class _ArduinoConnectionPanelState
    extends State<ArduinoConnectionPanel> {
  List<String> ports = [];
  String? selectedPort;
  bool connected = false;
  String status = 'Not connected';

  @override
  void initState() {
    super.initState();
    refreshPorts();
  }

  void refreshPorts() {
    // Get available serial ports from your serial_pet.dart file.
    final available = serialPet.availablePorts;

    setState(() {
      ports = available;
      if (selectedPort == null ||
          !ports.contains(selectedPort)) {
        selectedPort = ports.isNotEmpty ? ports.first : null;
      }
    });
  }

  Future<void> connectArduino() async {
    if (selectedPort == null) {
      setState(() => status = 'No COM port found');
      return;
    }

    try {
      await serialPet.connect(selectedPort!);

      await Future.delayed(const Duration(seconds: 2));
      serialPet.sendMood(pet.mood.name);

      if (!mounted) return;

      setState(() {
        connected = true;
        status = 'Connected to $selectedPort';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connected = false;
        status = 'Connection failed: $e';
      });
    }
  }

  Future<void> disconnectArduino() async {
    await serialPet.disconnect();

    if (!mounted) return;

    setState(() {
      connected = false;
      status = 'Not connected';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Arduino Connection',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            DropdownButtonFormField<String>(
              value: selectedPort,
              decoration: const InputDecoration(
                labelText: 'COM Port',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Select Arduino port'),
              items: ports.map((port) {
                return DropdownMenuItem(
                  value: port,
                  child: Text(port),
                );
              }).toList(),
              onChanged: connected
                  ? null
                  : (value) {
                      setState(() => selectedPort = value);
                    },
            ),

            const SizedBox(height: 12),

            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: connected ? null : refreshPorts,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),

                FilledButton.icon(
                  onPressed: connected
                      ? disconnectArduino
                      : connectArduino,
                  icon: Icon(
                    connected ? Icons.link_off : Icons.usb,
                  ),
                  label: Text(
                    connected ? 'Disconnect' : 'Connect',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Text('Status: $status'),
          ],
        ),
      ),
    );
  }
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

// ── Flashcards ──
class CardsPage extends StatefulWidget {
  const CardsPage({super.key});
  @override
  State<CardsPage> createState() => _CardsState();
}

class _CardsState extends State<CardsPage> {
  int i = 0;
  bool? ok;
  final ans = TextEditingController();

  void check() {
    final f = store.cards[i];
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

  void next() => setState(() { i = (i + 1) % store.cards.length; ok = null; ans.clear(); });

  void addCard() {
    final q = TextEditingController(), a = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New flashcard'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: q, decoration: const InputDecoration(labelText: 'Question')),
          TextField(controller: a, decoration: const InputDecoration(labelText: 'Answer')),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              if (q.text.isNotEmpty && a.text.isNotEmpty) { store.cards.add(Flash(q.text, a.text)); store.changed(); }
              Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = store.cards[i];
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Card ${i + 1}/${store.cards.length}', style: const TextStyle(color: Colors.black54)),
        TextButton.icon(onPressed: addCard, icon: const Icon(Icons.add), label: const Text('Add card')),
      ]),
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
    ]);
  }
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
          final missed = store.cards.where((c) => c.miss > 0).toList();
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
            TextField(controller: note, maxLines: 2, decoration: field('One thing I\'m grateful for today...')),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: sage, foregroundColor: ink),
              onPressed: () {
                if (note.text.isEmpty) return;
                store.entries.insert(0, Entry(feel, note.text));
                note.clear();
                store.changed();
                pet.react(Mood.happy, 'Great job studying! Proud of you!');
              },
              child: const Text('Save entry'),
            ),
            const SizedBox(height: 16),
            const Text('Cards to review (missed)', style: TextStyle(fontWeight: FontWeight.w600)),
            if (missed.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing missed yet 🎉')),
            for (final c in missed)
              Container(margin: const EdgeInsets.only(top: 8), decoration: box(), child: ListTile(title: Text(c.q), subtitle: Text('Answer: ${c.a}'), trailing: Text('✗ ${c.miss}'))),
            const SizedBox(height: 16),
            const Text('Previous entries', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final e in store.entries)
              Container(margin: const EdgeInsets.only(top: 8), decoration: box(), child: ListTile(title: Text(e.text), trailing: Text(e.mood))),
          ]);
        },
      );
}

// ── Analytics ──
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});
  static const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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
          final today = DateTime.now().weekday - 1;
          final total = store.focusMin.fold<double>(0, (a, b) => a + b).round();
          final n = store.right + store.wrong;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Container(
              padding: const EdgeInsets.all(16), decoration: box(),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Focus minutes per day', style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(
                  height: 140,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                          Text('${store.focusMin[d].round()}', style: const TextStyle(fontSize: 10)),
                          Container(height: store.focusMin[d].clamp(2, 100).toDouble(), margin: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(color: d == today ? sage : butter, borderRadius: BorderRadius.circular(6))),
                          Text(days[d], style: const TextStyle(fontSize: 11)),
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