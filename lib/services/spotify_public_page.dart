import 'dart:convert';

import 'package:http/http.dart' as http;

/// Facts read off Spotify's public embed page (open.spotify.com/embed/…).
///
/// Spotify's Web API withholds the contents — and the length — of playlists
/// the token's user neither owns nor collaborates on, but the embed page of a
/// public playlist is served to anyone. Only the host can fetch it: browsers
/// refuse it (no CORS headers), the host phone doesn't care.
///
/// This is an undocumented page, not an API: treat every result as optional
/// and fall back to discovering the length by playing.
abstract final class SpotifyPublicPage {
  /// The embed page lists at most this many tracks, so a count this high
  /// means "at least this many", not "exactly this many".
  static const pageCap = 100;

  static final _nextData = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
    dotAll: true,
  );

  /// Name and number of songs of a public playlist. [capped] means the real
  /// playlist is longer than [count] (the page stopped listing at
  /// [pageCap]). Null when the page can't be read or parsed.
  static Future<({String name, int count, bool capped})?> playlist(
    String id,
  ) async {
    try {
      final resp = await http
          .get(
            Uri.parse('https://open.spotify.com/embed/playlist/$id'),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final match = _nextData.firstMatch(resp.body);
      if (match == null) return null;
      final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
      final entity =
          ((((data['props'] as Map?)?['pageProps'] as Map?)?['state']
                      as Map?)?['data']
                  as Map?)?['entity']
              as Map?;
      final list = entity?['trackList'] as List?;
      if (list == null) return null;
      return (
        name: entity?['name'] as String? ?? 'Playlist',
        count: list.length,
        capped: list.length >= pageCap,
      );
    } catch (_) {
      return null;
    }
  }
}
