/// §15 camera QR scan-to-add — the ONLY file that imports `mobile_scanner`.
///
/// Kept isolated so the shared controller code (invite_screen etc.) carries no
/// direct camera dependency. It is reached solely through [launchScanToAdd],
/// which the caller guards with `scanToAddSupported`. On the Windows desktop
/// controller `scanToAddSupported` is false (compile-time define + runtime
/// platform check), so this widget is never constructed and the mobile_scanner
/// runtime path is never taken on Windows.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Open the camera scanner and return the first `lmw://pair...` string scanned,
/// or null if dismissed. Callers MUST gate this behind `scanToAddSupported`.
Future<String?> launchScanToAdd(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => const _ScanPage()),
  );
}

/// 真·摄像头扫码页（§15 扫码入口）：用 mobile_scanner 打开后置摄像头，扫到第一个
/// 含 `lmw://pair` 的二维码即 pop 回其原始文本。摄像头权限由 CI 注入的 CAMERA 声明
/// 支撑（见 .github/workflows/flutter-build.yml），运行时由 mobile_scanner 触发授权。
class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      // 只接受配对 URI，避免误扫其它二维码。大小写无关地匹配 scheme。
      if (raw.toLowerCase().startsWith('lmw://pair')) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描设备二维码'),
        actions: [
          IconButton(
            tooltip: '手电筒',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: '切换摄像头',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text(
              '对准被控端屏幕上的 lmw:// 配对二维码',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
