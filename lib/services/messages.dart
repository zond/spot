import 'dart:convert';

import 'package:uuid/uuid.dart';

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

  // host -> member
  /// MemberView
  static const state = 'state';
}

/// Envelope: FCM data payloads are flat string maps, so the body travels as a
/// JSON string under 'm'. 'id' lets receivers drop duplicates (a message can
/// arrive both via push and via the inbox).
class Message {
  Message({required this.type, required this.body, String? id})
      : id = id ?? const Uuid().v4();

  final String type;
  final String id;
  final Map<String, dynamic> body;

  Map<String, String> toData() =>
      {'t': type, 'id': id, 'm': jsonEncode(body)};

  static Message? fromData(Map<String, dynamic> data) {
    final t = data['t'];
    final id = data['id'];
    final m = data['m'];
    if (t is! String || id is! String || m is! String) return null;
    try {
      final body = jsonDecode(m);
      if (body is! Map<String, dynamic>) return null;
      return Message(type: t, id: id, body: body);
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
