import 'dart:math';

import 'party.dart';
import 'track.dart';

/// What is currently playing, as told to members.
class NowInfo {
  const NowInfo({
    required this.track,
    required this.memberUuid,
    required this.memberName,
    required this.positionMs,
    required this.atMs,
    required this.paused,
  });

  final Track track;
  final String memberUuid;
  final String memberName;

  /// Playback position at host time [atMs] (epoch ms, host clock).
  final int positionMs;
  final int atMs;
  final bool paused;

  /// Extrapolated position at [nowMs] (caller's clock; host and member clocks
  /// are assumed to agree within a second or two, which is fine for a bar).
  int positionAt(int nowMs) => paused
      ? positionMs
      : min(track.durationMs, positionMs + max(0, nowMs - atMs));

  Map<String, dynamic> toJson() => {
    't': track.toJson(),
    'mu': memberUuid,
    'mn': memberName,
    'p': positionMs,
    'at': atMs,
    'pa': paused,
  };

  factory NowInfo.fromJson(Map<String, dynamic> j) => NowInfo(
    track: Track.fromJson(j['t'] as Map<String, dynamic>),
    memberUuid: j['mu'] as String,
    memberName: j['mn'] as String,
    positionMs: (j['p'] as num).toInt(),
    atMs: (j['at'] as num).toInt(),
    paused: j['pa'] as bool? ?? false,
  );
}

/// Summary of another member.
class OtherInfo {
  const OtherInfo({
    required this.uuid,
    required this.name,
    required this.playedMs,
    required this.queueLength,
    this.nextTrack,
  });

  final String uuid;
  final String name;
  final int playedMs;
  final int queueLength;
  final String? nextTrack;

  Map<String, dynamic> toJson() => {
    'u': uuid,
    'n': name,
    'p': playedMs,
    'q': queueLength,
    if (nextTrack != null) 'x': nextTrack,
  };

  factory OtherInfo.fromJson(Map<String, dynamic> j) => OtherInfo(
    uuid: j['u'] as String,
    name: j['n'] as String,
    playedMs: (j['p'] as num).toInt(),
    queueLength: (j['q'] as num).toInt(),
    nextTrack: j['x'] as String?,
  );
}

/// The personalised state snapshot the host sends to one member. Every send is
/// a full snapshot, so a member is fully up to date after any single message.
class MemberView {
  const MemberView({
    required this.hostName,
    required this.token,
    required this.tokenExpiresAt,
    required this.now,
    required this.myPlayedMs,
    required this.myQueue,
    required this.others,
    required this.sentAt,
    this.notice,
    this.noticeAt = 0,
    this.pausedReason,
    this.shuffle = false,
    this.repeat = false,
    this.cursor = 0,
    this.pausedByHost = false,
  });

  final String hostName;

  /// Host's Spotify access token (for search) and its expiry (epoch ms).
  final String? token;
  final int tokenExpiresAt;
  final NowInfo? now;
  final int myPlayedMs;
  final List<QueueItem> myQueue;
  final List<OtherInfo> others;
  final int sentAt;

  /// Short announcement for everyone (e.g. "Bob skipped …"), with its time.
  final String? notice;
  final int noticeAt;

  /// Non-null while the party is paused because Spotify was taken over
  /// (another device, or the Spotify app on the host phone): the reason.
  final String? pausedReason;

  /// My queue modes and in-order position.
  final bool shuffle;
  final bool repeat;
  final int cursor;

  /// The host paused me (out of the rotation, queue kept) — rejoin explicitly.
  final bool pausedByHost;

  bool get hasValidToken =>
      token != null && tokenExpiresAt > DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'h': hostName,
    if (token != null) 'tk': token,
    'te': tokenExpiresAt,
    if (now != null) 'now': now!.toJson(),
    'mp': myPlayedMs,
    'mq': myQueue.map((q) => q.toJson()).toList(),
    'o': others.map((o) => o.toJson()).toList(),
    's': sentAt,
    if (notice != null) 'n': notice,
    if (notice != null) 'na': noticeAt,
    if (pausedReason != null) 'pr': pausedReason,
    if (shuffle) 'sh': true,
    if (repeat) 'rp': true,
    if (cursor > 0) 'cu': cursor,
    if (pausedByHost) 'pb': true,
  };

  factory MemberView.fromJson(Map<String, dynamic> j) => MemberView(
    hostName: j['h'] as String? ?? 'Host',
    token: j['tk'] as String?,
    tokenExpiresAt: (j['te'] as num?)?.toInt() ?? 0,
    now: j['now'] == null
        ? null
        : NowInfo.fromJson(j['now'] as Map<String, dynamic>),
    myPlayedMs: (j['mp'] as num?)?.toInt() ?? 0,
    myQueue: (j['mq'] as List? ?? const [])
        .map((q) => QueueItem.fromJson(q as Map<String, dynamic>))
        .toList(),
    others: (j['o'] as List? ?? const [])
        .map((o) => OtherInfo.fromJson(o as Map<String, dynamic>))
        .toList(),
    sentAt: (j['s'] as num?)?.toInt() ?? 0,
    notice: j['n'] as String?,
    noticeAt: (j['na'] as num?)?.toInt() ?? 0,
    pausedReason: j['pr'] as String?,
    shuffle: j['sh'] == true,
    repeat: j['rp'] == true,
    cursor: (j['cu'] as num?)?.toInt() ?? 0,
    pausedByHost: j['pb'] == true,
  );
}
