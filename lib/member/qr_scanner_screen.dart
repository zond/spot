import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// In-page QR scanner (BarcodeDetector with a jsQR fallback, see index.html).
/// Only needed when the page is already open; scanning the host's QR with the
/// phone's camera app opens the join link directly.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  static int _viewCounter = 0;
  late final String _viewId;
  late final web.HTMLVideoElement _video;
  web.MediaStream? _stream;
  Timer? _scanTimer;
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _viewId = 'qr-scanner-${_viewCounter++}';
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewId,
      (int id) => _video,
    );
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final constraints = web.MediaStreamConstraints(
        video: {'facingMode': 'environment'}.jsify()!,
      );
      _stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      _video.srcObject = _stream;
      setState(() => _scanning = true);
      _scanTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _scan(),
      );
    } catch (e) {
      setState(() => _error = 'Camera access denied');
    }
  }

  Future<void> _scan() async {
    if (!_scanning) return;
    try {
      final result = await _jsDetectQR(_video).toDart;
      if (result != null && mounted) {
        _scanning = false;
        Navigator.pop(context, (result as JSString).toDart);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _scanning = false;
    _stream?.getTracks().toDart.forEach((track) => track.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan the host QR')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            )
          : Stack(
              children: [
                SizedBox.expand(child: HtmlElementView(viewType: _viewId)),
                if (_scanning)
                  const Center(
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.greenAccent, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

@JS('_spotDetectQR')
external JSPromise<JSAny?> _jsDetectQR(web.HTMLVideoElement video);
