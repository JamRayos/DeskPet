import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'ble_pet.dart';

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

    // Send the same mood to the physical desk pet over Bluetooth.
    blePet.sendMood(m.name);

    notifyListeners();
  }
}

final pet = Pet();

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
                  valueListenable: blePet.connected,
                  builder: (_, on, __) => Text(
                    '${on ? "● BLE" : "○ not connected"}  → ${pet.log.first}',
                    style: TextStyle(color: on ? cyan : Colors.redAccent, fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      );
}