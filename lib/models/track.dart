/// A Spotify track, trimmed to what the party needs.
class Track {
  const Track({
    required this.id,
    required this.name,
    required this.artists,
    required this.durationMs,
    this.imageUrl,
  });

  final String id;
  final String name;
  final String artists;
  final int durationMs;
  final String? imageUrl;

  String get uri => 'spotify:track:$id';
  String get spotifyUrl => 'https://open.spotify.com/track/$id';

  static String? idFromUri(String uri) => uri.startsWith('spotify:track:')
      ? uri.substring('spotify:track:'.length)
      : null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'n': name,
    'a': artists,
    'd': durationMs,
    if (imageUrl != null) 'i': imageUrl,
  };

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    name: j['n'] as String,
    artists: j['a'] as String,
    durationMs: (j['d'] as num).toInt(),
    imageUrl: j['i'] as String?,
  );

  /// Parses a track object from the Spotify Web API (e.g. search results).
  factory Track.fromSpotify(Map<String, dynamic> j) {
    final artists = (j['artists'] as List? ?? const [])
        .map((a) => (a as Map)['name'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .join(', ');
    String? image;
    final images = (j['album'] as Map?)?['images'] as List?;
    if (images != null && images.isNotEmpty) {
      // Images are ordered largest first; the last one is small enough for a
      // list row but still sharp.
      image = (images.last as Map)['url'] as String?;
    }
    return Track(
      id: j['id'] as String,
      name: j['name'] as String,
      artists: artists,
      durationMs: (j['duration_ms'] as num).toInt(),
      imageUrl: image,
    );
  }

  @override
  String toString() => '$name – $artists';
}

String formatMs(int ms) {
  final totalSeconds = (ms / 1000).floor();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
