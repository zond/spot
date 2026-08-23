import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotify_sdk/spotify_sdk.dart' show PlayerState;

import '../config.dart';
import '../models/member_view.dart';
import '../models/party.dart';
import '../models/track.dart';
import '../services/identity.dart';
import '../services/messages.dart';
import '../services/spotify_web_api.dart';
import '../services/switch_client.dart';
import 'foreground.dart';
import 'host_player.dart';
import 'host_push.dart';
import 'spotify_auth.dart';

enum HostPhase { idle, starting, running }

/// The host brain: receives member messages through fcm-switch, keeps the
/// [Party] state, drives the Spotify app, and sends every member a personal
/// state snapshot whenever something changes.
///
/// Playback model: the scheduler plays one track at a time (`play(uri)`),
/// watches App Remote player-state events to credit airtime and detect the end
/// of the track, then asks [Party.takeNext] for the next one. A belt-and-braces
/// timer re-checks the player state shortly after the expected end in case the
/// end event never arrives.
class HostController extends ChangeNotifier {
  HostController({
    required this.identity,
    required this.auth,
    required this.player,
    SwitchClient? switchClient,
    HostPush? push,
  }) : switchClient = switchClient ?? SwitchClient(),
       push = push ?? HostPush();

  static const _partyKey = 'host_party';

  final Identity identity;
  final SpotifyAuth auth;
  final HostPlayer player;
  final SwitchClient switchClient;
  final HostPush push;

  Party party = Party();
  HostPhase phase = HostPhase.idle;
  String? notice;
  int noticeAt = 0;

  // ---- Spotify taken over by another device (one stream per account)
  /// Spotify Connect id/name of *this* phone, learnt the first time our track
  /// is heard playing.
  String? _ourDeviceId;
  String? ourDeviceName;
  bool takenOver = false;
  String? takenOverBy;

  /// True when the takeover happened in the Spotify app on this very phone
  /// (someone started other music here) rather than on another device.
  bool takenOverLocally = false;
  bool autoReclaim = false;
  Timer? _reclaimTimer;
  bool _checkingDevice = false;
  String status = '';
  String? lastError;
  bool spotifyConnected = false;

  // ---- current track
  QueueItem? current;
  Member? currentMember;
  String? _expectedUri;
  bool _sawPlaying = false;
  int _lastPos = 0;
  int _durationMs = 0;
  int _startAttempts = 0;
  int _positionMs = 0;
  DateTime _positionAt = DateTime.now();
  bool paused = false;
  Timer? _endCheck;
  Timer? _startTimeout;

  // ---- comms
  Timer? _pollTimer;
  Timer? _heartbeat;
  Timer? _tokenTimer;
  Timer? _broadcastDebounce;
  Timer? _reconnect;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<dynamic>? _connSub;
  bool _polling = false;
  int _pollFailures = 0;
  final _seen = SeenIds();

  String get joinUrl => Uri.parse(Config.webBaseUrl)
      .replace(
        queryParameters: {'join': identity.uuid, 'n': identity.name ?? 'Host'},
      )
      .toString();

  /// Extrapolated playback position of the current track.
  int get positionMs => paused
      ? _positionMs
      : min(
          _durationMs > 0 ? _durationMs : 1 << 30,
          _positionMs + DateTime.now().difference(_positionAt).inMilliseconds,
        );

  int get durationMs => _durationMs;

  /// Airtime including the part of the current track not yet credited (credit
  /// happens on Spotify state events, which are sparse).
  int airtimeOf(Member m) =>
      m.playedMs +
      (currentMember?.uuid == m.uuid && _sawPlaying
          ? max(0, positionMs - _lastPos)
          : 0);

  // ------------------------------------------------------------------ lifecycle

