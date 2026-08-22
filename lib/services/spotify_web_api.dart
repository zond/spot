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
      r'open\.spotify\.com/(?:[a-z]{2}(?:-[A-Za-z]{2})?/)?(track|playlist|album)/([A-Za-z0-9]+)');
  static final _uri = RegExp(r'spotify:(track|playlist|album):([A-Za-z0-9]+)');

  static SpotifyLink? parse(String text) {
    final m = _url.firstMatch(text) ?? _uri.firstMatch(text);
    if (m == null) return null;
    return SpotifyLink(m.group(1)!, m.group(2)!);
  }
}

/// Tracks of a playlist or album (or a single shared track).
class TrackCollection {
  const TrackCollection(
      {required this.kind, required this.name, required this.tracks});
  final String kind;
  final String name;
  final List<Track> tracks;
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

  static Future<Track> track(String token, String id) async =>
      Track.fromSpotify(
          await _get(token, Uri.https('api.spotify.com', '/v1/tracks/$id')));

  /// Up to [maxTracks] tracks of a playlist (episodes and unavailable items
  /// are skipped).
  static Future<TrackCollection> playlist(String token, String id,
      {int maxTracks = 300}) async {
    final meta = await _get(token,
        Uri.https('api.spotify.com', '/v1/playlists/$id', {'fields': 'name'}));
    final tracks = <Track>[];
    var offset = 0;
    var limit = 50;
    while (tracks.length < maxTracks) {
      final Map<String, dynamic> page;
      try {
        page = await _get(
            token,
            Uri.https('api.spotify.com', '/v1/playlists/$id/items',
                {'limit': '$limit', 'offset': '$offset'}));
      } on SpotifyApiException catch (e) {
        if (e.status == 400 && limit > 10 && e.body.contains('limit')) {
          limit = 10; // Development Mode may cap page size too
          continue;
        }
        rethrow;
      }
      final items = page['items'] as List? ?? const [];
      for (final it in items) {
        final t = ((it as Map)['track'] ?? it['item']) as Map?;
        if (t == null || t['id'] == null || (t['type'] ?? 'track') != 'track') {
          continue;
        }
        tracks.add(Track.fromSpotify(t.cast<String, dynamic>()));
      }
      offset += items.length;
      if (items.isEmpty || page['next'] == null) break;
    }
    return TrackCollection(
        kind: 'Playlist', name: meta['name'] as String? ?? 'Playlist',
        tracks: tracks);
  }

  static Future<TrackCollection> album(String token, String id) async {
    final a = await _get(token, Uri.https('api.spotify.com', '/v1/albums/$id'));
    final images = a['images'] as List?;
    final items = ((a['tracks'] as Map?)?['items'] as List?) ?? const [];
    final tracks = [
      for (final t in items)
        Track.fromSpotify({...(t as Map).cast<String, dynamic>(),
          'album': {'images': images ?? const []}}),
    ];
    return TrackCollection(
        kind: 'Album', name: a['name'] as String? ?? 'Album', tracks: tracks);
  }

  static Future<TrackCollection> fromLink(String token, SpotifyLink link) =>
      switch (link.type) {
        'track' => track(token, link.id).then((t) =>
            TrackCollection(kind: 'Track', name: t.name, tracks: [t])),
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
        }));
    final items = (json['tracks'] as Map?)?['items'] as List? ?? const [];
    return items
        .map((i) => Track.fromSpotify(i as Map<String, dynamic>))
        .toList();
  }
}
