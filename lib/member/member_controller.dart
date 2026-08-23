import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import '../config.dart';
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
  }) : identity = identity ?? Identity(),
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
  Timer? _pingTimer;

  /// Requests sent to the host that haven't been answered by a snapshot yet
  /// (the UI shows progress while this is > 0).
  int _inflight = 0;
  Timer? _inflightTimeout;
  bool get waiting => _inflight > 0;

  void _beginWait() {
    _inflight++;
    _inflightTimeout?.cancel();
    _inflightTimeout = Timer(const Duration(seconds: 10), () {
      _inflight = 0;
      notifyListeners();
    });
    notifyListeners();
  }

  void _endWait() {
    if (_inflight == 0) return;
    _inflight = 0;
    _inflightTimeout?.cancel();
    notifyListeners();
  }

  final _pendingResolves = <String, Completer<String?>>{};
  final _seen = SeenIds();

  String get displayHostName => view?.hostName ?? hostName ?? 'the host';

  Future<void> init() async {
    unawaited(_checkVersion());
    _watchVisibility();
    await identity.init();
    final prefs = await SharedPreferences.getInstance();
    final params = Uri.base.queryParameters;
    final shared = [
      params['url'],
      params['text'],
      params['title'],
    ].whereType<String>().join(' ');
    if (SpotifyLink.parse(shared) != null ||
        SpotifyLink.shortUrl(shared) != null) {
      _sharedText = shared;
    }
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
        uuid: identity.uuid,
        token: token,
        secret: identity.secret,
      );
      push.onMessage(_handleData);
      _watchVisibility();
      await _sendJoin();
      // Live updates arrive over FCM; the inbox is only drained to catch up
      // (now, after being in the background, or on manual refresh).
      unawaited(_drainInbox());
      phase = MemberPhase.joined;
      _startPinging();
    } catch (e) {
      error = e is StateError ? e.message : '$e';
      phase = MemberPhase.needName;
    }
    notifyListeners();
  }

  /// Why push is unavailable, and what to do about it, by permission state.
  String _pushHelp() {
    const why =
        'The host reaches you through push notifications, so they '
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
    _pingTimer?.cancel();
    _pingTimer = null;
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
  /// Also a good moment to notice a newer deployment (installed pages are
  /// resumed, not reloaded, so they can run an old build for days).
  void _watchVisibility() {
    if (_watchingVisibility) return;
    _watchingVisibility = true;
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState != 'visible') {
          _pingTimer?.cancel();
          _pingTimer = null;
          return;
        }
        unawaited(_checkVersion());
        if (phase == MemberPhase.joined) {
          unawaited(_drainInbox());
          _startPinging();
        }
      }).toJS,
    );
  }

  /// "Still here" heartbeat while the page is visible, so the host keeps
  /// pushing to us (it stops after [Config.listenerTimeout] of silence).
  void _startPinging() {
    unawaited(_send(MsgType.ping, {}));
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      Config.memberPingInterval,
      (_) => unawaited(_send(MsgType.ping, {})),
    );
  }

  /// Every message carries our uuid and name so the host can (re)admit us.
  /// Anything but a ping expects an answer (a snapshot or a resolve reply),
  /// so it is counted as in flight for the UI.
  Future<void> _send(String type, Map<String, dynamic> body) async {
    if (type != MsgType.ping) _beginWait();
    try {
      await switchClient.send(
        hostUuid!,
        Message(
          type: type,
          body: {'uuid': identity.uuid, 'name': identity.name, ...body},
        ).toData(),
      );
    } catch (e) {
      _endWait();
      rethrow;
    }
  }

  /// The host runs a newer build than this page: fetch the new web build
  /// (once per version, so a lagging deploy can't cause a reload loop).
  Future<void> _reloadForVersion(int v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'member_reloaded_for_protocol';
      if ((prefs.getInt(key) ?? 0) >= v) return;
      await prefs.setInt(key, v);
      await _dropCaches();
      web.window.location.reload();
    } catch (_) {}
  }

  static const _versionKey = 'member_app_version';
  DateTime _lastVersionCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// deploy-web.sh writes version.txt next to the app; if it changed since
  /// this page was loaded, reload so the service-worker picks up the new
  /// build (same trick as analfapet).
  Future<void> _checkVersion() async {
    if (DateTime.now().difference(_lastVersionCheck) <
        const Duration(minutes: 1)) {
      return;
    }
    _lastVersionCheck = DateTime.now();
    try {
      final baseHref =
          web.document.querySelector('base')?.getAttribute('href') ?? '/';
      final resp = await http
          .get(
            Uri.parse(
              '${baseHref}version.txt?t=${DateTime.now().millisecondsSinceEpoch}',
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final server = resp.body.trim();
      if (server.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final local = prefs.getString(_versionKey);
      await prefs.setString(_versionKey, server);
      if (local != null && local != server) {
        await _dropCaches();
        web.window.location.reload();
      }
    } catch (_) {
      // Offline or blocked: just keep running what we have.
    }
  }

  /// Empties Cache Storage (Flutter's app-shell cache and ours) and nudges the
  /// service workers to update, so the reload really fetches the new build.
  /// Registrations are kept: the push subscription lives on them.
  Future<void> _dropCaches() async {
    try {
      final keys = (await web.window.caches.keys().toDart).toDart;
      for (final k in keys) {
        await web.window.caches.delete(k.toDart).toDart;
      }
    } catch (_) {}
    try {
      final regs =
          (await web.window.navigator.serviceWorker.getRegistrations().toDart)
              .toDart;
      for (final r in regs) {
        await r.update().toDart;
      }
    } catch (_) {}
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

  Future<void> _sendJoin() => _send(MsgType.join, {});

  Future<List<Track>> search(String query) async {
    try {
      return await SpotifyWebApi.search(await _token(), query);
    } on SpotifyApiException catch (e) {
      if (e.isUnauthorized) {
        unawaited(_sendJoin());
        throw StateError(
          'Token expired; asked the host for a new one. Try again.',
        );
      }
      rethrow;
    }
  }

  Future<String> _token() async {
    final v = view;
    if (v == null || !v.hasValidToken) {
      unawaited(_sendJoin());
      throw StateError(
        "Waiting for the host's Spotify token — try again in a moment",
      );
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
        throw StateError(
          'Token expired; asked the host for a new one. Try again.',
        );
      }
      if (e.status == 403 || e.status == 404) {
        final host = view?.hostName ?? 'the host';
        throw StateError(
          'Spotify only lets Spot read playlists that $host owns or '
          'collaborates on (a 2026 API rule — "public" no longer matters). '
          'Fix: in Spotify open the playlist → ⋯ → Invite collaborators and '
          'let $host join it; then paste the link again. Until then, add its '
          'songs one by one via search.',
        );
      }
      rethrow;
    }
  }

  /// Next page of a playlist opened with [openLink].
  Future<bool> loadMore(TrackCollection col) async =>
      SpotifyWebApi.loadMore(await _token(), col);

  Future<void> enqueue(Track track) async {
    final item = QueueItem(id: const Uuid().v4(), track: track);
    await _send(MsgType.enqueue, {'item': item.toJson()});
  }

  /// Adds a whole playlist as one queue entry; the host reads it live.
  Future<void> enqueuePlaylist(String id, String name, int total) async {
    final item = QueueItem(
      id: const Uuid().v4(),
      playlist: PlaylistRef(id: id, name: name, total: total),
    );
    await _send(MsgType.enqueue, {'item': item.toJson()});
  }

  Future<void> setModes({bool? shuffle, bool? repeat}) async {
    final v = view;
    if (v != null) {
      view = MemberView(
        hostName: v.hostName,
        token: v.token,
        tokenExpiresAt: v.tokenExpiresAt,
        now: v.now,
        myPlayedMs: v.myPlayedMs,
        myQueue: v.myQueue,
        others: v.others,
        sentAt: v.sentAt,
        notice: v.notice,
        noticeAt: v.noticeAt,
        pausedReason: v.pausedReason,
        shuffle: shuffle ?? v.shuffle,
        repeat: repeat ?? v.repeat,
        cursor: v.cursor,
      );
      notifyListeners();
    }
    await _send(MsgType.modes, {'shuffle': ?shuffle, 'repeat': ?repeat});
  }

  /// Applies the new order locally right away (so the drag doesn't snap
  /// back) and tells the host; the host's next snapshot confirms it.
  Future<void> reorder(List<String> itemIds) async {
    final v = view;
    if (v != null) {
      final byId = {for (final q in v.myQueue) q.id: q};
      final next = [
        for (final id in itemIds) ?byId.remove(id),
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
        notice: v.notice,
        noticeAt: v.noticeAt,
        pausedReason: v.pausedReason,
        shuffle: v.shuffle,
        repeat: v.repeat,
        cursor: v.cursor,
      );
      notifyListeners();
    }
    await _send(MsgType.reorder, {'itemIds': itemIds});
  }

  Future<void> dequeue(String itemId) =>
      _send(MsgType.dequeue, {'itemId': itemId});

  /// Skip the playing song; the host charges the remaining time to us.
  Future<void> skip(String trackId) =>
      _send(MsgType.skip, {'trackId': trackId});

  /// Asks the host to follow a Spotify short share link and returns the real
  /// URL (the host phone has no CORS limits). Null if it couldn't.
  Future<String?> resolveShortLink(String url) async {
    final rid = const Uuid().v4();
    final completer = Completer<String?>();
    _pendingResolves[rid] = completer;
    try {
      await _send(MsgType.resolve, {'rid': rid, 'url': url});
      return await completer.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return null;
    } finally {
      _pendingResolves.remove(rid);
    }
  }

  void _handleData(Map<String, dynamic> data) {
    final m = Message.fromData(data);
    if (m == null || !_seen.add(m.id)) return;
    if (m.version > Config.protocolVersion) {
      unawaited(_reloadForVersion(m.version));
    }
    if (m.type == MsgType.resolved) {
      final rid = m.body['rid'];
      if (rid is String) {
        _pendingResolves[rid]?.complete(m.body['url'] as String?);
      }
      _endWait();
      return;
    }
    if (m.type != MsgType.state) return;
    try {
      final v = MemberView.fromJson(m.body);
      // Ignore snapshots older than the one we have (push and inbox can race).
      if (view != null && v.sentAt < view!.sentAt) return;
      view = v;
      lastStateAt = DateTime.now();
      error = null;
      _endWait();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _drainInbox() async {
    if (_polling) return;
    _polling = true;
    try {
      final msgs = await switchClient.inbox(
        uuid: identity.uuid,
        secret: identity.secret,
      );
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