  Future<void> start() async {
    phase = HostPhase.starting;
    lastError = null;
    status = 'Starting…';
    notifyListeners();
    try {
      await _restoreParty();

      status = 'Checking Spotify login…';
      notifyListeners();
      if (auth.needsRelogin) {
        throw StateError(
          'Spot needs new Spotify permissions: log out and log in again.',
        );
      }
      final token = await auth.validToken();
      if (token == null) throw StateError('Log in to Spotify first');

      status = 'Registering with the relay…';
      notifyListeners();
      final fcmToken = await push.init(_onPushData);
      if (fcmToken == null) {
        throw StateError(
          'Push (FCM) unavailable: ${push.error ?? 'no token'}. '
          'Run `flutterfire configure` for Android (see README).',
        );
      }
      push.onTokenRefresh = (t) => switchClient
          .register(uuid: identity.uuid, token: t, secret: identity.secret)
          .catchError((_) {});
      await switchClient.register(
        uuid: identity.uuid,
        token: fcmToken,
        secret: identity.secret,
      );

      status = 'Connecting to the Spotify app…';
      notifyListeners();
      await _connectPlayer();

      await HostForeground.requestPermissions();
      await HostForeground.start(text: 'Waiting for songs');

      _pollTimer = Timer.periodic(Config.inboxPollInterval, (_) => _poll());
      _heartbeat = Timer.periodic(Config.stateHeartbeat, (_) => broadcast());
      _scheduleTokenRefresh();

      phase = HostPhase.running;
      status = 'Waiting for songs';
      notifyListeners();
      unawaited(_poll());
      _maybePlayNext();
      broadcast();
    } catch (e) {
      lastError = '$e';
      phase = HostPhase.idle;
      status = '';
      notifyListeners();
      await _teardown();
    }
  }

  Future<void> stop() async {
    await _teardown();
    phase = HostPhase.idle;
    status = '';
    notifyListeners();
  }

  /// Forgets members, queues and airtime.
  Future<void> resetParty() async {
    party = Party();
    await _persistParty();
    notifyListeners();
  }

  Future<void> _teardown() async {
    _pollTimer?.cancel();
    _heartbeat?.cancel();
    _tokenTimer?.cancel();
    _broadcastDebounce?.cancel();
    _reconnect?.cancel();
    _endCheck?.cancel();
    _startTimeout?.cancel();
    _pollTimer = _heartbeat = _tokenTimer = _broadcastDebounce = null;
    _reconnect = _endCheck = _startTimeout = null;
    await _stateSub?.cancel();
    await _connSub?.cancel();
    _stateSub = null;
    _connSub = null;
    _reclaimTimer?.cancel();
    _reclaimTimer = null;
    takenOver = false;
    takenOverLocally = false;
    takenOverBy = null;
    if (spotifyConnected) {
      try {
        await player.pause();
      } catch (_) {}
      try {
        await player.disconnect();
      } catch (_) {}
    }
    spotifyConnected = false;
    _expectedUri = null;
    current = null;
    currentMember = null;
    await HostForeground.stop();
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }

  // ---------------------------------------------------------------- spotify

  Future<void> _connectPlayer() async {
    await player.connect();
    spotifyConnected = true;
    await _stateSub?.cancel();
    await _connSub?.cancel();
    _stateSub = player.states.listen(
      _onPlayerState,
      onError: (Object e) {
        lastError = 'Player: $e';
        notifyListeners();
      },
    );
    _connSub = player.connection.listen((c) {
      spotifyConnected = c.connected;
      if (!c.connected) {
        status =
            'Spotify disconnected${c.message == null ? '' : ': ${c.message}'}';
        _scheduleReconnect();
      }
      notifyListeners();
    });
  }

  void _scheduleReconnect() {
    if (phase != HostPhase.running || _reconnect != null) return;
    _reconnect = Timer(const Duration(seconds: 5), () async {
      _reconnect = null;
      if (phase != HostPhase.running || spotifyConnected) return;
      try {
        await _connectPlayer();
        status = 'Reconnected to Spotify';
        if (_expectedUri != null) {
          _sawPlaying = false;
          await _issuePlay();
        } else {
          _maybePlayNext();
        }
      } catch (e) {
        lastError = 'Reconnect: $e';
        _scheduleReconnect();
      }
      notifyListeners();
    });
  }

  void _maybePlayNext() {
    if (phase != HostPhase.running || !spotifyConnected) return;
    if (_expectedUri != null) return;
    unawaited(_playNext());
  }

