import 'package:flutter_test/flutter_test.dart';
import 'package:spot/models/party.dart';
import 'package:spot/models/track.dart';

Track t(String id, int ms) =>
    Track(id: id, name: id, artists: 'x', durationMs: ms);

QueueItem q(String id, int ms) => QueueItem(id: id, track: t(id, ms));

void main() {
  test('round robin while nobody has airtime', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 1000), 1);
    p.enqueue('a', 'A', q('a2', 1000), 1);
    p.enqueue('b', 'B', q('b1', 1000), 2);
    expect(p.takeNext()!.$1.uuid, 'a');
    p.credit('a', 1000);
    expect(p.takeNext()!.$1.uuid, 'b');
    p.credit('b', 1000);
    expect(p.takeNext()!.$1.uuid, 'a');
    expect(p.takeNext(), isNull);
  });

  test('least airtime wins', () {
    final p = Party();
    p.enqueue('a', 'A', q('long', 600000), 1);
    p.enqueue('b', 'B', q('short1', 60000), 2);
    p.enqueue('b', 'B', q('short2', 60000), 2);
    p.enqueue('a', 'A', q('a2', 60000), 3);
    expect(p.takeNext()!.$2.id, 'long');
    p.credit('a', 600000);
    expect(p.takeNext()!.$2.id, 'short1');
    p.credit('b', 60000);
    expect(p.takeNext()!.$2.id, 'short2');
    p.credit('b', 60000);
    expect(p.takeNext()!.$2.id, 'a2');
  });

  test('joining only makes you a listener; queuing admits you at the maximum',
      () {
    final p = Party();
    p.touch('c', 'C', 1);
    expect(p.members, isEmpty);
    expect(p.listeners.single.name, 'C');
    p.enqueue('a', 'A', q('a1', 1), 2);
    p.enqueue('b', 'B', q('b1', 1), 2);
    p.credit('a', 300000);
    p.credit('b', 200000);
    p.enqueue('c', 'C', q('c1', 1), 3);
    expect(p.member('c')!.playedMs, 300000);
  });

  test('idle members are dropped and come back at the maximum', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 1), 1);
    p.enqueue('a', 'A', q('a2', 1), 1);
    p.enqueue('b', 'B', q('b1', 1), 2);
    p.enqueue('c', 'C', q('c1', 1), 3);
    expect(p.takeNext()!.$1.uuid, 'a'); // a1 plays
    p.credit('a', 600000);
    expect(p.takeNext()!.$1.uuid, 'b'); // b1 plays, b's queue now empty
    p.removeIdle(playing: 'b');
    expect(p.member('b'), isNotNull, reason: 'still playing');
    p.credit('b', 100000);
    expect(p.takeNext()!.$1.uuid, 'c'); // c1 plays
    p.removeIdle(playing: 'c');
    expect(p.member('b'), isNull, reason: 'b idle → dropped');
    expect(p.member('a'), isNotNull, reason: 'a still has a2 queued');
    // b adds a song later: admitted at the maximum, behind a
    p.enqueue('b', 'B', q('b2', 1), 9);
    expect(p.member('b')!.playedMs, 600000);
    p.credit('c', 100000);
    expect(p.takeNext()!.$1.uuid, 'a');
  });

  test('listeners: recipients and pruning by last-seen', () {
    final p = Party();
    p.touch('x', 'X', 0);
    p.touch('y', 'Y', 5 * 60000);
    p.enqueue('z', 'Z', q('z1', 1), 0); // member, silent since 0
    const tenMin = Duration(minutes: 10);
    expect(p.recipients(12 * 60000, tenMin).map((l) => l.uuid), ['y']);
    expect(p.pruneListeners(12 * 60000, tenMin), 1, reason: 'x pruned, z kept');
    expect(p.listener('z'), isNotNull);
  });

  test('duplicate enqueue ids are ignored, dequeue and reorder work', () {
    final p = Party();
    expect(p.enqueue('a', 'A', q('x', 1), 2), isTrue);
    expect(p.enqueue('a', 'A', q('x', 1), 2), isFalse);
    for (final id in ['y', 'z']) {
      p.enqueue('a', 'A', q(id, 1), 2);
    }
    expect(p.reorder('a', ['z', 'x']), isTrue);
    expect(p.member('a')!.queue.map((i) => i.id), ['z', 'x', 'y']);
    expect(p.reorder('a', ['nope']), isFalse);
    expect(p.dequeue('a', 'x'), isTrue);
    expect(p.dequeue('a', 'x'), isFalse);
  });

  test('skipping costs the skipper the remaining time, now or as debt', () {
    final p = Party();
    p.enqueue('a', 'A', q('a1', 1), 1);
    p.enqueue('b', 'B', q('b1', 1), 1);
    p.enqueue('b', 'B', q('b2', 1), 1);
    p.takeNext(); // a1 plays
    p.credit('a', 60000);
    // b (member) skips with 120 s left: pays now
    p.penalize('b', 'B', 120000, 2);
    expect(p.member('b')!.playedMs, 120000);
    // c (just watching) skips: carries debt until queuing
    p.penalize('c', 'C', 30000, 3);
    expect(p.member('c'), isNull);
    expect(p.listener('c')!.debtMs, 30000);
    p.enqueue('c', 'C', q('c1', 1), 4);
    expect(p.member('c')!.playedMs, 120000 + 30000, reason: 'max + debt');
    expect(p.listener('c')!.debtMs, 0);
  });

  test('json round trip', () {
    final p = Party();
    p.touch('l', 'L', 7);
    p.enqueue('a', 'A', q('x', 1234), 2);
    p.credit('a', 42);
    final back = Party.fromJson(p.toJson());
    expect(back.member('a')!.playedMs, 42);
    expect(back.member('a')!.queue.single.track.durationMs, 1234);
    expect(back.listener('l')!.lastSeen, 7);
  });
}
