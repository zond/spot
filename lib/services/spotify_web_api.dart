import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/track.dart';

class SpotifyApiException implements Exception {
  SpotifyApiException(this.status, this.body);
  final int status;
  final String body;
  bool get isUnauthorized => status == 401;
  @override
  String toString() => 'Spotify API $status: ${body.trim()}';
}

/// A Spotify link (open.spotify.com/...) or URI (spotify:track:...) a member
/// pasted or shared from the Spotify app.
class SpotifyLink {
  const SpotifyLink(this.type, this.id);
  final String type; // track | playlist | album
  final String id;

  static final _url = RegExp(
    r'open\.spotify\.com/(?:[a-z]{2}(?:-[A-Za-z]{2})?/)?(track|playlist|album)/([A-Za-z0-9]+)',
  );
  static final _uri = RegExp(r'spotify:(track|playlist|album):([A-Za-z0-9]+)');

  static SpotifyLink? parse(String text) {
    final m = _url.firstMatch(text) ?? _uri.firstMatch(text);
    if (m == null) return null;
    return SpotifyLink(m.group(1)!, m.group(2)!);
  }

  /// Spotify's short share links (open.spotify.com/s/…, spotify.link/…,
  /// spotify.app.link/…) hide the real URL behind redirects; returns the
  /// short URL found in [text], if any, so it can be resolved (by the host).
  static final _short = RegExp(
    r'https?://(?:open\.spotify\.com/s/|spotify\.link/|spotify\.app\.link/)[^\s)]+',
  );

  static String? shortUrl(String text) =>
      parse(text) == null ? _short.firstMatch(text)?.group(0) : null;

  /// Follows a short link's redirects (no CORS in the host app) and returns
  /// the real open.spotify.com URL, or null. Looks in every hop's URL and
  /// Location header (URL-decoded — app.link carries it as a parameter) and
  /// finally in the page body.
  static Future<String?> resolveShort(String url) async {
    final client = http.Client();
    try {
      var current = Uri.parse(url);
      for (var hop = 0; hop < 8; hop++) {
        final found = _findFull(current.toString());
        if (found != null) return found;
        final req = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] =
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36';
        final resp = await client
            .send(req)
            .timeout(const Duration(seconds: 10));
        final loc = resp.headers['location'];
        if (resp.isRedirect && loc != null) {
          current = current.resolve(loc);
          final f = _findFull(current.toString());
          if (f != null) return f;
          continue;
        }
        final body = await resp.stream.bytesToString();
        return _findFull(body);
      }
      return null;
    } finally {
      client.close();
    }
  }

  static String? _findFull(String s) {
    String decoded;
    try {
      decoded = Uri.decodeFull(s);
    } catch (_) {
      decoded = s;
    }
    final m = _url.firstMatch(decoded) ?? _url.firstMatch(s);
    if (m == null) return null;
    return 'https://open.spotify.com/${m.group(1)}/${m.group(2)}';
  }
}

/// Tracks of a playlist or album (or a single shared track). Playlists load
/// page by page: [tracks] holds what has been fetched so far, [total] how
/// many there are, and [nextOffset] where to continue (null = complete).
class TrackCollection {
  TrackCollection({
    required this.kind,
    required this.name,
    required this.tracks,
    this.id,
    int? total,
    this.nextOffset,
    this.viaApp = false,
  }) : total = total ?? tracks.length;
  final String kind;
  final String name;
  final String? id;
  final List<Track> tracks;
  int total;
  int? nextOffset;

  /// Items can't be read (not the host's playlist); only name/total known.
  /// The host can still play it through the Spotify app by index.
  final bool viaApp;
  bool get complete => nextOffset == null;
}

/// Where the account is playing right now (GET /me/player).
class PlaybackDevice {
  const PlaybackDevice({
    required this.id,
    required this.name,
    required this.type,
  });
  final String id;
  final String name;
  final String type;
}

class PlayerSnapshot {
  const PlayerSnapshot({this.device, required this.isPlaying, this.trackId});
  final PlaybackDevice? device;
  final bool isPlaying;
  final String? trackId;
}