  Future<void> _playNext() async {
    _endCheck?.cancel();
    _startTimeout?.cancel();
    final next = party.takeNext();
    if (next == null) {
      _expectedUri = null;
      current = null;
      currentMember = null;
      party.removeIdle();
      status = 'Waiting for songs';
      unawaited(HostForeground.update(status));
      await _persistParty();
      notifyListeners();
      broadcast();
      return;
    }
    final (member, item) = next;
    current = item;
    currentMember = member;
    party.removeIdle(playing: member.uuid);
    _expectedUri = item.track.uri;
    _sawPlaying = false;
    _lastPos = 0;
    _positionMs = 0;
    _positionAt = DateTime.now();
    paused = false;
    _durationMs = item.track.durationMs;
    _startAttempts = 0;
    await _persistParty();
    notifyListeners();
    await _issuePlay();
    broadcast();
  }

  Future<void> _issuePlay() async {
    final uri = _expectedUri;
    if (uri == null) return;
    _startAttempts++;
    try {
      await player.play(uri);
      status = 'Playing for ${currentMember?.name}';
      unawaited(
        HostForeground.update(
          '${current?.track.name} — ${currentMember?.name}',
        ),
      );
    } catch (e) {
      lastError = 'Play failed: $e';
    }
    notifyListeners();
    _startTimeout?.cancel();
    _startTimeout = Timer(const Duration(seconds: 10), () {
      if (_expectedUri != uri || _sawPlaying) return;
      if (_startAttempts < 3) {
        unawaited(_issuePlay());
      } else {
        lastError = 'Spotify did not start ${current?.track}; skipping it';
        _finishCurrent();
      }
    });
  }

  void _onPlayerState(PlayerState s) {
    final expected = _expectedUri;
    final track = s.track;
    if (expected == null || track == null) return;

    final isOurs = track.uri == expected || track.linkedFromUri == expected;
    if (takenOver) {
      // Another device holds the account. We're back when our track is heard
      // playing here again (Take back / auto-reclaim / someone transferred).
      if (isOurs && !s.isPaused) {
        _exitTakenOver();
      } else {
        return;
      }
    }
    if (!isOurs) {
      // Before we've seen our track play, Spotify is still switching to it.
      // After, a different track means ours ended (autoplay kicked in),
      // someone skipped in the Spotify app — or another device took the
      // account over. Ask Spotify which device is active before moving on.
      if (_sawPlaying) unawaited(_onForeignTrack());
      return;
    }

    if (_ourDeviceId == null && !s.isPaused) unawaited(_learnDevice());

    final pos = s.playbackPosition;
    final duration = track.duration > 0 ? track.duration : _durationMs;
    _durationMs = duration;
    if (!s.isPaused) _sawPlaying = true;

    if (_sawPlaying) {
      if (pos >= _lastPos) {
        party.credit(currentMember!.uuid, pos - _lastPos);
        _lastPos = pos;
        _persistThrottled();
      } else {
        // Position jumped back: a seek, or Spotify restarted the track after
        // it ended (repeat). Treat the latter as the end.
        final wasNearEnd = duration > 0 && _lastPos >= duration - 3000;
        if (wasNearEnd && !s.isPaused) {
          _finishCurrent();
          return;
        }
        _lastPos = pos;
      }
    }

    final pausedChanged = paused != s.isPaused;
    paused = s.isPaused;
    _positionMs = pos;
    _positionAt = DateTime.now();

    // Stopped at the start or the end after having played: the track is over.
    if (_sawPlaying &&
        s.isPaused &&
        (pos == 0 || (duration > 0 && pos >= duration - 1500))) {
      _finishCurrent();
      return;
    }

    _endCheck?.cancel();
    if (!s.isPaused && duration > 0) {
      _endCheck = Timer(
        Duration(milliseconds: max(0, duration - pos) + 2500),
        _checkEnd,
      );
    }
    if (pausedChanged) broadcast();
    notifyListeners();
  }

  /// Remembers which Spotify Connect device is "this phone": whatever is
  /// active while our track is playing.
  Future<void> _learnDevice() async {
    if (_checkingDevice) return;
    _checkingDevice = true;
    try {
      final token = await auth.validToken();
      if (token == null) return;
      final snap = await SpotifyWebApi.player(token);
      final d = snap?.device;
      if (d != null && snap!.trackId == current?.track.id) {
        _ourDeviceId = d.id;
        ourDeviceName = d.name;
        notifyListeners();
      }
    } catch (_) {
      // Without device info we fall back to the old behaviour.
    } finally {
      _checkingDevice = false;
    }
  }

