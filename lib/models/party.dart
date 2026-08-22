import 'dart:math';

import 'track.dart';

/// One entry in a member's personal queue.
class QueueItem {
  const QueueItem({required this.id, required this.track});

  final String id;
  final Track track;

  Map<String, dynamic> toJson() => {'id': id, 't': track.toJson()};

  factory QueueItem.fromJson(Map<String, dynamic> j) => QueueItem(
        id: j['id'] as String,
        track: Track.fromJson(j['t'] as Map<String, dynamic>),
      );
}

class Member {
  Member({
    required this.uuid,
    required this.name,
    required this.joinedAt,
    this.playedMs = 0,
    int? lastSeen,
  }) : lastSeen = lastSeen ?? joinedAt;

  final String uuid;
  String name;
  final int joinedAt;

  /// Airtime credited to this member so far (ms actually played).
  int playedMs;
  int lastSeen;
  final List<QueueItem> queue = [];

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'name': name,
        'joinedAt': joinedAt,
        'playedMs': playedMs,
        'lastSeen': lastSeen,
        'queue': queue.map((q) => q.toJson()).toList(),
      };

  factory Member.fromJson(Map<String, dynamic> j) {
    final m = Member(
      uuid: j['uuid'] as String,
      name: j['name'] as String,
      joinedAt: (j['joinedAt'] as num).toInt(),
      playedMs: (j['playedMs'] as num?)?.toInt() ?? 0,
      lastSeen: (j['lastSeen'] as num?)?.toInt(),
    );
    for (final q in (j['queue'] as List? ?? const [])) {
      m.queue.add(QueueItem.fromJson(q as Map<String, dynamic>));
    }
    return m;
  }
}

/// Host-side party state and the fairness policy.
///
/// Fairness is "least airtime first": whenever a track ends, the next track is
/// the head of the queue of the member who has had the least airtime so far
/// (ties go to whoever joined first, which makes the start a plain round
/// robin). Airtime is credited as tracks actually play, so skips only count
/// what was heard.
class Party {
  Party();

  /// Insertion order = join order (LinkedHashMap).
  final Map<String, Member> _members = {};

  Iterable<Member> get members => _members.values;
  Member? member(String uuid) => _members[uuid];
  bool get isEmpty => _members.isEmpty;
  bool get hasQueued => _members.values.any((m) => m.queue.isNotEmpty);

  /// Adds a member, or refreshes name/presence if already present.
  ///
  /// New members start at the lowest airtime already in the party, so they
  /// neither owe time nor get to monopolise the speakers catching up.
  Member join(String uuid, String name, int nowMs) {
    final existing = _members[uuid];
    if (existing != null) {
      existing.name = name;
      existing.lastSeen = nowMs;
      return existing;
    }
    final start = _members.isEmpty
        ? 0
        : _members.values.map((m) => m.playedMs).reduce(min);
    return _members[uuid] =
        Member(uuid: uuid, name: name, joinedAt: nowMs, playedMs: start);
  }

  void touch(String uuid, int nowMs) => _members[uuid]?.lastSeen = nowMs;

  /// Appends [item] to the member's queue. Returns false if the member is
  /// unknown or the item id was already queued (duplicate delivery).
  bool enqueue(String uuid, QueueItem item, int nowMs) {
    final m = _members[uuid];
    if (m == null) return false;
    if (m.queue.any((q) => q.id == item.id)) return false;
    m.queue.add(item);
    m.lastSeen = nowMs;
    return true;
  }

  bool dequeue(String uuid, String itemId) {
    final m = _members[uuid];
    if (m == null) return false;
    final before = m.queue.length;
    m.queue.removeWhere((q) => q.id == itemId);
    return m.queue.length != before;
  }

  /// Removes and returns the next item to play, or null if every queue is
  /// empty.
  (Member, QueueItem)? takeNext() {
    Member? best;
    for (final m in _members.values) {
      if (m.queue.isEmpty) continue;
      if (best == null || m.playedMs < best.playedMs) best = m;
    }
    if (best == null) return null;
    return (best, best.queue.removeAt(0));
  }

  void credit(String uuid, int deltaMs) {
    if (deltaMs <= 0) return;
    _members[uuid]?.playedMs += deltaMs;
  }

  Map<String, dynamic> toJson() =>
      {'members': _members.values.map((m) => m.toJson()).toList()};

  factory Party.fromJson(Map<String, dynamic> j) {
    final p = Party();
    for (final m in (j['members'] as List? ?? const [])) {
      final member = Member.fromJson(m as Map<String, dynamic>);
      p._members[member.uuid] = member;
    }
    return p;
  }
}
