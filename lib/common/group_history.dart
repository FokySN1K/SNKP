import 'package:fl_clash/models/models.dart';

/// How many events one group keeps. A group with hundreds of nodes would
/// otherwise fill the window with its own churn.
const groupHistoryLimit = 32;

/// How many events the whole log keeps: a profile with hundreds of groups must
/// not grow the window with the subscription size.
const totalHistoryLimit = 2048;

/// What a group did, as the page can tell it apart.
enum GroupEventType {
  /// The member the group routes through changed.
  now,

  /// A user pinned a member.
  pin,

  /// A user took the pin away.
  unpin,

  /// A pool took a member out of play.
  suspicious,

  /// A member came back into play.
  recovered,

  /// A member stopped answering after its handshake.
  dataSilent,

  /// A pool changed the members it keeps in rotation.
  pool,
}

class GroupEvent {
  const GroupEvent({
    required this.time,
    required this.type,
    this.from = '',
    this.to = '',
  });

  final DateTime time;
  final GroupEventType type;
  final String from;
  final String to;
}

class _Entry {
  const _Entry(this.group, this.event);

  final String group;
  final GroupEvent event;
}

class _Snapshot {
  _Snapshot(Group group)
    : now = group.now ?? '',
      fixed = group.fixed ?? '',
      suspicious = group.suspicious.toSet(),
      silent = group.dataSilent.toSet(),
      pool = group.pool.toSet();

  final String now;
  final String fixed;
  final Set<String> suspicious;
  final Set<String> silent;
  final Set<String> pool;
}

/// What the proxies page has seen a group do this session. The page reads the
/// group list on its own schedule, so it differs what it reads instead of the
/// Core keeping the app's window: a group the log has not read before only
/// sets the baseline, and a group that left the list is forgotten.
///
/// The window is bounded on purpose. The page polls every couple of seconds
/// and a subscription can carry hundreds of groups, so an unbounded log would
/// grow with uptime instead of staying a window onto the last few switches.
class GroupHistoryLog {
  GroupHistoryLog({
    this.perGroupLimit = groupHistoryLimit,
    this.totalLimit = totalHistoryLimit,
  });

  final int perGroupLimit;
  final int totalLimit;

  final List<_Entry> _entries = [];
  final Map<String, int> _counts = {};
  Map<String, _Snapshot> _snapshots = {};

  /// Moves on every change, so a sheet can watch the log without the log
  /// itself having to be a provider's state.
  int revision = 0;

  /// The events of one group, oldest first.
  List<GroupEvent> of(String group) {
    return [
      for (final entry in _entries)
        if (entry.group == group) entry.event,
    ];
  }

  void reset() {
    _entries.clear();
    _counts.clear();
    _snapshots = {};
    revision++;
  }

  /// Records what changed between this read of the group list and the one
  /// before it.
  void record(List<Group> groups) {
    final now = DateTime.now();
    final next = <String, _Snapshot>{};
    for (final group in groups) {
      final snapshot = _Snapshot(group);
      next[group.name] = snapshot;
      final previous = _snapshots[group.name];
      if (previous != null) {
        _diff(group.name, previous, snapshot, now);
      }
    }
    _snapshots = next;
  }

  void _diff(String group, _Snapshot previous, _Snapshot next, DateTime now) {
    if (previous.now != next.now) {
      _add(
        group,
        GroupEvent(
          time: now,
          type: GroupEventType.now,
          from: previous.now,
          to: next.now,
        ),
      );
    }
    if (previous.fixed != next.fixed) {
      _add(
        group,
        next.fixed.isEmpty
            ? GroupEvent(
                time: now,
                type: GroupEventType.unpin,
                from: previous.fixed,
              )
            : GroupEvent(
                time: now,
                type: GroupEventType.pin,
                from: previous.fixed,
                to: next.fixed,
              ),
      );
    }
    for (final name in next.suspicious.difference(previous.suspicious)) {
      _add(
        group,
        GroupEvent(time: now, type: GroupEventType.suspicious, to: name),
      );
    }
    for (final name in previous.suspicious.difference(next.suspicious)) {
      _add(
        group,
        GroupEvent(time: now, type: GroupEventType.recovered, to: name),
      );
    }
    for (final name in next.silent.difference(previous.silent)) {
      _add(
        group,
        GroupEvent(time: now, type: GroupEventType.dataSilent, to: name),
      );
    }
    for (final name in previous.silent.difference(next.silent)) {
      _add(
        group,
        GroupEvent(time: now, type: GroupEventType.recovered, to: name),
      );
    }
    if (previous.pool.length != next.pool.length ||
        !previous.pool.containsAll(next.pool)) {
      _add(
        group,
        GroupEvent(
          time: now,
          type: GroupEventType.pool,
          from: '${previous.pool.length}',
          to: '${next.pool.length}',
        ),
      );
    }
  }

  void _add(String group, GroupEvent event) {
    _entries.add(_Entry(group, event));
    final count = _counts[group] = (_counts[group] ?? 0) + 1;
    if (count > perGroupLimit) {
      _removeOldestOf(group);
    }
    while (_entries.length > totalLimit) {
      _removeAt(0);
    }
    revision++;
  }

  void _removeOldestOf(String group) {
    for (var index = 0; index < _entries.length; index++) {
      if (_entries[index].group == group) {
        _removeAt(index);
        return;
      }
    }
  }

  void _removeAt(int index) {
    final removed = _entries.removeAt(index);
    final left = (_counts[removed.group] ?? 1) - 1;
    if (left <= 0) {
      _counts.remove(removed.group);
    } else {
      _counts[removed.group] = left;
    }
  }
}