  /// A track that isn't ours is playing. Either our song ended and Spotify
  /// autoplayed (same device → move on) or another device took the account
  /// over (→ pause the party instead of feeding it our queue).
  Future<void> _onForeignTrack() async {
    if (_checkingDevice || takenOver || _expectedUri == null) return;
    _checkingDevice = true;
    // Spotify only autoplays something else *after* our song reached its end;
    // a foreign track while we were mid-song means a person chose it.
    final nearEnd = _durationMs > 0 && positionMs >= _durationMs - 5000;
    try {
      final token = await auth.validToken();
      final snap = token == null ? null : await SpotifyWebApi.player(token);
      final d = snap?.device;
      if (d != null && _ourDeviceId != null && d.id != _ourDeviceId) {
        _enterTakenOver(d.name, local: false);
        return;
      }
    } catch (_) {
      // Can't tell which device; fall back to the position heuristic.
    } finally {
      _checkingDevice = false;
    }
    if (takenOver || _expectedUri == null) return;
    if (!nearEnd) {
      _enterTakenOver('the Spotify app on this phone', local: true);
      return;
    }
    _finishCurrent();
  }

  void _enterTakenOver(String deviceName, {required bool local}) {
    takenOver = true;
    takenOverLocally = local;
    takenOverBy = deviceName;
    paused = true;
    _positionMs = _lastPos;
    _positionAt = DateTime.now();
    _endCheck?.cancel();
    _startTimeout?.cancel();
    status = local
        ? 'Someone started other music in Spotify here — party paused'
        : 'Spotify is playing on $deviceName — party paused';
    notice = local
        ? 'Party paused: someone is playing other music in Spotify on the host phone'
        : 'Party paused: Spotify was taken over by $deviceName';
    noticeAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(HostForeground.update(status));
    notifyListeners();
    broadcast();
    if (autoReclaim) {
      _reclaimTimer?.cancel();
      _reclaimTimer = Timer(const Duration(seconds: 30), () {
        if (takenOver) unawaited(reclaim());
      });
    }
  }

  void _exitTakenOver() {
    takenOver = false;
    takenOverLocally = false;
    takenOverBy = null;
    _reclaimTimer?.cancel();
    _reclaimTimer = null;
    status = 'Playing for ${currentMember?.name}';
    notice = 'Back on this phone';
    noticeAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    broadcast();
  }

  /// Pulls playback back to this phone and resumes the current song where it
  /// was. Falls back to App Remote's play when the Web API can't help.
  Future<void> reclaim() async {
    final cur = current;
    if (cur == null) return;
    _sawPlaying = false;
    try {
      final token = await auth.validToken();
      final dev = _ourDeviceId;
      if (token != null && dev != null) {
        await SpotifyWebApi.playOn(token, dev, cur.track.uri, _lastPos);
      } else {
        await player.play(cur.track.uri);
      }
      status = 'Taking playback back…';
    } catch (e) {
      lastError = 'Take back: $e';
    }
    notifyListeners();
  }

  void setAutoReclaim(bool on) {
    autoReclaim = on;
    if (!on) {
      _reclaimTimer?.cancel();
      _reclaimTimer = null;
    } else if (takenOver && _reclaimTimer == null) {
      _reclaimTimer = Timer(const Duration(seconds: 30), () {
        if (takenOver) unawaited(reclaim());
      });
    }
    notifyListeners();
  }

  Future<void> _checkEnd() async {
    if (_expectedUri == null || takenOver) return;
    try {
      final s = await player.state();
      if (s != null) {
        _onPlayerState(s);
        // Still reported as playing our track past its end: poll again soon.
        if (_expectedUri != null && !paused) {
          _endCheck = Timer(const Duration(seconds: 3), _checkEnd);
        }
        return;
      }
    } catch (_) {}
    _finishCurrent();
  }

