import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

@JS('_spotCanPromptInstall')
external bool _jsCanPromptInstall();

@JS('_spotPromptInstall')
external JSPromise<JSBoolean> _jsPromptInstall();

bool get _isStandalone =>
    web.window.matchMedia('(display-mode: standalone)').matches;

String get _ua => web.window.navigator.userAgent.toLowerCase();

bool get _isIOS =>
    _ua.contains('iphone') ||
    _ua.contains('ipad') ||
    (_ua.contains('macintosh') && web.window.navigator.maxTouchPoints > 0);

bool get _isMobile => _isIOS || _ua.contains('android');

/// "Add Spot to your home screen" — a tappable install offer where the
/// browser supports prompting (Android Chrome), otherwise instructions.
/// Hidden once the page runs installed. Same idea as analfapet's hint.
class InstallHint extends StatefulWidget {
  const InstallHint({super.key});

  @override
  State<InstallHint> createState() => _InstallHintState();
}

class _InstallHintState extends State<InstallHint> {
  Future<void> _install() async {
    try {
      await _jsPromptInstall().toDart;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_isStandalone || !_isMobile) return const SizedBox.shrink();
    final canPrompt = _jsCanPromptInstall();
    final text = canPrompt
        ? 'Install Spot on your home screen: notifications are more reliable, '
            'and Spotify\'s Share menu gets a Spot entry.'
        : _isIOS
            ? 'iPhone/iPad: tap Share (square with arrow) → "Add to Home '
                'Screen", then open Spot from there — notifications only work '
                'that way.'
            : 'Add Spot to your home screen (Chrome menu ⋮ → "Add to Home '
                'screen" / "Install app"): notifications are more reliable, '
                'and Spotify\'s Share menu gets a Spot entry.';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: InkWell(
        onTap: canPrompt ? _install : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.install_mobile,
                size: 18, color: canPrompt ? Colors.white70 : Colors.white54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: canPrompt ? Colors.white70 : Colors.white54,
                  decoration: canPrompt ? TextDecoration.underline : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