/// The bits of the Spotify Web API the party uses. Works with any valid user
/// access token — members use the host's. Stays within what Development Mode
/// apps may call (Feb 2026 rules): search ≤ 10, single-item lookups,
/// playlists by id (user-created ones), no batch or browse endpoints.
abstract final class SpotifyWebApi {
  static Future<Map<String, dynamic>> _get(String token, Uri uri) async {
    final resp = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw SpotifyApiException(resp.statusCode, resp.body);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// The account's current playback and active device; null when Spotify
  /// reports nothing playing anywhere (204). Needs user-read-playback-state.
  static Future<PlayerSnapshot?> player(String token) async {
    final resp = await http
        .get(
          Uri.https('api.spotify.com', '/v1/me/player'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 204 || resp.body.trim().isEmpty) return null;
    if (resp.statusCode != 200) {
      throw SpotifyApiException(resp.statusCode, resp.body);
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final d = j['device'] as Map?;
    return PlayerSnapshot(
      device: d == null || d['id'] == null
          ? null
          : PlaybackDevice(
              id: d['id'] as String,
              name: d['name'] as String? ?? 'Unknown device',
              type: d['type'] as String? ?? '',
            ),
      isPlaying: j['is_playing'] == true,
      trackId: (j['item'] as Map?)?['id'] as String?,
    );
  }

  /// Starts [uri] on [deviceId] at [positionMs] (transfers playback there).
  /// Needs user-modify-playback-state.
  static Future<void> playOn(
    String token,
    String deviceId,
    String uri,
    int positionMs,
  ) async {
    final resp = await http
        .put(
          Uri.https('api.spotify.com', '/v1/me/player/play', {
            'device_id': deviceId,
          }),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'uris': [uri],
            'position_ms': positionMs,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 204 &&
        resp.statusCode != 202 &&
        resp.statusCode != 200) {
      throw SpotifyApiException(resp.statusCode, resp.body);
    }
  }

  static Future<Track> track(String token, String id) async =>
      Track.fromSpotify(
        await _get(token, Uri.https('api.spotify.com', '/v1/tracks/$id')),
      );

  /// Name and item count of a playlist — Spotify still hands these out for
  /// other people's playlists (only the items are restricted).
  static Future<({String name, int total})> playlistMeta(
    String token,
    String id,
  ) async {
    final meta = await _get(
      token,
      Uri.https('api.spotify.com', '/v1/playlists/$id', {
        'fields': 'name,tracks.total,items.total',
      }),
    );
    final total =
        ((meta['items'] as Map?)?['total'] ??
                (meta['tracks'] as Map?)?['total'])
            as num?;
    return (
      name: meta['name'] as String? ?? 'Playlist',
      total: total?.toInt() ?? 0,
    );
  }

  /// A playlist's name and its first page of tracks; call [loadMore] for the
  /// rest (episodes and unavailable items are skipped). If Spotify refuses
  /// the items (403: not the token owner's playlist), returns a [viaApp]
  /// collection with just name and total.
  static Future<TrackCollection> playlist(String token, String id) async {
    final meta = await playlistMeta(token, id);
    final col = TrackCollection(
      kind: 'Playlist',
      name: meta.name,
      id: id,
      tracks: [],
      total: meta.total,
      nextOffset: 0,
    );
    try {
      await loadMore(token, col);
    } on SpotifyApiException catch (e) {
      if (e.status != 403) rethrow;
      return TrackCollection(
        kind: 'Playlist',
        name: meta.name,
        id: id,
        tracks: [],
        total: meta.total,
        viaApp: true,
      );
    }
    return col;
  }

  static int _playlistPageSize = 50;

  /// Raw page of playlist items from [offset]: (offset, Track) for playable
  /// tracks, the number of raw items the page held, and the playlist total.
  static Future<({List<(int, Track)> items, int fetched, int total})>
  playlistPage(String token, String id, int offset, {int limit = 20}) async {
    var lim = limit > _playlistPageSize ? _playlistPageSize : limit;
    while (true) {
      try {
        final page = await _get(
          token,
          Uri.https('api.spotify.com', '/v1/playlists/$id/items', {
            'limit': '$lim',
            'offset': '$offset',
          }),
        );
        final raw = page['items'] as List? ?? const [];
        final items = <(int, Track)>[];
        for (var i = 0; i < raw.length; i++) {
          final t = ((raw[i] as Map)['track'] ?? raw[i]['item']) as Map?;
          if (t == null ||
              t['id'] == null ||
              (t['type'] ?? 'track') != 'track') {
            continue;
          }
          items.add((offset + i, Track.fromSpotify(t.cast<String, dynamic>())));
        }
        return (
          items: items,
          fetched: raw.length,
          total: (page['total'] as num?)?.toInt() ?? (offset + raw.length),
        );
      } on SpotifyApiException catch (e) {
        if (e.status == 400 && lim > 10 && e.body.contains('limit')) {
          _playlistPageSize = 10;
          lim = 10;
          continue;
        }
        rethrow;
      }
    }
  }

  /// Fetches the next page of a playlist into [col]. Returns false when there
  /// was nothing more to load.
  static Future<bool> loadMore(String token, TrackCollection col) async {
    final id = col.id;
    final offset = col.nextOffset;
    if (id == null || offset == null) return false;
    Map<String, dynamic> page;
    while (true) {
      try {
        page = await _get(
          token,
          Uri.https('api.spotify.com', '/v1/playlists/$id/items', {
            'limit': '$_playlistPageSize',
            'offset': '$offset',
          }),
        );
        break;
      } on SpotifyApiException catch (e) {
        if (e.status == 400 &&
            _playlistPageSize > 10 &&
            e.body.contains('limit')) {
          _playlistPageSize = 10; // Development Mode caps page size too
          continue;
        }
        rethrow;
      }
    }
    final items = page['items'] as List? ?? const [];
    for (final it in items) {
      final t = ((it as Map)['track'] ?? it['item']) as Map?;
      if (t == null || t['id'] == null || (t['type'] ?? 'track') != 'track') {
        continue;
      }
      col.tracks.add(Track.fromSpotify(t.cast<String, dynamic>()));
    }
    col.total = (page['total'] as num?)?.toInt() ?? (offset + items.length);
    col.nextOffset = items.isEmpty || page['next'] == null
        ? null
        : offset + items.length;
    return items.isNotEmpty;
  }

  static Future<TrackCollection> album(String token, String id) async {
    final a = await _get(token, Uri.https('api.spotify.com', '/v1/albums/$id'));
    final images = a['images'] as List?;
    final items = ((a['tracks'] as Map?)?['items'] as List?) ?? const [];
    final tracks = [
      for (final t in items)
        Track.fromSpotify({
          ...(t as Map).cast<String, dynamic>(),
          'album': {'images': images ?? const []},
        }),
    ];
    return TrackCollection(
      kind: 'Album',
      name: a['name'] as String? ?? 'Album',
      tracks: tracks,
    );
  }

  static Future<TrackCollection> fromLink(String token, SpotifyLink link) =>
      switch (link.type) {
        'track' => track(token, link.id).then(
          (t) => TrackCollection(kind: 'Track', name: t.name, tracks: [t]),
        ),
        'playlist' => playlist(token, link.id),
        _ => album(token, link.id),
      };

  static Future<List<Track>> search(
    String token,
    String query, {
    int limit = 10, // Development Mode apps: max 10 per request
    String? market,
  }) async {
    final json = await _get(
      token,
      Uri.https('api.spotify.com', '/v1/search', {
        'q': query,
        'type': 'track',
        'limit': '$limit',
        'market': ?market,
      }),
    );
    final items = (json['tracks'] as Map?)?['items'] as List? ?? const [];
    return items
        .map((i) => Track.fromSpotify(i as Map<String, dynamic>))
        .toList();
  }
}
