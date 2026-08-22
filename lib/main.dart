import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// One codebase, two apps: Android builds are the host (plays via the Spotify
// app, schedules fairly), web builds are the member page (search + personal
// queue). Conditional imports keep each side's platform-only code out of the
// other's build.
import 'host/host_entry_stub.dart' if (dart.library.io) 'host/host_entry.dart'
    as host;
import 'member/member_entry.dart'
    if (dart.library.io) 'member/member_entry_stub.dart' as member;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(kIsWeb ? member.buildApp() : host.buildApp());
}
