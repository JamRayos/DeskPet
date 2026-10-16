import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Must match the ESP32 sketch (Nordic UART style UUIDs).
final serviceUuid = Guid('6e400001-b5a3-f393-a0a9-e50e24dcca9e');
final rxUuid = Guid('6e400002-b5a3-f393-a0a9-e50e24dcca9e'); // app -> pet (write)

class BlePet {
  final connected = ValueNotifier<bool>(false);
  final scanning = ValueNotifier<bool>(false);
  final status = ValueNotifier<String>('Not connected');
  final results = ValueNotifier<List<ScanResult>>([]);

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _rx;
  StreamSubscription? _connSub;
  Timer? _beat;
  String _last = 'idle';
  bool _manual = false;

  /// Call once at startup. Reconnects to the last paired pet automatically.
  Future<void> init() async {
    FlutterBluePlus.scanResults.listen((r) => results.value = r);
    FlutterBluePlus.isScanning.listen((s) => scanning.value = s);

    // The firmware drops back to idle after 2 min without a command,
    // so resend the current mood as a heartbeat.
    _beat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (connected.value) sendMood(_last);
    });

    final p = await SharedPreferences.getInstance();
    final id = p.getString('pet_id');
    if (id != null) {
      status.value = 'Looking for saved pet…';
      _attach(BluetoothDevice.fromId(id));
    }
  }

  Future<void> scan() async {
    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      status.value = 'Scanning…';
      await FlutterBluePlus.startScan(
          withServices: [serviceUuid], timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
      if (!connected.value && results.value.isEmpty) {
        status.value = 'No pet found. Is it powered on?';
      }
    } catch (e) {
      status.value = 'Scan failed: $e';
    }
  }

  Future<void> connect(BluetoothDevice d) async {
    await FlutterBluePlus.stopScan();
    _manual = false;
    final p = await SharedPreferences.getInstance();
    await p.setString('pet_id', d.remoteId.str);
    status.value = 'Connecting…';
    _attach(d);
  }

  void _attach(BluetoothDevice d) {
    _dev = d;
    _connSub?.cancel();
    _connSub = d.connectionState.listen((s) async {
      if (s == BluetoothConnectionState.connected) {
        await _setup(d);
      } else {
        _rx = null;
        connected.value = false;
        if (!_manual) status.value = 'Waiting for pet…';
      }
    });
    // autoConnect: Android keeps retrying whenever the pet is back in range.
    d.connect(autoConnect: true, mtu: null).catchError((e) {
      status.value = 'Connect failed: $e';
    });
  }

  Future<void> _setup(BluetoothDevice d) async {
    try {
      status.value = 'Setting up…';
      for (final s in await d.discoverServices()) {
        if (s.uuid != serviceUuid) continue;
        for (final c in s.characteristics) {
          if (c.uuid == rxUuid) _rx = c;
        }
      }
      connected.value = _rx != null;
      status.value = _rx != null ? 'Connected to Desk Pet' : 'Pet service not found';
      if (_rx != null) sendMood(_last);
    } catch (e) {
      status.value = 'Setup failed: $e';
    }
  }

  Future<void> sendMood(String mood) async {
    _last = mood;
    final rx = _rx;
    if (rx == null) return;
    try {
      await rx.write(utf8.encode('MOOD:${mood.toUpperCase()}'),
          withoutResponse: rx.properties.writeWithoutResponse);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _manual = true;
    final p = await SharedPreferences.getInstance();
    await p.remove('pet_id');
    await _connSub?.cancel();
    await _dev?.disconnect();
    _rx = null;
    connected.value = false;
    status.value = 'Not connected';
  }
}

final blePet = BlePet();