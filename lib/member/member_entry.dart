import 'dart:js_interop';

import 'package:flutter/widgets.dart';

import '../config.dart';
import 'member_app.dart';

/// The build this page is running, readable from the browser console as
/// `spotBuild` — the quickest way to tell whether someone is on the current
/// version (it matches the stamp in the page's footer).
@JS('spotBuild')
external set _spotBuild(JSAny? value);

Widget buildApp() {
  _spotBuild = Config.buildStamp.toJS;
  return const MemberApp();
}
