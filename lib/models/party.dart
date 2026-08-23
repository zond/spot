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

/// Someone whose page talks to the host: gets state pushes while recently
/// seen. Separate from [Member] so idle people don't clutter the party.
class Listener {
  Listener({
    required this.uuid,
    required this.name,
    required this.lastSeen,
    this.debtMs = 0,
  });
  final String uuid;
  String name;
  int lastSeen;

  /// Airtime owed (e.g. from skipping) while not an active member; applied
  /// on top of the party maximum when they next queue a song.
  int debtMs;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'name': name,
        'lastSeen': lastSeen,
        if (debtMs > 0) 'debtMs': debtMs,
      };

  factory Listener.fromJson(Map<String, dynamic> j) => Listener(
        uuid: j['uuid'] as String,
        name: j['name'] as String,
        lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
        debtMs: (j['debtMs'] as num?)?.toInt() ?? 0,
      );
}

/// Host-side party state and the fairness policy.
///
/// Fairness is "least airtime first": whenever a track ends, the next track is
/// the head of the queue of the member who has had the least airtime so far
/// (ties go to whoever joined first, which makes the start a plain round
/// robin). Airtime is credited as tracks actually play, so skips only count
/// what was heard.
///
/// Only people with something queued (or playing) are *members*. Everyone who
/// has talked to the host is a *listener* and receives state pushes while
/// recently seen. Idle people are not kept as members: an idle member's state
/// is fully implied (empty queue, airtime = party maximum), so dropping them
/// and re-admitting them at the maximum when they next queue a song is
/// indistinguishable from keeping them — and it keeps the host list honest.
class Party {
  Party();

  /// Insertion order = order of (re)joining the active set (LinkedHashMap).
  final Map<String, Member> _members = {};
  final Map<String, Listener> _listeners = {};

  Iterable<Member> get members => _members.values;
  Iterable<Listener> get listeners => _listeners.values;
  Member? member(String uuid) => _members[uuid];
  Listener? listener(String uuid) => _listeners[uuid];
  bool get isEmpty => _members.isEmpty && _listeners.isEmpty;
  bool get hasQueued => _members.values.any((m) => m.queue.isNotEmpty);

  int get maxPlayedMs =>
      _members.isEmpty ? 0 : _members.values.map((m) => m.playedMs).reduce(max);

  /// Records that [uuid] is around (any message does this) and keeps the
  /// display name current.
  Listener touch(String uuid, String? name, int nowMs) {
    final l = _listeners[uuid];
    final n = (name ?? l?.name ?? '').trim();
    if (l == null) {
      return _listeners[uuid] =
          Listener(uuid: uuid, name: n.isEmpty ? 'Someone' : n, lastSeen: nowMs);
    }
    l.lastSeen = nowMs;
    if (n.isNotEmpty) l.name = n;
    _members[uuid]?.name = l.name;
    return l;
  }

  /// Listeners heard from within [maxAge] — the ones worth pushing to.
  Iterable<Listener> recipients(int nowMs, Duration maxAge) => _listeners.values
      .where((l) => nowMs - l.lastSeen <= maxAge.inMilliseconds);

  /// Forgets listeners silent for longer than [maxAge]. Members are kept
  /// regardless: their queued songs still play.
  int pruneListeners(int nowMs, Duration maxAge) {
    final before = _listeners.length;
    _listeners.removeWhere((uuid, l) =>
        nowMs - l.lastSeen > maxAge.inMilliseconds && !_members.containsKey(uuid));
    return before - _listeners.length;
  }

  /// Appends [item] to the member's queue, admitting them to the active set
  /// (at the party's maximum airtime — back of the line) if needed. Returns
  /// false if the item id was already queued (duplicate delivery).
  bool enqueue(String uuid, String? name, QueueItem item, int nowMs) {
    final l = touch(uuid, name, nowMs);
    var m = _members[uuid];
    if (m == null) {
      m = _members[uuid] = Member(
          uuid: uuid,
          name: l.name,
          joinedAt: nowMs,
          playedMs: maxPlayedMs + l.debtMs);
      l.debtMs = 0;
    }
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

  /// Reorders the member's queue to follow [itemIds]; items not mentioned
  /// keep their relative order at the end (they were added after the member
  /// dragged). Returns true if the order changed.
  bool reorder(String uuid, List<String> itemIds) {
    final m = _members[uuid];
    if (m == null) return false;
    final byId = {for (final q in m.queue) q.id: q};
    final next = <QueueItem>[
      for (final id in itemIds) ?byId.remove(id),
      ...m.queue.where((q) => byId.containsKey(q.id)),
    ];
    var changed = next.length != m.queue.length;
    for (var i = 0; !changed && i < next.length; i++) {
      changed = next[i].id != m.queue[i].id;
    }
    if (!changed) return false;
    m.queue
      ..clear()
      ..addAll(next);
    return true;
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

  /// Drops members with nothing queued, except [playing] (whose current
  /// track is not in their queue). Their airtime is implied (= maximum) and
  /// restored on their next enqueue.
  int removeIdle({String? playing}) {
    final before = _members.length;
    _members.removeWhere((uuid, m) => m.queue.isEmpty && uuid != playing);
    return before - _members.length;
  }

  /// Charges [ms] of airtime to [uuid] — the price of skipping a song. Active
  /// members pay right away; anyone else carries it as debt until they next
  /// queue a song.
  void penalize(String uuid, String? name, int ms, int nowMs) {
    if (ms <= 0) return;
    final l = touch(uuid, name, nowMs);
    final m = _members[uuid];
    if (m != null) {
      m.playedMs += ms;
    } else {
      l.debtMs += ms;
    }
  }

  /// Credits airtime to the member whose track is playing.
  void credit(String uuid, int deltaMs) {
    if (deltaMs <= 0) return;
    _members[uuid]?.playedMs += deltaMs;
  }

  Map<String, dynamic> toJson() => {
        'members': _members.values.map((m) => m.toJson()).toList(),
        'listeners': _listeners.values.map((l) => l.toJson()).toList(),
      };

  factory Party.fromJson(Map<String, dynamic> j) {
    final p = Party();
    for (final m in (j['members'] as List? ?? const [])) {
      final member = Member.fromJson(m as Map<String, dynamic>);
      p._members[member.uuid] = member;
    }
    for (final l in (j['listeners'] as List? ?? const [])) {
      final listener = Listener.fromJson(l as Map<String, dynamic>);
      p._listeners[listener.uuid] = listener;
    }
    return p;
  }
}