  void _finishCurrent() {
    _endCheck?.cancel();
    _startTimeout?.cancel();
    _expectedUri = null;
    current = null;
    currentMember = null;
    unawaited(_playNext());
  }

  // ---------------------------------------------------------- host controls

  Future<void> pause() async {
    try {
      await player.pause();
    } catch (e) {
      lastError = 'Pause: $e';
      notifyListeners();
    }
  }

  Future<void> resume() async {
    try {
      await player.resume();
    } catch (e) {
      lastError = 'Resume: $e';
      notifyListeners();
    }
  }

  void skip() {
    if (_expectedUri == null) return;
    _finishCurrent();
  }

  void removeQueued(String memberUuid, String itemId) {
    if (party.dequeue(memberUuid, itemId)) {
      party.removeIdle(playing: currentMember?.uuid);
      unawaited(_persistParty());
      notifyListeners();
      broadcast();
    }
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  // -------------------------------------------------------------- incoming

  void _onPushData(Map<String, dynamic> data) {
    final m = Message.fromData(data);
    if (m != null) _handle(m);
  }

  Future<void> _poll() async {
    if (_polling || phase != HostPhase.running) return;
    _polling = true;
    try {
      final msgs = await switchClient.inbox(
        uuid: identity.uuid,
        secret: identity.secret,
      );
      for (final d in msgs) {
        final m = Message.fromData(d);
        if (m != null) _handle(m);
      }
      if (_pollFailures >= 3 && (lastError?.startsWith('Inbox:') ?? false)) {
        lastError = null;
        notifyListeners();
      }
      _pollFailures = 0;
    } catch (e) {
      // Phones flap between networks; only complain when it keeps failing.
      if (++_pollFailures >= 3) {
        lastError = 'Inbox: $e';
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  void _handle(Message m) {
    if (!_seen.add(m.id)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final uuid = m.body['uuid'];
    if (uuid is! String) return;
    final name = (m.body['name'] as String?)?.trim();
    // Any message proves the sender is around (and may rename them).
    final wasKnown = party.listener(uuid) != null;
    party.touch(uuid, name, now);
    switch (m.type) {
      case MsgType.join:
        unawaited(_persistParty());
        notifyListeners();
        unawaited(_sendView(uuid));
      case MsgType.ping:
        // A returning listener needs a snapshot right away.
        if (!wasKnown) unawaited(_sendView(uuid));
        notifyListeners();
      case MsgType.skip:
        final cur = current;
        if (cur == null || m.body['trackId'] != cur.track.id) return;
        final remaining = max(0, _durationMs - positionMs);
        final who = party.listener(uuid)?.name ?? 'Someone';
        party.penalize(uuid, name, remaining, now);
        notice =
            '$who skipped ${cur.track.name} '
            '(+${formatMs(remaining)} to ${who == name ? 'their' : who}\'s airtime)';
        noticeAt = now;
        status = notice!;
        unawaited(_persistParty());
        notifyListeners();
        _finishCurrent();
      case MsgType.enqueue:
        final itemJson = m.body['item'];
        if (itemJson is! Map<String, dynamic>) return;
        final QueueItem item;
        try {
          item = QueueItem.fromJson(itemJson);
        } catch (_) {
          return;
        }
        if (party.enqueue(uuid, name, item, now)) {
          unawaited(_persistParty());
          notifyListeners();
          _maybePlayNext();
          broadcast();
        }
      case MsgType.dequeue:
        final itemId = m.body['itemId'];
        if (itemId is! String) return;
        if (party.dequeue(uuid, itemId)) {
          party.removeIdle(playing: currentMember?.uuid);
          unawaited(_persistParty());
          notifyListeners();
          broadcast();
        }
      case MsgType.reorder:
        final ids = m.body['itemIds'];
        if (ids is! List) return;
        if (party.reorder(uuid, ids.whereType<String>().toList())) {
          unawaited(_persistParty());
          notifyListeners();
          broadcast();
        }
    }
  }

  // -------------------------------------------------------------- outgoing

  /// Sends every member a fresh snapshot (debounced, so a burst of changes
  /// costs one round of sends).
  void broadcast() {
    if (phase != HostPhase.running) return;
    _broadcastDebounce ??= Timer(
      const Duration(milliseconds: 300),
      _flushBroadcast,
    );
  }

  Future<void> _flushBroadcast() async {
    _broadcastDebounce = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Only push to pages heard from recently; forget the rest.
    if (party.pruneListeners(now, Config.listenerTimeout * 6) > 0) {
      unawaited(_persistParty());
    }
    final recipients = party.recipients(now, Config.listenerTimeout).toList();
    await Future.wait(recipients.map((l) => _sendView(l.uuid)));
  }

  Future<void> _sendView(String uuid) async {
    final view = viewFor(uuid);
    if (view == null) return;
    try {
      await switchClient.send(
        uuid,
        Message(type: MsgType.state, body: view.toJson()).toData(),
      );
    } catch (e) {
      lastError = 'Send to ${party.listener(uuid)?.name}: $e';
      notifyListeners();
    }
  }

  MemberView? viewFor(String uuid) {
    if (party.listener(uuid) == null) return null;
    // Not an active member = nothing queued, airtime at the party maximum.
    final me = party.member(uuid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final cur = current;
    final curMember = currentMember;
    return MemberView(
      hostName: identity.name ?? 'Host',
      token: auth.accessToken,
      tokenExpiresAt: auth.expiresAt?.millisecondsSinceEpoch ?? 0,
      now: cur == null || curMember == null
          ? null
          : NowInfo(
              track: cur.track,
              memberUuid: curMember.uuid,
              memberName: curMember.name,
              positionMs: positionMs,
              atMs: now,
              paused: paused,
            ),
      myPlayedMs: me?.playedMs ?? party.maxPlayedMs,
      myQueue: me == null ? const [] : List.of(me.queue),
      others: [
        for (final m in party.members)
          if (m.uuid != uuid)
            OtherInfo(
              uuid: m.uuid,
              name: m.name,
              playedMs: m.playedMs,
              queueLength: m.queue.length,
              nextTrack: m.queue.isEmpty ? null : m.queue.first.track.name,
            ),
      ],
      sentAt: now,
      notice: notice,
      noticeAt: noticeAt,
      pausedReason: !takenOver
          ? null
          : takenOverLocally
              ? 'Party paused: someone is playing other music in the Spotify '
                  'app on the host phone. The host can take it back.'
              : 'Party paused: Spotify is playing on "$takenOverBy" (one '
                  'stream per account). The host can take it back.',
    );
  }

  // ----------------------------------------------------------------- token

  void _scheduleTokenRefresh() {
    _tokenTimer?.cancel();
    final exp = auth.expiresAt;
    var delay = exp == null
        ? const Duration(minutes: 1)
        : exp.difference(DateTime.now()) - Config.tokenRefreshMargin;
    if (delay < const Duration(minutes: 1)) delay = const Duration(minutes: 1);
    _tokenTimer = Timer(delay, () async {
      try {
        await auth.refresh();
        broadcast();
      } catch (e) {
        lastError = 'Token refresh: $e';
        notifyListeners();
      }
      if (phase == HostPhase.running) _scheduleTokenRefresh();
    });
  }

  // ----------------------------------------------------------- persistence

  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  /// Saves members, queues and airtime. The track playing right now is saved
  /// at the head of its member's queue so a restart resumes with it.
  Future<void> _persistParty() async {
    _lastPersist = DateTime.now();
    final json = party.toJson();
    final cur = current;
    final cm = currentMember;
    if (cur != null && cm != null) {
      for (final m in json['members'] as List) {
        if ((m as Map)['uuid'] == cm.uuid) {
          (m['queue'] as List).insert(0, cur.toJson());
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_partyKey, jsonEncode(json));
  }

  /// Airtime accrues continuously; persist it now and then so a crash or
  /// reinstall doesn't forget it.
  void _persistThrottled() {
    if (DateTime.now().difference(_lastPersist) > const Duration(seconds: 10)) {
      unawaited(_persistParty());
    }
  }

  Future<void> _restoreParty() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_partyKey);
    if (raw == null) return;
    try {
      party = Party.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      party = Party();
    }
  }

  Future<void> loadSavedParty() =>
      _restoreParty().then((_) => notifyListeners());
}
