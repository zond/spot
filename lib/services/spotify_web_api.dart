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

/// The bits of the Spotify Web API the party uses. Works with any valid user
/// access token — members use the host's.
abstract final class SpotifyWebApi {
  static Future<List<Track>> search(
    String token,
    String query, {
    int limit = 10, // Development Mode apps: max 10 per request
    String? market,
  }) async {
    final uri = Uri.https('api.spotify.com', '/v1/search', {
      'q': query,
      'type': 'track',
      'limit': '$limit',
      'market': ?market,
    });
    final resp = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw SpotifyApiException(resp.statusCode, resp.body);
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (json['tracks'] as Map?)?['items'] as List? ?? const [];
    return items
        .map((i) => Track.fromSpotify(i as Map<String, dynamic>))
        .toList();
  }
}
