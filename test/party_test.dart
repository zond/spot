import 'package:flutter_test/flutter_test.dart';
import 'package:spot/models/party.dart';
import 'package:spot/models/track.dart';

Track t(String id, int ms) =>
    Track(id: id, name: id, artists: 'x', durationMs: ms);

QueueItem q(String id, int ms) => QueueItem(id: id, track: t(id, ms));

void main() {
  test('round robin while nobody has airtime', () {
    final p = Party();
    p.join('a', 'A', 1);
    p.join('b', 'B', 2);
    p.enqueue('a', q('a1', 1000), 3);
    p.enqueue('a', q('a2', 1000), 3);
    p.enqueue('b', q('b1', 1000), 3);
    expect(p.takeNext()!.$1.uuid, 'a');
    p.credit('a', 1000);
    expect(p.takeNext()!.$1.uuid, 'b');
    p.credit('b', 1000);
    expect(p.takeNext()!.$1.uuid, 'a');
    expect(p.takeNext(), isNull);
  });

  test('least airtime wins', () {
    final p = Party();
    p.join('a', 'A', 1);
    p.join('b', 'B', 2);
    p.enqueue('a', q('long', 600000), 3);
    p.enqueue('b', q('short1', 60000), 3);
    p.enqueue('b', q('short2', 60000), 3);
    p.enqueue('a', q('a2', 60000), 3);
    expect(p.takeNext()!.$2.id, 'long');
    p.credit('a', 600000);
    expect(p.takeNext()!.$2.id, 'short1');
    p.credit('b', 60000);
    expect(p.takeNext()!.$2.id, 'short2');
    p.credit('b', 60000);
    expect(p.takeNext()!.$2.id, 'a2');
  });

  test('late joiner starts at the party maximum', () {
    final p = Party();
    p.join('a', 'A', 1);
    p.join('b', 'B', 2);
    p.enqueue('b', q('b1', 1), 2);
    p.credit('a', 300000);
    p.credit('b', 200000);
    final c = p.join('c', 'C', 3);
    expect(c.playedMs, 300000);
  });

  test('idle members follow the maximum instead of banking credit', () {
    final p = Party();
    p.join('a', 'A', 1);
    p.join('b', 'B', 2);
    p.join('c', 'C', 3);
    p.enqueue('a', q('a1', 1), 4);
    p.enqueue('a', q('a2', 1), 4);
    p.enqueue('c', q('c1', 1), 4);
    p.takeNext(); // a1 plays
    p.credit('a', 600000);
    expect(p.member('b')!.playedMs, 600000, reason: 'b idles → follows max');
    expect(p.member('c')!.playedMs, 0, reason: 'c is queued → keeps its turn');
    // a's own queue (a2) keeps a from being "idle" while a1 plays
    expect(p.member('a')!.playedMs, 600000);
    // b adds a song now: it goes behind c, not ahead of everyone
    p.enqueue('b', q('b1', 1), 5);
    expect(p.takeNext()!.$1.uuid, 'c');
  });

  test('duplicate enqueue ids are ignored, dequeue works', () {
    final p = Party();
    p.join('a', 'A', 1);
    expect(p.enqueue('a', q('x', 1), 2), isTrue);
    expect(p.enqueue('a', q('x', 1), 2), isFalse);
    expect(p.member('a')!.queue.length, 1);
    expect(p.dequeue('a', 'x'), isTrue);
    expect(p.dequeue('a', 'x'), isFalse);
  });

  test('reorder follows the given ids, unknown ones go last', () {
    final p = Party();
    p.join('a', 'A', 1);
    for (final id in ['x', 'y', 'z']) {
      p.enqueue('a', q(id, 1), 2);
    }
    expect(p.reorder('a', ['z', 'x']), isTrue);
    expect(p.member('a')!.queue.map((i) => i.id), ['z', 'x', 'y']);
    expect(p.reorder('a', ['z', 'x', 'y']), isFalse);
    expect(p.reorder('a', ['nope']), isFalse);
    expect(p.member('a')!.queue.map((i) => i.id), ['z', 'x', 'y']);
  });

  test('json round trip', () {
    final p = Party();
    p.join('a', 'A', 1);
    p.enqueue('a', q('x', 1234), 2);
    p.credit('a', 42);
    final back = Party.fromJson(p.toJson());
    expect(back.member('a')!.playedMs, 42);
    expect(back.member('a')!.queue.single.track.durationMs, 1234);
  });
}
