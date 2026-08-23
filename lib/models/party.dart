import 'dart:math';

import 'track.dart';

/// A Spotify playlist referenced from a queue, with the host's progress
/// through it. The host reads the playlist live, so edits made in Spotify
/// show up; it only remembers where it is.
class PlaylistRef {
  PlaylistRef({
    required this.id,
    required this.name,
    required this.total,
    this.nextIndex = 0,
    Set<String>? playedIds,
  }) : playedIds = playedIds ?? {};

  final String id;
  String name;

  /// Number of items, as last seen (refreshed whenever the host reads it).
  int total;

  /// In-order mode: the next item offset to play.
  int nextIndex;

  /// Shuffle mode: track ids played in the current cycle.
  final Set<String> playedIds;

  /// Songs left before this entry is "done" (used as shuffle weight).
  int remaining(bool shuffle) => shuffle
      ? (total - playedIds.length).clamp(0, total)
      : (total - nextIndex).clamp(0, total);

  bool done(bool shuffle) => total == 0 || remaining(shuffle) == 0;

  void reset() {
    nextIndex = 0;
    playedIds.clear();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'n': name,
    'c': total,
    if (nextIndex > 0) 'i': nextIndex,
    if (playedIds.isNotEmpty) 'p': playedIds.toList(),
  };

  factory PlaylistRef.fromJson(Map<String, dynamic> j) => PlaylistRef(
    id: j['id'] as String,
    name: j['n'] as String? ?? 'Playlist',
    total: (j['c'] as num?)?.toInt() ?? 0,
    nextIndex: (j['i'] as num?)?.toInt() ?? 0,
    playedIds: ((j['p'] as List?) ?? const []).cast<String>().toSet(),
  );
}

/// One entry in a member's personal queue: a song, or a whole playlist that
/// plays all its songs (one per turn) before the queue moves past it.
class QueueItem {
  QueueItem({required this.id, this.track, this.playlist})
    : assert((track == null) != (playlist == null));

  final String id;
  final Track? track;
  final PlaylistRef? playlist;

  bool get isPlaylist => playlist != null;

  /// Repeat mode: has this song entry played in the current shuffle cycle.
  bool playedThisCycle = false;

  /// Songs this entry still has to offer this cycle (shuffle weight).
  int remaining(bool shuffle) => playlist != null
      ? playlist!.remaining(shuffle)
      : (playedThisCycle ? 0 : 1);

  String get title => track?.name ?? playlist!.name;

  Map<String, dynamic> toJson() => {
    'id': id,
    if (track != null) 't': track!.toJson(),
    if (playlist != null) 'pl': playlist!.toJson(),
    if (playedThisCycle) 'x': true,
  };

  factory QueueItem.fromJson(Map<String, dynamic> j) {
    final item = QueueItem(
      id: j['id'] as String,
      track: j['t'] == null
          ? null
          : Track.fromJson(j['t'] as Map<String, dynamic>),
      playlist: j['pl'] == null
          ? null
          : PlaylistRef.fromJson(j['pl'] as Map<String, dynamic>),
    );
    item.playedThisCycle = j['x'] == true;
    return item;
  }
}

class Member {
  Member({
    required this.uuid,
    required this.name,
    required this.joinedAt,
    this.playedMs = 0,
    int? lastSeen,
    this.shuffle = false,
    this.repeat = false,
  }) : lastSeen = lastSeen ?? joinedAt;

  final String uuid;
  String name;
  final int joinedAt;

  /// Airtime credited to this member so far (ms actually played).
  int playedMs;
  int lastSeen;
  final List<QueueItem> queue = [];

  /// Pick randomly (weighted per song) instead of in order.
  bool shuffle;

  /// Keep entries after playing them; wrap around at the end.
  bool repeat;

  /// In-order position in [queue] (repeat mode; with repeat off the head is
  /// always next because played entries are removed).
  int cursor = 0;

  /// Songs this member can still offer this cycle.
  int remaining(bool forShuffle) =>
      queue.fold(0, (n, q) => n + q.remaining(forShuffle));

