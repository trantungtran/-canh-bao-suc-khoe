// =====================================================================
//  HE THONG CANH BAO SOM SUC KHOE - app Android v2
//
//  Giao dien + AI phan tich: dung lai nguyen web app (assets/index.html),
//  nen app va ban web luon giong nhau.
//  Phan Flutter chi lo Bluetooth (BLE) vi WebView tren Android khong co
//  Web Bluetooth:
//    trang web --NativeBle.postMessage({cmd})--> Flutter --BLE--> HEALTH_BW16
//    HEALTH_BW16 --BLE notify--> Flutter --window.onNativeBle({type})--> trang web
// =====================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

// Nordic UART Service (giong firmware)
final Guid kSvc = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
final Guid kRx = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // app -> thiet bi
final Guid kTx = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // thiet bi -> app
const String kNamePrefix = 'HEALTH';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0A1120),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A1120),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const HealthApp());
}

class HealthApp extends StatelessWidget {
  const HealthApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cảnh báo sức khỏe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xFF0A1120)),
        home: const WebShell(),
      );
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  late final WebViewController _web;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _rxChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  bool _busy = false, _connected = false, _manualStop = false;

  // Du lieu BLE gom lai roi day vao trang web moi 40 ms (thiet bi gui ~125 goi/giay)
  final StringBuffer _inBuf = StringBuffer();
  Timer? _flushTimer;

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.setLogLevel(LogLevel.warning);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0A1120))
      ..addJavaScriptChannel('NativeBle', onMessageReceived: (m) => _onJs(m.message))
      ..loadFlutterAsset('assets/index.html');
    _flushTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _flush());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _cleanup();
    _dev?.disconnect();
    super.dispose();
  }

  // ---------------- giao tiep voi trang web ----------------
  void _emit(Map<String, dynamic> ev) {
    _web.runJavaScript('window.onNativeBle && window.onNativeBle(${jsonEncode(ev)});');
  }

  void _flush() {
    if (_inBuf.isEmpty) return;
    final text = _inBuf.toString();
    _inBuf.clear();
    _emit({'type': 'data', 'text': text});
  }

  void _onJs(String raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['cmd']) {
      case 'connect':
        _connect();
        break;
      case 'disconnect':
        _disconnect();
        break;
      case 'write':
        _write((m['data'] ?? '').toString());
        break;
      case 'notify':
        _alert();
        break;
    }
  }

  // ---------------- Bluetooth ----------------
  Future<void> _connect() async {
    if (_busy || _connected) return;
    _busy = true;
    try {
      if (!await FlutterBluePlus.isSupported) {
        _fail('Điện thoại này không hỗ trợ Bluetooth năng lượng thấp (BLE).');
        return;
      }
      var st = await FlutterBluePlus.adapterState.first;
      if (st != BluetoothAdapterState.on) {
        _emit({'type': 'busy', 'msg': 'Đang bật Bluetooth...'});
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
        try {
          await FlutterBluePlus.adapterState
              .where((s) => s == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 8));
        } on TimeoutException {
          _fail('Bluetooth đang tắt. Hãy bật Bluetooth rồi bấm Kết nối lại.');
          return;
        }
      }

      // 1. Tim thiet bi
      _emit({'type': 'busy', 'msg': 'Đang tìm HEALTH_BW16...'});
      final found = Completer<BluetoothDevice?>();
      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
          final ok = name.toUpperCase().startsWith(kNamePrefix) || r.advertisementData.serviceUuids.contains(kSvc);
          if (ok && !found.isCompleted) found.complete(r.device);
        }
      });
      try {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      } catch (e) {
        await scanSub.cancel();
        _fail('Chưa được cấp quyền Bluetooth. Vào Cài đặt > Ứng dụng > Cảnh báo sức khỏe > Quyền, '
            'cho phép "Thiết bị ở gần" (Android 12 trở lên) hoặc "Vị trí" (Android 11 trở xuống).');
        return;
      }
      final dev = await found.future.timeout(const Duration(seconds: 11), onTimeout: () => null);
      await scanSub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (dev == null) {
        _fail('Không tìm thấy HEALTH_BW16. Kiểm tra: đã lắp ăng-ten, thiết bị đang bật '
            '(nhấn RST trên BW16), điện thoại để gần. Android 11 trở xuống cần bật thêm Vị trí (GPS).');
        return;
      }

      // 2. Ket noi va tim dich vu UART
      _emit({'type': 'busy', 'msg': 'Đang kết nối...'});
      await dev.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      _dev = dev;
      final services = await dev.discoverServices();
      BluetoothCharacteristic? tx, rx;
      for (final s in services) {
        if (s.uuid != kSvc) continue;
        for (final c in s.characteristics) {
          if (c.uuid == kTx) tx = c;
          if (c.uuid == kRx) rx = c;
        }
      }
      if (tx == null) {
        await dev.disconnect();
        _dev = null;
        _fail('Thiết bị vừa tìm thấy chưa chạy firmware HEALTH_BW16. Nạp firmware rồi thử lại.');
        return;
      }
      _rxChar = rx;
      _notifySub = tx.onValueReceived.listen((v) => _inBuf.write(String.fromCharCodes(v)));
      await tx.setNotifyValue(true);

      _manualStop = false;
      _stateSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _connected) {
          _connected = false;
          _cleanup();
          _flush();
          _emit({
            'type': 'disconnected',
            'msg': _manualStop ? 'Đã ngắt kết nối · bấm Kết nối để đo tiếp' : 'Mất kết nối với thiết bị · bấm Kết nối để thử lại',
          });
        }
      });
      _connected = true;
      _emit({'type': 'connected', 'name': dev.platformName});
    } catch (e) {
      try {
        await _dev?.disconnect();
      } catch (_) {}
      _dev = null;
      _cleanup();
      _fail('Không kết nối được (${e.toString().split('\n').first}). Nhấn RST trên BW16, chờ 3 giây rồi thử lại.');
    } finally {
      _busy = false;
    }
  }

  void _fail(String msg) => _emit({'type': 'disconnected', 'msg': msg});

  Future<void> _disconnect() async {
    _manualStop = true;
    try {
      await _dev?.disconnect();
    } catch (_) {}
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _rxChar = null;
  }

  // Ghi lenh (USER:..., START, STOP), cat thanh goi 20 byte
  Future<void> _write(String text) async {
    final c = _rxChar;
    if (c == null || !_connected) return;
    final bytes = utf8.encode(text);
    final noResp = c.properties.writeWithoutResponse;
    try {
      for (var i = 0; i < bytes.length; i += 20) {
        final end = (i + 20 < bytes.length) ? i + 20 : bytes.length;
        await c.write(bytes.sublist(i, end), withoutResponse: noResp);
      }
    } catch (_) {}
  }

  // Canh bao muc Canh bao / Nguy hiem: rung may (trang web hien thong bao tren man hinh)
  Future<void> _alert() async {
    for (var i = 0; i < 3; i++) {
      HapticFeedback.vibrate();
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(child: WebViewWidget(controller: _web)),
      );
}
