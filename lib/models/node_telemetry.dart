/// One outbound node's carried traffic, as the Core counts it since it started.
///
/// The Core reports absolute totals; a caller that needs an interval turns two
/// readings into the bytes moved between them.
class NodeTraffic {
  const NodeTraffic({
    required this.name,
    this.provider = '',
    this.up = 0,
    this.down = 0,
  });

  final String name;
  final String provider;
  final int up;
  final int down;

  int get bytes => up + down;

  static NodeTraffic? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    if (name is! String || name.isEmpty) return null;
    return NodeTraffic(
      name: name,
      provider: value['provider'] is String ? value['provider'] as String : '',
      up: _int(value['up']),
      down: _int(value['down']),
    );
  }
}

/// One node's reliability as the Core's reputation store holds it: the decayed
/// score plus the evidence behind it.
class NodeReputation {
  const NodeReputation({
    required this.name,
    this.score = 0,
    this.fails = 0,
    this.streak = 0,
    this.lastSeen,
  });

  final String name;
  final int score;
  final int fails;
  final int streak;
  final DateTime? lastSeen;

  static NodeReputation? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    if (name is! String || name.isEmpty) return null;
    return NodeReputation(
      name: name,
      score: _int(value['score']),
      fails: _int(value['fails']),
      streak: _int(value['streak']),
      lastSeen: DateTime.tryParse('${value['last_seen'] ?? ''}'),
    );
  }
}

int _int(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
