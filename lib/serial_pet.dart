import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialPet {
  final connected = ValueNotifier<bool>(false);
  SerialPort? _port;
  SerialPortReader? _reader;

  bool get isConnected => _port?.isOpen ?? false;
  List<String> get availablePorts => SerialPort.availablePorts;

  Future<void> connect(String name, {int baud = 9600}) async {
    await disconnect();
    final p = SerialPort(name);
    if (!p.openReadWrite()) {
      final err = SerialPort.lastError;
      p.dispose();
      throw Exception('Cannot open $name ($err). Is the Serial Monitor closed?');
    }
    final cfg = SerialPortConfig()
      ..baudRate = baud            // must match Serial.begin(9600)
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);
    p.config = cfg;
    cfg.dispose();

    _port = p;
    _reader = SerialPortReader(p);
    _reader!.stream.listen(
      (d) => print('Arduino says: ${utf8.decode(d, allowMalformed: true).trim()}'),
    );
    print('Serial open: $name @ $baud');
    connected.value = true;
  }

  void sendMood(String mood) {
    final p = _port;
    if (p == null || !p.isOpen) {
      print('sendMood SKIPPED (not connected): $mood');
      return;
    }
    final msg = 'MOOD:${mood.toUpperCase()}\n';       // newline is required
    final n = p.write(Uint8List.fromList(utf8.encode(msg)));
    print('Sent "${msg.trim()}" ($n bytes)');
  }

  Future<void> disconnect() async {
    connected.value = false;
    _reader?.close();
    _reader = null;
    final p = _port;
    _port = null;
    if (p != null) {
      if (p.isOpen) p.close();
      p.dispose();
    }
  }
}

final serialPet = SerialPet();