import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import '../models/member_view.dart';
import '../models/party.dart';
import '../models/track.dart';
import '../services/identity.dart';
import '../services/messages.dart';
import '../services/spotify_web_api.dart';
import '../services/switch_client.dart';
import 'web_push.dart';

enum MemberPhase { loading, noHost, needName, joining, joined }

final _uuidRe = RegExp(r'^[0-9a-fA-F-]{36}$');

/// Member brain (web): joins a host, searches Spotify with the host's token,
/// sends enqueue/dequeue, and keeps the latest [MemberView] from the host.
class MemberController extends ChangeNotifier {
  MemberController({
    Identity? identity,
    SwitchClient? switchClient,
    WebPush? push,
  })  : identity = identity ?? Identity(),
        switchClient = switchClient ?? SwitchClient(),
        push = push ?? WebPush();

  static const _hostKey = 'member_host_uuid';
  static const _hostNameKey = 'member_host_name';

  final Identity identity;
  final SwitchClient switchClient;
  final WebPush push;

  MemberPhase phase = MemberPhase.loading;
  String? hostUuid;
  String? hostName;
  MemberView? view;
  String? error;
  DateTime? lastStateAt;

  /// Text shared into the page (Web Share Target from the Spotify app) or a
  /// link in the URL; consumed once by the party screen.
  String? _sharedText;
  String? takeSharedText() {
    final t = _sharedText;
    _sharedText = null;
    return t;
  }

  bool _polling = false;
  bool _watchingVisibility = false;
  final _seen = SeenIds();

  String get displayHostName => view?.hostName ?? hostName ?? 'the host';

  Future<void> init() async {
    await identity.init();
    final prefs = await SharedPreferences.getInstance();
    final params = Uri.base.queryParameters;
    final shared = [params['url'], params['text'], params['title']]
        .whereType<String>()
        .join(' ');
    if (SpotifyLink.parse(shared) != null) _sharedText = shared;
    final joinParam = params['join'];
    if (joinParam != null && _uuidRe.hasMatch(joinParam)) {
      hostUuid = joinParam;
      hostName = params['n'];
      await prefs.setString(_hostKey, joinParam);
      if (hostName != null) await prefs.setString(_hostNameKey, hostName!);
    } else {
      hostUuid = prefs.getString(_hostKey);
      hostName = prefs.getString(_hostNameKey);
    }
    await push.init();
    if (hostUuid == null) {
      phase = MemberPhase.noHost;
    } else {
      phase = MemberPhase.needName;
      // Returning member with permission already granted: rejoin silently.
      if (identity.hasName && push.permission == 'granted') {
        unawaited(join(identity.name!));
      }
    }
    notifyListeners();
  }

