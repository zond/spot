import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../config.dart';

/// Message types exchanged over fcm-switch.
abstract final class MsgType {
  // member -> host
  /// {uuid, name}. Also doubles as "please (re)send me the state".
  static const join = 'join';

  /// {uuid, item: QueueItem}
  static const enqueue = 'enqueue';

  /// {uuid, itemId}
  static const dequeue = 'dequeue';

  /// {uuid, itemIds: [...]} — full desired order of the member's queue.
  static const reorder = 'reorder';

  /// {uuid, name} — "still here"; keeps the member among push recipients.
  static const ping = 'ping';

  /// {uuid, name, trackId} — skip the playing song; the remaining time is
  /// charged to the skipper's airtime.
  static const skip = 'skip';

  /// {uuid, name, shuffle?, repeat?} — queue playback modes.
  static const modes = 'modes';

  /// {uuid, name, rid, url} — please resolve this Spotify short link.
  static const resolve = 'resolve';

  /// {uuid, name} — a member paused by the host asks to be back in.
  static const rejoin = 'rejoin';

  // host -> member
  /// {rid, url?} — the real URL behind a short link (null: couldn't).
  static const resolved = 'resolved';

  // host -> member
  /// MemberView
  static const state = 'state';
}

/// Envelope: FCM data payloads are flat string maps, so the body travels as a
/// JSON string under 'm'. 'id' lets receivers drop duplicates (a message can
/// arrive both via push and via the inbox).
class Message {
  Message({
    required this.type,
    required this.body,
    String? id,
    this.version = Config.protocolVersion,
  }) : id = id ?? const Uuid().v4();

  final String type;
  final String id;
  final Map<String, dynamic> body;

  /// Sender's [Config.protocolVersion] (1 for builds before it existed).
  final int version;

  Map<String, String> toData() => {
    't': type,
    'id': id,
    'm': jsonEncode(body),
    'v': '$version',
  };

  static Message? fromData(Map<String, dynamic> data) {
    final t = data['t'];
    final id = data['id'];
    final m = data['m'];
    if (t is! String || id is! String || m is! String) return null;
    try {
      final body = jsonDecode(m);
      if (body is! Map<String, dynamic>) return null;
      return Message(
        type: t,
        id: id,
        body: body,
        version: int.tryParse('${data['v'] ?? ''}') ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Remembers recently seen message ids so at-least-once delivery becomes
/// effectively once.
class SeenIds {
  SeenIds({this.capacity = 500});
  final int capacity;
  final _ids = <String>{};
  final _order = <String>[];

  /// Returns true if [id] was new (and records it).
  bool add(String id) {
    if (!_ids.add(id)) return false;
    _order.add(id);
    if (_order.length > capacity) _ids.remove(_order.removeAt(0));
    return true;
  }
}
