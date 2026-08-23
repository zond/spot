import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot/models/party.dart';
import 'package:spot/models/track.dart';

Track t(String id, int ms) =>
    Track(id: id, name: id, artists: 'x', durationMs: ms);

QueueItem q(String id, int ms) => QueueItem(id: id, track: t(id, ms));

QueueItem pl(String id, String name, int total) =>
    QueueItem(id: id, playlist: PlaylistRef(id: 'pl-$id', name: name, total: total));

/// Plays one turn for the least-airtime member: picks, "plays" (credits the
/// duration, or 1 s for playlist songs), commits. Returns (member uuid, entry).
(String, QueueItem)? turn(Party p, Random rng, {int playlistSongMs = 1000}) {
  final m = p.candidates().firstOrNull;
  if (m == null) return null;
  final e = p.plan(m, rng);
  if (e == null) return null;
  var done = false;
  if (e.playlist != null) {
    final plr = e.playlist!;
    if (m.shuffle) {
      plr.playedIds.add('${plr.id}-${plr.playedIds.length}');
      done = plr.playedIds.length >= plr.total;
    } else {
      plr.nextIndex++;
      done = plr.nextIndex >= plr.total;
    }
    p.credit(m.uuid, playlistSongMs);
  } else {
    p.credit(m.uuid, e.track!.durationMs);
  }
  p.commit(m, e, playlistDone: done);
  p.removeIdle();
  return (m.uuid, e);
}