  /// Accepts a scanned/pasted join link or a bare host UUID.
  Future<bool> setHost(String raw) async {
    String? uuid;
    String? name;
    final s = raw.trim();
    if (_uuidRe.hasMatch(s)) {
      uuid = s;
    } else {
      final uri = Uri.tryParse(s);
      final j = uri?.queryParameters['join'];
      if (j != null && _uuidRe.hasMatch(j)) {
        uuid = j;
        name = uri!.queryParameters['n'];
      }
    }
    if (uuid == null) {
      error = 'That is not a Spot join link';
      notifyListeners();
      return false;
    }
    hostUuid = uuid;
    hostName = name;
    view = null;
    error = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, uuid);
    if (name != null) await prefs.setString(_hostNameKey, name);
    phase = MemberPhase.needName;
    notifyListeners();
    return true;
  }

  Future<void> join(String name) async {
    final host = hostUuid;
    if (host == null) return;
    phase = MemberPhase.joining;
    error = null;
    notifyListeners();
    try {
      // Ask for push first, straight from the tap, before any other awaits.
      final token = await push.requestToken();
      if (token == null) throw StateError(_pushHelp());
      await identity.setName(name);
      await switchClient.register(
          uuid: identity.uuid, token: token, secret: identity.secret);
      push.onMessage(_handleData);
      _watchVisibility();
      await _sendJoin();
      // Live updates arrive over FCM; the inbox is only drained to catch up
      // (now, after being in the background, or on manual refresh).
      unawaited(_drainInbox());
      phase = MemberPhase.joined;
    } catch (e) {
      error = e is StateError ? e.message : '$e';
      phase = MemberPhase.needName;
    }
    notifyListeners();
  }

  /// Why push is unavailable, and what to do about it, by permission state.
  String _pushHelp() {
    const why = 'The host reaches you through push notifications, so they '
        'must be allowed for this page.';
    switch (push.permission) {
      case 'denied':
        return '$why They are blocked right now. If you opened Spot from the '
            'Home Screen: Android Settings → Apps → Spot → Notifications → '
            'Allow. In a Chrome tab: tap the icon left of the address bar → '
            'Permissions → Notifications → Allow (or ⋮ → Settings → Site '
            'settings → Notifications, and make sure "Sites can ask" is on). '
            'Also check Android Settings → Apps → Chrome → Notifications. '
            'Then tap Join again.';
      case 'unsupported':
        return '$why This browser has no web push. On iPhone/iPad: add this '
            'page to the Home Screen (Share → Add to Home Screen) and open it '
            'from there, then Join.';
      case 'default':
        return '$why The browser did not show the question. In Chrome, look '
            'for a crossed-out bell in the address bar, or check ⋮ → Settings → '
            'Site settings → Notifications → "Sites can ask" is on. Then tap '
            'Join again. ${push.error ?? ''}';
      default:
        return '$why ${push.error ?? 'Could not get a push token.'}';
    }
  }

  Future<void> leave() async {
    hostUuid = null;
    hostName = null;
    view = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hostKey);
    await prefs.remove(_hostNameKey);
    phase = MemberPhase.noHost;
    notifyListeners();
  }

  /// Re-announces ourselves; the host answers with a fresh snapshot (and
  /// token). Also drains the inbox in case a push was missed.
  Future<void> requestState() async {
    unawaited(_drainInbox());
    await _sendJoin();
  }

  /// Pushes that arrived while the tab was hidden went to the service worker
  /// (as a notification), not to the page: catch up when we become visible.
  void _watchVisibility() {
    if (_watchingVisibility) return;
    _watchingVisibility = true;
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'visible' &&
            phase == MemberPhase.joined) {
          unawaited(_drainInbox());
        }
      }).toJS,
    );
  }

  /// Changes the display name; a join message carries the new name to the
  /// host, which tells everyone.
  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    await identity.setName(n);
    notifyListeners();
    if (phase == MemberPhase.joined) await _sendJoin();
  }

  Future<void> _sendJoin() => switchClient.send(
        hostUuid!,
        Message(
          type: MsgType.join,
          body: {'uuid': identity.uuid, 'name': identity.name},
        ).toData(),
      );

  Future<List<Track>> search(String query) async {
    try {
      return await SpotifyWebApi.search(await _token(), query);
    } on SpotifyApiException catch (e) {
      if (e.isUnauthorized) {
        unawaited(_sendJoin());
        throw StateError('Token expired; asked the host for a new one. Try again.');
      }
      rethrow;
    }
  }

  Future<String> _token() async {
    final v = view;
    if (v == null || !v.hasValidToken) {
      unawaited(_sendJoin());
      throw StateError("Waiting for the host's Spotify token — try again in a moment");
    }
    return v.token!;
  }

  /// Tracks behind a pasted/shared Spotify link (track, playlist or album).
  Future<TrackCollection> openLink(SpotifyLink link) async {
    try {
      return await SpotifyWebApi.fromLink(await _token(), link);
    } on SpotifyApiException catch (e) {
      if (e.isUnauthorized) {
        unawaited(_sendJoin());
        throw StateError('Token expired; asked the host for a new one. Try again.');
      }
      if (e.status == 404 || e.status == 403) {
        throw StateError(
            'Spotify would not hand out that ${link.type} — private playlists '
            'and Spotify-made ones cannot be read. Make it public and try again.');
      }
      rethrow;
    }
  }

  /// Next page of a playlist opened with [openLink].
  Future<bool> loadMore(TrackCollection col) async =>
      SpotifyWebApi.loadMore(await _token(), col);

  Future<void> enqueue(Track track) async {
    final item = QueueItem(id: const Uuid().v4(), track: track);
    await switchClient.send(
      hostUuid!,
      Message(
        type: MsgType.enqueue,
        body: {'uuid': identity.uuid, 'item': item.toJson()},
      ).toData(),
    );
  }

  /// Applies the new order locally right away (so the drag doesn't snap
  /// back) and tells the host; the host's next snapshot confirms it.
  Future<void> reorder(List<String> itemIds) async {
    final v = view;
    if (v != null) {
      final byId = {for (final q in v.myQueue) q.id: q};
      final next = [
        for (final id in itemIds)
          ?byId.remove(id),
        ...v.myQueue.where((q) => byId.containsKey(q.id)),
      ];
      view = MemberView(
        hostName: v.hostName,
        token: v.token,
        tokenExpiresAt: v.tokenExpiresAt,
        now: v.now,
        myPlayedMs: v.myPlayedMs,
        myQueue: next,
        others: v.others,
        sentAt: v.sentAt,
      );
      notifyListeners();
    }
    await switchClient.send(
      hostUuid!,
      Message(
        type: MsgType.reorder,
        body: {'uuid': identity.uuid, 'itemIds': itemIds},
      ).toData(),
    );
  }

  Future<void> dequeue(String itemId) => switchClient.send(
        hostUuid!,
        Message(
          type: MsgType.dequeue,
          body: {'uuid': identity.uuid, 'itemId': itemId},
        ).toData(),
      );

  void _handleData(Map<String, dynamic> data) {
    final m = Message.fromData(data);
    if (m == null || !_seen.add(m.id)) return;
    if (m.type != MsgType.state) return;
    try {
      final v = MemberView.fromJson(m.body);
      // Ignore snapshots older than the one we have (push and inbox can race).
      if (view != null && v.sentAt < view!.sentAt) return;
      view = v;
      lastStateAt = DateTime.now();
      error = null;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _drainInbox() async {
    if (_polling) return;
    _polling = true;
    try {
      final msgs = await switchClient.inbox(
          uuid: identity.uuid, secret: identity.secret);
      for (final d in msgs) {
        _handleData(d);
      }
    } catch (_) {
      // Transient; next tick retries.
    } finally {
      _polling = false;
    }
  }

}
