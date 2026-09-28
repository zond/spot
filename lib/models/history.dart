/// A song the party has played, and how it ended.
class PlayedSong {
  const PlayedSong({
    required this.name,
    required this.artists,
    required this.trackId,
    required this.playedMs,
    required this.at,
    required this.reason,
    this.memberName,
    this.by,
  });

  final String name;
  final String artists;
  final String trackId;

  /// How much of it was actually heard.
  final int playedMs;
  final int at;

  /// played · skipped · interrupted (something else grabbed the session).
  final String reason;

  /// Whose song it was; null for music Spotify itself put on.
  final String? memberName;

  /// Who skipped it, when [reason] is `skipped`.
  final String? by;

  bool get wasSkipped => reason == 'skipped';

  Map<String, dynamic> toJson() => {
    'n': name,
    'a': artists,
    'i': trackId,
    'p': playedMs,
    't': at,
    'r': reason,
    if (memberName != null) 'm': memberName,
    if (by != null) 'b': by,
  };

  factory PlayedSong.fromJson(Map<String, dynamic> j) => PlayedSong(
    name: j['n'] as String? ?? '',
    artists: j['a'] as String? ?? '',
    trackId: j['i'] as String? ?? '',
    playedMs: (j['p'] as num?)?.toInt() ?? 0,
    at: (j['t'] as num?)?.toInt() ?? 0,
    reason: j['r'] as String? ?? 'played',
    memberName: j['m'] as String?,
    by: j['b'] as String?,
  );

  /// "for Martin · 3:12" / "skipped by Emelie after 0:42".
  String describe(String Function(int) formatMs) {
    final whose = memberName == null ? "Spotify's own pick" : 'for $memberName';
    return switch (reason) {
      'skipped' =>
        '$whose · skipped by ${by ?? 'someone'} after ${formatMs(playedMs)}',
      'interrupted' =>
        '$whose · cut short after ${formatMs(playedMs)} (Spotify was grabbed)',
      _ => '$whose · ${formatMs(playedMs)}',
    };
  }
}