void main() {
  final rng = Random(42);

  test('round robin while nobody has airtime', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 1000), 1);
    p.enqueue('a', 'A', q('a2', 1000), 1);
    p.enqueue('b', 'B', q('b1', 1000), 2);
    expect(turn(p, rng)!.$1, 'a');
    expect(turn(p, rng)!.$1, 'b');
    expect(turn(p, rng)!.$1, 'a');
    expect(turn(p, rng), isNull);
  });

  test('least airtime wins', () {
    final p = Party();
    p.enqueue('a', 'A', q('long', 600000), 1);
    p.enqueue('b', 'B', q('short1', 60000), 2);
    p.enqueue('b', 'B', q('short2', 60000), 2);
    p.enqueue('a', 'A', q('a2', 60000), 3);
    expect(turn(p, rng)!.$2.id, 'long');
    expect(turn(p, rng)!.$2.id, 'short1');
    expect(turn(p, rng)!.$2.id, 'short2');
    expect(turn(p, rng)!.$2.id, 'a2');
  });

  test('joining only makes you a listener; queuing admits you at the maximum',
      () {
    final p = Party();
    p.touch('c', 'C', 1);
    expect(p.members, isEmpty);
    p.enqueue('a', 'A', q('a1', 1), 2);
    p.enqueue('b', 'B', q('b1', 1), 2);
    p.credit('a', 300000);
    p.credit('b', 200000);
    p.enqueue('c', 'C', q('c1', 1), 3);
    expect(p.member('c')!.playedMs, 300000);
  });

  test('idle members are dropped and come back at the maximum', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 600000), 1);
    p.enqueue('a', 'A', q('a2', 1), 1);
    p.enqueue('b', 'B', q('b1', 100000), 2);
    p.enqueue('c', 'C', q('c1', 100000), 3);
    expect(turn(p, rng)!.$1, 'a'); // a=600000
    expect(turn(p, rng)!.$1, 'b'); // b=100000, now idle → dropped
    expect(p.member('b'), isNull);
    expect(p.member('a'), isNotNull, reason: 'a still has a2 queued');
    p.enqueue('b', 'B', q('b2', 1), 9);
    expect(p.member('b')!.playedMs, 600000, reason: 'back at the maximum');
  });

  test('repeat keeps entries and wraps the cursor', () {
    final p = Party();
    p.setModes('a', 'A', 1, repeat: true);
    for (final id in ['x', 'y', 'z']) {
      p.enqueue('a', 'A', q(id, 1000), 1);
    }
    final seen = [for (var i = 0; i < 7; i++) turn(p, rng)!.$2.id];
    expect(seen, ['x', 'y', 'z', 'x', 'y', 'z', 'x']);
    expect(p.member('a')!.queue.length, 3);
  });

  test('a playlist entry plays all its songs before the queue moves on', () {
    final p = Party();
    p.enqueue('a', 'A', q('s1', 1000), 1);
    p.enqueue('a', 'A', pl('P', 'Party mix', 3), 1);
    p.enqueue('a', 'A', q('s2', 1000), 1);
    final seen = [for (var i = 0; i < 5; i++) turn(p, rng)!.$2.id];
    expect(seen, ['s1', 'P', 'P', 'P', 's2']);
    expect(turn(p, rng), isNull, reason: 'all consumed (repeat off)');
  });

  test('in order + repeat: a finished playlist restarts next time around',
      () {
    final p = Party();
    p.setModes('a', 'A', 1, repeat: true);
    p.enqueue('a', 'A', pl('P', 'Mix', 2), 1);
    p.enqueue('a', 'A', q('s', 1000), 1);
    final seen = [for (var i = 0; i < 6; i++) turn(p, rng)!.$2.id];
    expect(seen, ['P', 'P', 's', 'P', 'P', 's']);
  });

  test('shuffle weights every song equally, playlists included', () {
    final p = Party();
    p.setModes('a', 'A', 1, shuffle: true, repeat: true);
    p.enqueue('a', 'A', q('solo', 1000), 1);
    p.enqueue('a', 'A', pl('P', 'Big', 39), 1);
    var solo = 0;
    const n = 4000;
    final r = Random(7);
    for (var i = 0; i < n; i++) {
      if (turn(p, r)!.$2.id == 'solo') solo++;
    }
    // 1 in 40 ≈ 100 of 4000; generous tolerance.
    expect(solo, inInclusiveRange(60, 140));
  });

  test('shuffle + repeat: everything plays once per cycle', () {
    final p = Party();
    p.setModes('a', 'A', 1, shuffle: true, repeat: true);
    for (final id in ['x', 'y', 'z']) {
      p.enqueue('a', 'A', q(id, 1000), 1);
    }
    p.enqueue('a', 'A', pl('P', 'Mix', 2), 1);
    final seen = [for (var i = 0; i < 5; i++) turn(p, rng)!.$2.id];
    expect(seen.where((s) => s == 'x').length, 1);
    expect(seen.where((s) => s == 'y').length, 1);
    expect(seen.where((s) => s == 'z').length, 1);
    expect(seen.where((s) => s == 'P').length, 2);
    // next cycle starts fresh
    expect(turn(p, rng), isNotNull);
  });

  test('dequeue/reorder keep the in-order cursor on the same entry', () {
    final p = Party();
    p.setModes('a', 'A', 1, repeat: true);
    for (final id in ['x', 'y', 'z']) {
      p.enqueue('a', 'A', q(id, 1000), 1);
    }
    turn(p, rng); // x played, cursor → y
    expect(p.member('a')!.queue[p.member('a')!.cursor].id, 'y');
    p.reorder('a', ['z', 'y', 'x']);
    expect(p.member('a')!.queue[p.member('a')!.cursor].id, 'y');
    p.dequeue('a', 'z');
    expect(p.member('a')!.queue[p.member('a')!.cursor].id, 'y');
    expect(turn(p, rng)!.$2.id, 'y');
  });

  test('skipping costs the skipper the remaining time, now or as debt', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 1), 1);
    p.enqueue('b', 'B', q('b1', 1), 1);
    p.penalize('b', 'B', 120000, 2);
    expect(p.member('b')!.playedMs, 120000);
    p.penalize('c', 'C', 30000, 3);
    expect(p.member('c'), isNull);
    expect(p.listener('c')!.debtMs, 30000);
    p.enqueue('c', 'C', q('c1', 1), 4);
    expect(p.member('c')!.playedMs, 120000 + 30000);
  });

  test('listeners: recipients and pruning by last-seen', () {
    final p = Party();
    p.touch('x', 'X', 0);
    p.touch('y', 'Y', 5 * 60000);
    p.enqueue('z', 'Z', q('z1', 1), 0);
    const tenMin = Duration(minutes: 10);
    expect(p.recipients(12 * 60000, tenMin).map((l) => l.uuid), ['y']);
    expect(p.pruneListeners(12 * 60000, tenMin), 1);
    expect(p.listener('z'), isNotNull);
  });

  test('json round trip incl. playlist entries, modes and cursor', () {
    final p = Party();
    p.setModes('a', 'A', 1, shuffle: true, repeat: true);
    p.enqueue('a', 'A', q('x', 1234), 2);
    p.enqueue('a', 'A', pl('P', 'Mix', 5), 2);
    p.member('a')!.queue[1].playlist!.playedIds.add('t1');
    p.credit('a', 42);
    final back = Party.fromJson(p.toJson());
    final m = back.member('a')!;
    expect(m.playedMs, 42);
    expect(m.shuffle, isTrue);
    expect(m.repeat, isTrue);
    expect(m.queue[1].playlist!.name, 'Mix');
    expect(m.queue[1].playlist!.playedIds, {'t1'});
  });
}