  bool get hasSomethingToPlay =>
      queue.any((q) => q.track != null || (q.playlist?.total ?? 0) > 0);

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'name': name,
    'joinedAt': joinedAt,
    'playedMs': playedMs,
    'lastSeen': lastSeen,
    'queue': queue.map((q) => q.toJson()).toList(),
    if (shuffle) 'shuffle': true,
    if (repeat) 'repeat': true,
    if (cursor > 0) 'cursor': cursor,
  };

  factory Member.fromJson(Map<String, dynamic> j) {
    final m = Member(
      uuid: j['uuid'] as String,
      name: j['name'] as String,
      joinedAt: (j['joinedAt'] as num).toInt(),
      playedMs: (j['playedMs'] as num?)?.toInt() ?? 0,
      lastSeen: (j['lastSeen'] as num?)?.toInt(),
      shuffle: j['shuffle'] == true,
      repeat: j['repeat'] == true,
    );
    m.cursor = (j['cursor'] as num?)?.toInt() ?? 0;
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
  bool get hasQueued => _members.values.any((m) => m.hasSomethingToPlay);

  int get maxPlayedMs =>
      _members.isEmpty ? 0 : _members.values.map((m) => m.playedMs).reduce(max);

  /// Records that [uuid] is around (any message does this) and keeps the
  /// display name current.
  Listener touch(String uuid, String? name, int nowMs) {
    final l = _listeners[uuid];
    final n = (name ?? l?.name ?? '').trim();
    if (l == null) {
      return _listeners[uuid] = Listener(
        uuid: uuid,
        name: n.isEmpty ? 'Someone' : n,
        lastSeen: nowMs,
      );
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
    _listeners.removeWhere(
      (uuid, l) =>
          nowMs - l.lastSeen > maxAge.inMilliseconds &&
          !_members.containsKey(uuid),
    );
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
        playedMs: maxPlayedMs + l.debtMs,
      );
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
    final idx = m.queue.indexWhere((q) => q.id == itemId);
    if (idx < 0) return false;
    m.queue.removeAt(idx);
    if (idx < m.cursor) m.cursor--;
    if (m.cursor >= m.queue.length) m.cursor = 0;
    return true;
  }

  /// Shuffle / repeat toggles (admits the member if needed, so the flags
  /// stick even before anything is queued).
  void setModes(
    String uuid,
    String? name,
    int nowMs, {
    bool? shuffle,
    bool? repeat,
  }) {
    final l = touch(uuid, name, nowMs);
    var m = _members[uuid];
    if (m == null) {
      m = _members[uuid] = Member(
        uuid: uuid,
        name: l.name,
        joinedAt: nowMs,
        playedMs: maxPlayedMs + l.debtMs,
      );
      l.debtMs = 0;
    }
    if (shuffle != null) m.shuffle = shuffle;
    if (repeat != null) {
      m.repeat = repeat;
      if (!repeat) {
        // Leaving repeat: forget cycle bookkeeping; entries are consumed again.
        for (final q in m.queue) {
          q.playedThisCycle = false;
        }
      }
    }
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
    final currentId = m.cursor < m.queue.length ? m.queue[m.cursor].id : null;
    m.queue
      ..clear()
      ..addAll(next);
    final ci = currentId == null
        ? -1
        : m.queue.indexWhere((q) => q.id == currentId);
    m.cursor = ci < 0 ? 0 : ci;
    return true;
  }

  /// Members that can offer a song, least airtime first (ties: join order).
  List<Member> candidates() {
    final list = _members.values.where((m) => m.hasSomethingToPlay).toList();
    list.sort((a, b) => a.playedMs.compareTo(b.playedMs));
    return list;
  }

  /// Chooses which entry of [m]'s queue plays next, without touching the
  /// network: in order from the cursor, or — shuffled — weighted so that every
  /// song, loose or inside a playlist, has the same chance. Returns null when
  /// the member has nothing playable. Cycle bookkeeping (repeat + shuffle:
  /// everything plays once before anything repeats) is reset here when a
  /// cycle completes. The caller resolves playlist entries to a track and then
  /// calls [commit].
  QueueItem? plan(Member m, Random rng) {
    if (!m.hasSomethingToPlay) return null;
    if (!m.shuffle) {
      if (m.cursor >= m.queue.length) m.cursor = 0;
      // Skip playlist entries that are empty (nothing to read).
      for (var i = 0; i < m.queue.length; i++) {
        final q = m.queue[(m.cursor + i) % m.queue.length];
        if (q.track != null || (q.playlist?.total ?? 0) > 0) {
          m.cursor = (m.cursor + i) % m.queue.length;
          return q;
        }
      }
      return null;
    }
    var total = m.remaining(true);
    if (total == 0) {
      // Cycle complete (repeat mode): everything is eligible again.
      for (final q in m.queue) {
        q.playedThisCycle = false;
        q.playlist?.reset();
      }
      total = m.remaining(true);
      if (total == 0) return null;
    }
    var r = rng.nextInt(total);
    for (final q in m.queue) {
      final w = q.remaining(true);
      if (r < w) return q;
      r -= w;
    }
    return m.queue.last;
  }

  /// Records that [entry] of [m] produced a song (playlist entries: the
  /// caller advanced nextIndex / playedIds already). Applies repeat-off
  /// removal and in-order cursor movement. [playlistDone] tells whether a
  /// playlist entry has now offered all its songs this cycle.
  void commit(Member m, QueueItem entry, {bool playlistDone = false}) {
    final idx = m.queue.indexOf(entry);
    if (idx < 0) return;
    final finished = entry.playlist == null || playlistDone;
    if (!m.repeat) {
      if (finished) {
        m.queue.removeAt(idx);
        if (idx < m.cursor) m.cursor--;
        if (m.cursor >= m.queue.length) m.cursor = 0;
      }
      return;
    }
    if (m.shuffle) {
      if (entry.playlist == null) entry.playedThisCycle = true;
      return;
    }
    // In order + repeat: move on when the entry is finished; a finished
    // playlist restarts next time around.
    if (finished) {
      entry.playlist?.reset();
      m.cursor = (idx + 1) % m.queue.length;
    } else {
      m.cursor = idx;
    }
  }

  /// Host kicked a member: their queue goes with them (they stay a listener
  /// and can queue again).
  bool removeMember(String uuid) => _members.remove(uuid) != null;

  /// Drops members with nothing queued, except [playing] (whose current
  /// track is not in their queue). Their airtime is implied (= maximum) and
  /// restored on their next enqueue.
  int removeIdle({String? playing}) {
    final before = _members.length;
    _members.removeWhere((uuid, m) => !m.hasSomethingToPlay && uuid != playing);
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
