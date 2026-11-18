import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

Group _group(
  String name, {
  String now = '',
  String fixed = '',
  List<String> suspicious = const [],
  List<String> silent = const [],
  List<String> pool = const [],
}) {
  return Group(
    type: GroupType.URLTestPool,
    name: name,
    now: now,
    fixed: fixed.isEmpty ? null : fixed,
    suspicious: suspicious,
    dataSilent: silent,
    pool: pool,
  );
}

void main() {
  test('the first read of a group only sets the baseline', () {
    final log = GroupHistoryLog();

    log.record([_group('pool', now: 'a')]);

    expect(log.of('pool'), isEmpty);
    expect(log.revision, 0);
  });

  test('records a route change with both ends', () {
    final log = GroupHistoryLog();
    log.record([_group('pool', now: 'a')]);

    log.record([_group('pool', now: 'b')]);

    final events = log.of('pool');
    expect(events, hasLength(1));
    expect(events.single.type, GroupEventType.now);
    expect(events.single.from, 'a');
    expect(events.single.to, 'b');
  });

  test('names the pin and its removal', () {
    final log = GroupHistoryLog();
    log.record([_group('pool', now: 'a', fixed: 'a')]);

    log.record([_group('pool', now: 'a', fixed: 'b')]);
    log.record([_group('pool', now: 'a')]);

    final events = log.of('pool');
    expect(events.map((event) => event.type).toList(), [
      GroupEventType.pin,
      GroupEventType.unpin,
    ]);
    expect(events.first.from, 'a');
    expect(events.first.to, 'b');
    expect(events.last.from, 'b');
  });

  test('reports a member a pool took out of play and its return', () {
    final log = GroupHistoryLog();
    log.record([_group('pool')]);

    log.record([
      _group('pool', suspicious: const ['a']),
    ]);
    log.record([_group('pool')]);

    final events = log.of('pool');
    expect(events.map((event) => event.type).toList(), [
      GroupEventType.suspicious,
      GroupEventType.recovered,
    ]);
    expect(events.first.to, 'a');
    expect(events.last.to, 'a');
  });

  test('reports a member that went silent and one that answered', () {
    final log = GroupHistoryLog();
    log.record([_group('pool')]);

    log.record([
      _group('pool', silent: const ['a']),
    ]);
    log.record([_group('pool')]);

    final events = log.of('pool');
    expect(events.map((event) => event.type).toList(), [
      GroupEventType.dataSilent,
      GroupEventType.recovered,
    ]);
  });

  test('reports a rotation that changed', () {
    final log = GroupHistoryLog();
    log.record([
      _group('pool', pool: const ['a', 'b']),
    ]);

    log.record([
      _group('pool', pool: const ['a']),
    ]);

    final events = log.of('pool');
    expect(events.single.type, GroupEventType.pool);
    expect(events.single.from, '2');
    expect(events.single.to, '1');
  });

  test('a group that left the list is read afresh', () {
    final log = GroupHistoryLog();
    log.record([_group('pool', now: 'a')]);

    log.record([]);
    log.record([_group('pool', now: 'b')]);

    expect(log.of('pool'), isEmpty, reason: 'the group is new again');
  });

  test('one group keeps a bounded window', () {
    final log = GroupHistoryLog();
    log.record([_group('pool', now: 'n0')]);

    for (var index = 1; index <= groupHistoryLimit + 8; index++) {
      log.record([_group('pool', now: 'n$index')]);
    }

    final events = log.of('pool');
    expect(events, hasLength(groupHistoryLimit));
    expect(events.first.to, 'n9', reason: 'the oldest events go first');
    expect(events.last.to, 'n${groupHistoryLimit + 8}');
  });

  test('the whole log keeps a bounded window', () {
    final log = GroupHistoryLog(perGroupLimit: 32, totalLimit: 100);
    log.record([
      for (var index = 0; index < 10; index++) _group('g$index', now: 'n0'),
    ]);

    for (var round = 1; round <= 40; round++) {
      log.record([
        for (var index = 0; index < 10; index++)
          _group('g$index', now: 'n$round'),
      ]);
    }

    final total = [
      for (var index = 0; index < 10; index++) ...log.of('g$index'),
    ];
    expect(total, hasLength(100));
    expect(
      log.of('g0').first.to,
      'n31',
      reason: 'the oldest events are evicted first',
    );
    expect(log.of('g9').last.to, 'n40', reason: 'the newest survive');
  });
}
