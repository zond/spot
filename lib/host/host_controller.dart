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
import '../services/spotify_public_page.dart';
import '../services/spotify_web_api.dart';
import '../services/switch_client.dart';
import 'foreground.dart';
import 'host_player.dart';
import 'host_settings.dart';
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
  static const _currentKey = 'host_current';

  final Identity identity;
  final SpotifyAuth auth;
  final HostPlayer player;
  final SwitchClient switchClient;
  final HostPush push;

  Party party = Party();
  HostPhase phase = HostPhase.idle;
  final Random _rng = Random();
  String? notice;
  int noticeAt = 0;

  /// A member is running a newer build than this host: ask for an update.
  int? newerMemberVersion;

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
  Timer? _reclaimTimer;

  /// When the session was recently pulled out from under us. The party takes
  /// it straight back, and only gives up (showing the banner) if that keeps
  /// happening — otherwise two devices would fight forever.
  final List<DateTime> _interruptions = [];
  bool _checkingDevice = false;
  String status = '';
  String? lastError;
  bool spotifyConnected = false;

  // ---- current track
  QueueItem? current;
  Member? currentMember;

  /// True while we let a song that isn't from the party (whatever Spotify
  /// was playing when the host started) finish before taking over. Nobody is
  /// credited for it and skipping it is free.
  bool interlude = false;

  /// Playing a playlist the host can't read: we told the Spotify app to play
  /// index n of the context and are waiting to learn which track that is.
  bool _awaitingContext = false;
  QueueItem? _contextEntry;

  /// What plays next, worked out while the current song is still playing so
  /// the switch itself costs nothing (no metadata fetch, no page load, no
  /// silence for Spotify to fill with music of its own). A queue change in
  /// the last seconds of a song lands one song later, which is a fair price
  /// for a gapless handover.
  ({Member member, QueueItem entry, Track? track, int? index})? _prepared;
  Timer? _prefetch;

  final _metaCache = <String, ({DateTime at, String name, int? total})>{};

  /// Last few things that happened to playback, newest first — the host
  /// screen shows them so a party that misbehaves can be explained after the
  /// fact ("cut X, played Y", "Spotify played Z on its own", …).
  final List<String> events = [];

  void _log(String what) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    events.insert(
      0,
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $what',
    );
    if (events.length > 40) events.removeLast();
  }

  String? _lastFinishedUri;
  Timer? _preempt;
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
      if (!await _tryResume() && !await _letForeignFinish()) _maybePlayNext();
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
    _preempt?.cancel();
    _prefetch?.cancel();
    _prepared = null;
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

  /// Picks the next member (least airtime) and resolves their next entry to
  /// a song: loose songs directly, playlist entries by reading the playlist
  /// live (in order, or a random not-yet-played song when shuffled).
  Future<void> _playNext() async {
    _endCheck?.cancel();
    _startTimeout?.cancel();
    _prefetch?.cancel();
    var next = _prepared;
    _prepared = null;
    // A member who left (or was hidden) since we prepared their song.
    if (next != null && !party.members.contains(next.member)) next = null;
    next ??= await _resolveNext();
    if (next != null) {
      if (next.index != null) {
        await _startContext(next.member, next.entry, next.index!);
      } else {
        await _startTrack(next.member, next.entry, next.track!);
      }
      return;
    }
    _expectedUri = null;
    current = null;
    currentMember = null;
    party.removeIdle();
    status = 'Waiting for songs';
    unawaited(HostForeground.update(status));
    await _persistParty();
    notifyListeners();
    broadcast();
  }

  /// Works out whose song plays next and which song that is — including any
  /// network lookups — without touching playback.
  Future<({Member member, QueueItem entry, Track? track, int? index})?>
  _resolveNext() async {
    for (final member in party.candidates()) {
      var guard = 0;
      while (guard++ < 8) {
        final entry = party.plan(member, _rng);
        if (entry == null) break;
        Track? track;
        var done = false;
        if (entry.track != null) {
          track = entry.track;
        } else if (entry.playlist!.viaApp) {
          // Can't read the items: play by index through the Spotify app.
          final r = await _nextIndex(member, entry.playlist!);
          if (r == null) {
            party.commit(member, entry, playlistDone: true);
            if (member.repeat) party.dequeue(member.uuid, entry.id);
            continue;
          }
          party.commit(member, entry, playlistDone: r.$2);
          return (member: member, entry: entry, track: null, index: r.$1);
        } else {
          try {
            final r = await _fromPlaylist(member, entry.playlist!);
            if (r == null) {
              done = true;
            } else {
              track = r.$1;
              done = r.$2;
            }
          } catch (e) {
            lastError = 'Playlist "${entry.playlist!.name}": $e';
            notifyListeners();
            break; // this member's turn fails; try the next member
          }
        }
        if (track == null) {
          // Playlist offered nothing (empty, all unplayable, or finished).
          party.commit(member, entry, playlistDone: true);
          if (member.repeat) party.dequeue(member.uuid, entry.id);
          continue;
        }
        party.commit(member, entry, playlistDone: done);
        return (member: member, entry: entry, track: track, index: null);
      }
    }
    return null;
  }

  /// Resolves the next song ahead of time (see [_prepared]).
  Future<void> _prepareNext() async {
    if (phase != HostPhase.running) return;
    // A good moment to notice where the music is coming out: off the
    // critical path, and current by the time the next song starts.
    unawaited(_learnDevice());
    if (_prepared != null) return;
    try {
      _prepared = await _resolveNext();
    } catch (e) {
      lastError = 'Preparing the next song: $e';
      notifyListeners();
    }
  }

  Future<void> _startTrack(Member member, QueueItem entry, Track track) async {
    interlude = false;
    current = QueueItem(id: '${entry.id}:${track.id}', track: track);
    currentMember = member;
    party.removeIdle(playing: member.uuid);
    _expectedUri = track.uri;
    _sawPlaying = false;
    _lastPos = 0;
    _positionMs = 0;
    _positionAt = DateTime.now();
    paused = false;
    _durationMs = track.durationMs;
    _startAttempts = 0;
    _log('play "${track.name}" for ${member.name}');
    await _persistParty();
    notifyListeners();
    await _issuePlay();
    broadcast();
  }

  /// Next index to play from a playlist the host can't read (in order, or a
  /// random not-yet-played index), and whether the entry is then done for
  /// this cycle. Refreshes the total from Spotify's metadata when possible.
  /// Name and length of a playlist: from the Web API when Spotify is willing
  /// (the host's own and collaborative playlists), otherwise from the public
  /// embed page, which lists at most 100 songs — so a length of exactly 100
  /// is reported as unknown and left to the play-through discovery.
  Future<({String name, int? total})> playlistMeta(
    String id, {
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    final hit = _metaCache[id];
    if (hit != null && DateTime.now().difference(hit.at) < maxAge) {
      return (name: hit.name, total: hit.total);
    }
    String? name;
    try {
      final token = await auth.validToken();
      if (token != null) {
        final meta = await SpotifyWebApi.playlistMeta(token, id);
        name = meta.name;
        if ((meta.total ?? 0) > 0) return (name: meta.name, total: meta.total);
      }
    } catch (_) {}
    final page = await SpotifyPublicPage.playlist(id);
    final result = page != null && !page.capped
        ? (name: name ?? page.name, total: page.count)
        : (name: name ?? page?.name ?? 'Playlist', total: null);
    _metaCache[id] = (
      at: DateTime.now(),
      name: result.name,
      total: result.total,
    );
    return result;
  }

  Future<(int, bool)?> _nextIndex(Member m, PlaylistRef pl) async {
    // Songs come and go while the party runs, so the length is re-read every
    // time we pick from the playlist. This runs in the prefetch, a good ten
    // seconds before the song is needed, so nobody waits for it.
    try {
      final before = pl.total;
      final meta = await playlistMeta(pl.id);
      pl.name = meta.name;
      if ((meta.total ?? 0) > 0) {
        pl.resize(meta.total!);
        if (before > 0 && pl.total != before) {
          _log('"${pl.name}" is now ${pl.total} songs (was $before)');
        }
      }
    } catch (_) {}
    // Length unknown (Spotify withholds it for playlists the host neither
    // owns nor collaborates on): play through in order — running past the
    // last item is how we learn how long it is. Shuffle kicks in from the
    // second pass, when the length is known.
    if (!pl.totalKnown) {
      if (!pl.viaApp) return null;
      return (pl.nextIndex++, false);
    }
    if (!m.shuffle) {
      if (pl.nextIndex >= pl.total) return null;
      final idx = pl.nextIndex++;
      return (idx, pl.nextIndex >= pl.total);
    }
    final free = [
      for (var i = 0; i < pl.total; i++)
        if (!pl.playedIds.contains('#$i')) i,
    ];
    if (free.isEmpty) return null;
    final idx = free[_rng.nextInt(free.length)];
    pl.playedIds.add('#$idx');
    return (idx, pl.playedIds.length >= pl.total);
  }

  /// Starts item [idx] of a playlist the host can't read, via the Spotify app.
  /// The actual track is learnt from the first player state that shows it.
  Future<void> _startContext(Member member, QueueItem entry, int idx) async {
    final pl = entry.playlist!;
    interlude = false;
    _awaitingContext = true;
    _contextEntry = entry;
    current = QueueItem(
      id: '${entry.id}:#$idx',
      track: Track(
        id: '',
        name: '${pl.name} · #${idx + 1}',
        artists: 'starting…',
        durationMs: 0,
      ),
    );
    currentMember = member;
    party.removeIdle(playing: member.uuid);
    _expectedUri = null;
    _sawPlaying = false;
    _lastPos = 0;
    _positionMs = 0;
    _positionAt = DateTime.now();
    paused = false;
    _durationMs = 0;
    _startAttempts = 0;
    _log('play item ${idx + 1} of "${pl.name}" for ${member.name}');
    await _persistParty();
    notifyListeners();
    await _issuePlayIndex(pl.uri, idx);
    broadcast();
  }

  Future<void> _issuePlayIndex(String contextUri, int idx) async {
    _startAttempts++;
    try {
      await _startPlayback(contextUri: contextUri, index: idx);
      status = 'Playing for ${currentMember?.name} (from a playlist)';
    } catch (e) {
      lastError = 'Play playlist item failed: $e';
      _log('playlist item command failed: $e');
    }
    notifyListeners();
    _startTimeout?.cancel();
    // Nothing started: either Spotify is busy, or we asked for an item past
    // the end of a playlist whose length we don't know — which is exactly how
    // we find that length out.
    _startTimeout = Timer(const Duration(seconds: 5), () {
      if (!_awaitingContext) return;
      if (_startAttempts < 2) {
        unawaited(_issuePlayIndex(contextUri, idx));
      } else {
        _endOfContext(idx);
      }
    });
  }

  /// Item [idx] wouldn't play: treat it as the end of the playlist, remember
  /// the length we just learnt, and move on.
  void _endOfContext(int idx) {
    final pl = _contextEntry?.playlist;
    if (pl != null && !pl.totalKnown && idx > 0) {
      pl.total = idx; // items 0..idx-1 exist, idx doesn't
      pl.nextIndex = idx;
      status = '${pl.name} has $idx songs';
      _log('"${pl.name}" turned out to have $idx songs');
      unawaited(_persistParty());
    } else {
      lastError = 'Spotify did not start item ${idx + 1}; skipping it';
    }
    _awaitingContext = false;
    _finishCurrent();
  }

  /// Builds a [Track] from what App Remote reports is playing.
  Track _trackFromState(PlayerState s) {
    final t = s.track!;
    final artists = t.artists
        .map((a) => a.name)
        .whereType<String>()
        .where((n) => n.isNotEmpty)
        .join(', ');
    final raw = t.imageUri.raw;
    final image = raw.startsWith('spotify:image:')
        ? 'https://i.scdn.co/image/${raw.substring('spotify:image:'.length)}'
        : null;
    return Track(
      id: Track.idFromUri(t.uri) ?? t.uri,
      name: t.name,
      artists: artists.isEmpty ? (t.artist.name ?? '') : artists,
      durationMs: t.duration,
      imageUrl: image,
    );
  }

  /// Cuts the song a moment before its end and starts the next one, so
  /// Spotify never gets to continue a playlist context or autoplay something
  /// of its own.
  ///
  /// It deliberately does not pause first: the switch has to be a single play
  /// command, or the gap between pausing and playing is exactly the opening
  /// Spotify uses to pick its own music (and we'd lose control of the
  /// session). If we don't know yet what comes next, the song is left to play
  /// out rather than cut into silence.
  Future<void> _preemptEnd() async {
    if (_expectedUri == null || takenOver || paused) return;
    if (_prepared == null) await _prepareNext();
    if (_prepared == null) {
      _log('nothing queued to switch to — letting the song play out');
      return;
    }
    _log('cut "${current?.track?.name}" just before its end');
    _finishCurrent();
  }

  /// Next song from a playlist entry, reading Spotify live. Returns the track
  /// and whether the entry has now offered all its songs this cycle; null when
  /// there is nothing (left) to play. In-order mode tracks an offset (so
  /// reordering the playlist in Spotify shifts what comes next); shuffle mode
  /// tracks played track ids (robust to edits).
  Future<(Track, bool)?> _fromPlaylist(Member m, PlaylistRef pl) async {
    final token = await auth.validToken();
    if (token == null) throw StateError('no Spotify token');
    if (!m.shuffle) {
      var guard = 0;
      while (guard++ < 20) {
        final page = await SpotifyWebApi.playlistPage(
          token,
          pl.id,
          pl.nextIndex,
          limit: 10,
        );
        pl.total = page.total;
        if (pl.nextIndex >= pl.total || page.fetched == 0) return null;
        for (final (off, t) in page.items) {
          if (off >= pl.nextIndex) {
            pl.nextIndex = off + 1;
            return (t, pl.nextIndex >= pl.total);
          }
        }
        pl.nextIndex += page.fetched; // page had nothing playable
      }
      return null;
    }
    final head = await SpotifyWebApi.playlistPage(token, pl.id, 0, limit: 1);
    pl.total = head.total;
    if (pl.total == 0) return null;
    var off = _rng.nextInt(pl.total);
    var scanned = 0;
    while (scanned < pl.total) {
      final page = await SpotifyWebApi.playlistPage(
        token,
        pl.id,
        off,
        limit: 20,
      );
      if (page.fetched == 0) break;
      for (final (_, t) in page.items) {
        if (pl.playedIds.add(t.id)) {
          return (t, pl.playedIds.length >= pl.total);
        }
      }
      scanned += page.fetched;
      off = (off + page.fetched) % pl.total;
    }
    return null;
  }

  /// Starts something playing, preferring Spotify Connect over App Remote.
  ///
  /// App Remote talks to the Spotify app on this phone and can pull playback
  /// off a speaker the phone was casting to; a Connect play command with no
  /// device carries on wherever Spotify is already playing. The app is still
  /// the fallback for when there is no active device to talk to (nothing has
  /// played yet) or the Web API refuses.
  Future<bool> _startPlayback({
    String? uri,
    String? contextUri,
    int? index,
  }) async {
    final token = await auth.validToken();
    if (token != null) {
      // Pinned to a speaker: say so explicitly. "Wherever Spotify is playing"
      // is no help when the speaker has gone idle — Spotify then falls back
      // to whatever was used last, which is usually this phone, since App
      // Remote keeps its Spotify app awake.
      final pinned = HostSettings.deviceId;
      if (pinned != null) {
        try {
          await SpotifyWebApi.playHere(
            token,
            uri: uri,
            contextUri: contextUri,
            index: index,
            deviceId: pinned,
          );
          return true;
        } catch (e) {
          _log('"${HostSettings.deviceName}" would not take it ($e)');
        }
      }
      try {
        await SpotifyWebApi.playHere(
          token,
          uri: uri,
          contextUri: contextUri,
          index: index,
        );
        return true;
      } catch (e) {
        _log('Spotify Connect refused ($e)');
      }
      // Nothing was playing (an idle speaker drops off Spotify), so there was
      // no "here" to play on. Aim at the device the party was last coming out
      // of before falling back to this phone's own speaker.
      final device = _ourDeviceId;
      if (device != null) {
        try {
          await SpotifyWebApi.playHere(
            token,
            uri: uri,
            contextUri: contextUri,
            index: index,
            deviceId: device,
          );
          _log('woke "$ourDeviceName" back up');
          return true;
        } catch (e) {
          _log('"$ourDeviceName" would not take it ($e)');
        }
      }
    }
    _log('playing through the Spotify app on this phone');
    if (uri != null) {
      await player.play(uri);
    } else {
      await player.playIndex(contextUri!, index!);
    }
    return false;
  }

  Future<void> _issuePlay() async {
    final uri = _expectedUri;
    if (uri == null) return;
    _startAttempts++;
    try {
      await _startPlayback(uri: uri);
      status = 'Playing for ${currentMember?.name}';
      unawaited(
        HostForeground.update(
          '${current?.track?.name} — ${currentMember?.name}',
        ),
      );
    } catch (e) {
      lastError = 'Play failed: $e';
      _log('play command failed: $e');
    }
    notifyListeners();
    _startTimeout?.cancel();
    _startTimeout = Timer(const Duration(seconds: 10), () {
      if (_expectedUri != uri || _sawPlaying) return;
      if (_startAttempts < 3) {
        unawaited(_issuePlay());
      } else {
        lastError =
            'Spotify did not start ${current?.track?.name}; skipping it';
        _finishCurrent();
      }
    });
  }

  void _onPlayerState(PlayerState s) {
    if (_awaitingContext) {
      final t = s.track;
      // The first state showing a *new* playing track is our playlist item.
      if (t != null && !s.isPaused && t.uri != _lastFinishedUri) {
        _awaitingContext = false;
        _startTimeout?.cancel();
        final adopted = _trackFromState(s);
        current = QueueItem(id: current?.id ?? adopted.id, track: adopted);
        _expectedUri = t.uri;
        _durationMs = adopted.durationMs;
        unawaited(
          HostForeground.update('${adopted.name} — ${currentMember?.name}'),
        );
        unawaited(_persistParty());
        broadcast();
      } else {
        return;
      }
    }
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
        final cm = currentMember;
        if (cm != null) {
          party.credit(cm.uuid, pos - _lastPos);
          _persistThrottled();
        }
        _lastPos = pos;
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
    _preempt?.cancel();
    _prefetch?.cancel();
    if (!s.isPaused && duration > 0) {
      _endCheck = Timer(
        Duration(milliseconds: max(0, duration - pos) + 2500),
        _checkEnd,
      );
      final untilCut = duration - pos - Config.preemptEnd.inMilliseconds;
      if (untilCut > 0) {
        _preempt = Timer(Duration(milliseconds: untilCut), _preemptEnd);
      }
      final untilPrefetch =
          duration - pos - Config.prefetchBeforeEnd.inMilliseconds;
      _prefetch = Timer(
        Duration(milliseconds: max(0, untilPrefetch)),
        () => unawaited(_prepareNext()),
      );
    }
    if (pausedChanged) broadcast();
    notifyListeners();
  }

  /// Everything Spotify could play on right now, for the host's picker.
  Future<List<({String id, String name, String type, bool isActive})>>
  availableDevices() async {
    final token = await auth.validToken();
    if (token == null) return const [];
    return (await SpotifyWebApi.devices(token)).devices;
  }

  /// Pins the party to a speaker (null = follow whatever Spotify is playing
  /// on) and moves the song that is playing there right away.
  Future<void> pinDevice(String? id, String? name) async {
    await HostSettings.setDevice(id, name);
    _log(
      id == null
          ? 'following Spotify\'s own device'
          : 'playing on "$name" from now on',
    );
    notifyListeners();
    final cur = current?.track;
    if (id == null || cur == null) return;
    try {
      final token = await auth.validToken();
      if (token == null) return;
      await SpotifyWebApi.playOn(token, id, cur.uri, positionMs);
      _ourDeviceId = id;
      ourDeviceName = name;
      _sawPlaying = false;
    } catch (e) {
      lastError = 'Could not move playback to $name: $e';
      _log('could not move playback to "$name" ($e)');
    }
    notifyListeners();
  }

  /// Notes which Spotify Connect device the party is coming out of — the
  /// phone, or a speaker it is casting to. Songs are started on that device
  /// when a plain "play where Spotify is playing" command doesn't work, so
  /// the party doesn't fall back onto the phone's own speaker.
  Future<void> _learnDevice() async {
    if (_checkingDevice) return;
    _checkingDevice = true;
    try {
      final token = await auth.validToken();
      if (token == null) return;
      final snap = await SpotifyWebApi.player(token);
      final d = snap?.device;
      if (d == null) return;
      if (d.id != _ourDeviceId) {
        if (_ourDeviceId != null) {
          _log('playing on "${d.name}" now (was "$ourDeviceName")');
        } else {
          _log('playing on "${d.name}"');
        }
        _ourDeviceId = d.id;
        ourDeviceName = d.name;
        notifyListeners();
      }
    } catch (_) {
      // Without device info we just keep using the last one we saw.
    } finally {
      _checkingDevice = false;
    }
  }

  /// A track that isn't ours is playing.
  ///
  /// Telling "Spotify walked on to the next track by itself" apart from
  /// "someone took the account over" is guesswork at the moment a song ends —
  /// and guessing "taken over" stops the party, which is much worse than
  /// guessing wrong the other way. So the party simply takes the session
  /// back: near the end of a song that means playing the next song (the
  /// normal handover), mid-song it means cutting the intruder off with the
  /// party's next song. Only when that keeps happening does it accept that
  /// someone else wants the account and show the banner.
  Future<void> _onForeignTrack() async {
    if (takenOver || _expectedUri == null) return;
    final nearEnd =
        _durationMs == 0 ||
        positionMs >= _durationMs - Config.endOfSongWindow.inMilliseconds;
    if (nearEnd) {
      _log('Spotify moved on at the end of our song — playing the next one');
      _finishCurrent();
      return;
    }

    final now = DateTime.now();
    _interruptions
      ..add(now)
      ..removeWhere((t) => now.difference(t) > Config.interruptionWindow);
    if (_interruptions.length < Config.interruptionsBeforeGivingUp) {
      _log(
        'something else started playing mid-song '
        '(${_interruptions.length}) — taking the party back',
      );
      _finishCurrent();
      return;
    }

    // It keeps happening: stop fighting and say who we are fighting.
    _interruptions.clear();
    var who = 'another device';
    var local = true;
    try {
      final token = await auth.validToken();
      final snap = token == null ? null : await SpotifyWebApi.player(token);
      final d = snap?.device;
      if (d != null && (_ourDeviceId == null || d.id != _ourDeviceId)) {
        who = d.name;
        local = false;
      }
    } catch (_) {}
    _log('gave up after ${Config.interruptionsBeforeGivingUp} interruptions');
    _enterTakenOver(who, local: local);
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
    _preempt?.cancel();
    status = local
        ? 'Someone keeps playing other music here — party paused'
        : 'Spotify keeps being pulled to $deviceName — party paused';
    notice = local
        ? 'Party paused: someone keeps playing other music in Spotify on the host phone'
        : 'Party paused: Spotify keeps being pulled to $deviceName';
    noticeAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(HostForeground.update(status));
    notifyListeners();
    broadcast();
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
    _interruptions.clear();
    _exitTakenOver();
    final cur = current;
    if (cur == null) {
      unawaited(_playNext());
      return;
    }
    _sawPlaying = false;
    try {
      final token = await auth.validToken();
      final dev = _ourDeviceId;
      if (token != null && dev != null) {
        await SpotifyWebApi.playOn(token, dev, cur.track!.uri, _lastPos);
      } else {
        await player.play(cur.track!.uri);
      }
      status = 'Taking playback back…';
    } catch (e) {
      lastError = 'Take back: $e';
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
    _preempt?.cancel();
    _lastFinishedUri = _expectedUri;
    _awaitingContext = false;
    _contextEntry = null;
    _expectedUri = null;
    current = null;
    currentMember = null;
    interlude = false;
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

  /// Sets a member aside (someone who left the room with a live queue):
  /// invisible to everyone, queue kept, their playing song (if any) finishes
  /// undisturbed. Only an explicit rejoin from their page brings them back.
  void parkMember(String memberUuid) {
    if (!party.park(memberUuid)) return;
    unawaited(_persistParty());
    notifyListeners();
    broadcast();
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
    if (m.version > Config.protocolVersion &&
        (newerMemberVersion ?? 0) < m.version) {
      newerMemberVersion = m.version;
      notifyListeners();
    }
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
        if (cur == null || m.body['trackId'] != cur.track!.id) return;
        final remaining = max(0, _durationMs - positionMs);
        final who = party.listener(uuid)?.name ?? 'Someone';
        if (interlude) {
          notice = '$who skipped ${cur.track!.name} (not a party song — free)';
        } else {
          party.penalize(uuid, name, remaining, now);
          notice =
              '$who skipped ${cur.track!.name} '
              '(+${formatMs(remaining)} to ${who == name ? 'their' : who}\'s airtime)';
        }
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
      case MsgType.resolve:
        final rid = m.body['rid'];
        final url = m.body['url'];
        if (rid is! String || url is! String) return;
        unawaited(() async {
          String? full;
          try {
            full = await SpotifyLink.resolveShort(url);
          } catch (_) {}
          try {
            await switchClient.send(
              uuid,
              Message(
                type: MsgType.resolved,
                body: {'rid': rid, 'url': ?full},
              ).toData(),
            );
          } catch (e) {
            lastError = 'Resolve reply: $e';
            notifyListeners();
          }
        }());
      case MsgType.rejoin:
        if (party.unpark(uuid, now)) {
          unawaited(_persistParty());
          notifyListeners();
          _maybePlayNext();
          broadcast();
        } else {
          unawaited(_sendView(uuid));
        }
      case MsgType.playlistMeta:
        final rid = m.body['rid'];
        final plId = m.body['id'];
        if (rid is! String || plId is! String) return;
        unawaited(() async {
          ({String name, int? total})? meta;
          try {
            meta = await playlistMeta(plId);
          } catch (_) {}
          try {
            await switchClient.send(
              uuid,
              Message(
                type: MsgType.playlistMetaResult,
                body: {'rid': rid, 'name': ?meta?.name, 'total': ?meta?.total},
              ).toData(),
            );
          } catch (e) {
            lastError = 'Playlist meta reply: $e';
            notifyListeners();
          }
        }());
      case MsgType.modes:
        party.setModes(
          uuid,
          name,
          now,
          shuffle: m.body['shuffle'] as bool?,
          repeat: m.body['repeat'] as bool?,
        );
        party.removeIdle(playing: currentMember?.uuid);
        unawaited(_persistParty());
        notifyListeners();
        _maybePlayNext();
        broadcast();
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
    // A parked member still sees their kept queue (and a rejoin button).
    final parked = party.parkedMember(uuid);
    final me = party.member(uuid) ?? parked;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cur = current;
    final curMember = currentMember;
    return MemberView(
      hostName: identity.name ?? 'Host',
      token: auth.accessToken,
      tokenExpiresAt: auth.expiresAt?.millisecondsSinceEpoch ?? 0,
      now: cur == null
          ? null
          : NowInfo(
              track: cur.track!,
              memberUuid: curMember?.uuid ?? '',
              memberName: curMember?.name ?? 'Spotify (not from the party)',
              positionMs: positionMs,
              atMs: now,
              paused: paused,
            ),
      myPlayedMs: me?.playedMs ?? party.maxPlayedMs,
      myQueue: me == null ? const [] : List.of(me.queue),
      shuffle: me?.shuffle ?? false,
      repeat: me?.repeat ?? false,
      cursor: me?.cursor ?? 0,
      pausedByHost: parked != null,
      others: [
        for (final m in party.members)
          if (m.uuid != uuid)
            OtherInfo(
              uuid: m.uuid,
              name: m.name,
              playedMs: m.playedMs,
              queueLength: m.remaining(m.shuffle),
              nextTrack: m.queue.isEmpty
                  ? null
                  : m.shuffle
                  ? null
                  : m.queue[m.cursor < m.queue.length ? m.cursor : 0].title,
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
    if (cur != null && cm != null && !cm.repeat) {
      for (final m in json['members'] as List) {
        if ((m as Map)['uuid'] == cm.uuid) {
          (m['queue'] as List).insert(0, cur.toJson());
        }
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_partyKey, jsonEncode(json));
    if (cur != null && cm != null) {
      await prefs.setString(
        _currentKey,
        jsonEncode({'m': cm.uuid, 'item': cur.toJson()}),
      );
    } else {
      await prefs.remove(_currentKey);
    }
  }

  /// On start: if Spotify is already playing something that isn't ours, don't
  /// cut it off — track it as an interlude and take over when it ends (or is
  /// skipped). Returns true when such a song was adopted.
  Future<bool> _letForeignFinish() async {
    try {
      final s = await player.state();
      final t = s?.track;
      if (s == null || t == null || s.isPaused) return false;
      final id = Track.idFromUri(t.uri);
      if (id == null) return false; // podcasts, local files: not our business
      final artists = t.artists
          .map((a) => a.name)
          .whereType<String>()
          .where((n) => n.isNotEmpty)
          .join(', ');
      final track = Track(
        id: id,
        name: t.name,
        artists: artists.isEmpty ? (t.artist.name ?? '') : artists,
        durationMs: t.duration,
      );
      interlude = true;
      current = QueueItem(id: 'interlude:$id', track: track);
      currentMember = null;
      _expectedUri = t.uri;
      _sawPlaying = true;
      _lastPos = s.playbackPosition;
      _positionMs = s.playbackPosition;
      _positionAt = DateTime.now();
      paused = false;
      _durationMs = t.duration;
      _startAttempts = 0;
      status = 'Letting Spotify finish "${t.name}" before the party takes over';
      unawaited(HostForeground.update(status));
      _onPlayerState(s);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// After a restart: if the Spotify app is still on the song we were
  /// playing, pick it up where it is instead of starting over (or jumping to
  /// someone else's song). Returns true if playback was adopted.
  Future<bool> _tryResume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_currentKey);
      if (raw == null) return false;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final item = QueueItem.fromJson(j['item'] as Map<String, dynamic>);
      final memberUuid = j['m'] as String;
      final track = item.track;
      final member = party.member(memberUuid);
      if (track == null || member == null) return false;
      final s = await player.state();
      final playing = s?.track;
      if (s == null || playing == null) return false;
      final same =
          playing.uri == track.uri || playing.linkedFromUri == track.uri;
      final pos = s.playbackPosition;
      if (!same || (s.isPaused && pos == 0)) return false;
      // The restart re-queued this song at the head (repeat off): consume it.
      party.dequeue(memberUuid, item.id);
      current = item;
      currentMember = member;
      party.removeIdle(playing: memberUuid);
      _expectedUri = track.uri;
      _sawPlaying = true;
      _lastPos = pos; // airtime up to here was persisted before the restart
      _positionMs = pos;
      _positionAt = DateTime.now();
      paused = s.isPaused;
      _durationMs = playing.duration > 0 ? playing.duration : track.durationMs;
      _startAttempts = 0;
      status = 'Resumed ${track.name} for ${member.name} where Spotify was';
      unawaited(HostForeground.update('${track.name} — ${member.name}'));
      await _persistParty();
      _onPlayerState(s); // arms the end-of-track timer
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
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
