import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _link = 'http://127.0.0.1:7004/c/?token=abc123';

SublinkStatus _statusWithChannels({int interval = 60}) =>
    SublinkStatus.fromJson(_link, {
      'telemetry': {
        'enabled': true,
        'sessions': interval,
        'nodes': interval,
        'reliability': interval,
        'report_interval_seconds': interval,
      },
    });

Map<String, Object?> _bodyOf(RequestOptions request) {
  final data = request.data;
  Object? decoded = data;
  if (data is String) {
    decoded = jsonDecode(data);
  } else if (data is List<int>) {
    decoded = jsonDecode(utf8.decode(data));
  }
  if (decoded is Map) {
    return Map<String, Object?>.from(decoded);
  }
  throw StateError('unexpected request body: $data');
}

ResponseBody _json(Object? body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  final manager = SublinkManager.instance;
  late _FakeAdapter adapter;

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.packageInfo = PackageInfo(
      appName: 'SNKP',
      packageName: 'com.follow.clash',
      version: '1.0.61',
      buildNumber: '61',
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await manager.debugReset();
    adapter = _FakeAdapter();
    manager.debugDio.httpClientAdapter = adapter;
  });

  tearDown(() async {
    await manager.debugReset();
  });

  test('a session announces itself and every report names it', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStartWithStatus(_link, _statusWithChannels());
    await manager.debugFlushEvents();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.path, '/c/sessions');
    final start = _bodyOf(adapter.requests.single);
    expect(start['event'], 'session_start');
    final sessionId = start['session_id'];
    expect(sessionId, isA<String>());

    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    manager.debugTraffic = () => (up: 100, down: 200);
    await manager.debugTick();

    expect(adapter.requests.last.uri.path, '/c/telemetry');
    final report = _bodyOf(adapter.requests.last);
    expect(report['session_id'], sessionId);
    expect(report['up'], 100);
    expect(report['down'], 200);
  });

  test('stopping the session reports the stop it belongs to', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStartWithStatus(_link, _statusWithChannels());
    await manager.debugFlushEvents();
    final sessionId = _bodyOf(adapter.requests.single)['session_id'];

    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    manager.debugTraffic = () => (up: 500, down: 0);
    await manager.debugReset();

    expect(adapter.requests.last.uri.path, '/c/sessions');
    final stop = _bodyOf(adapter.requests.last);
    expect(stop['event'], 'session_stop');
    expect(stop['session_id'], sessionId);
  });

  test('a refused session_start is retried with the same id', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}, status: 503));

    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStartWithStatus(_link, _statusWithChannels());
    await manager.debugFlushEvents();

    expect(manager.debugEvents, hasLength(1));
    final first = _bodyOf(adapter.requests.single)['session_id'];

    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    await manager.debugFlushEvents();

    expect(manager.debugEvents, isEmpty);
    final second = _bodyOf(adapter.requests.last)['session_id'];
    expect(second, first);
  });

  test('node deltas are reported by key and only for keyed nodes', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

    manager.debugTraffic = () => (up: 0, down: 0);
    manager.debugNodeKeys = () async => {'key-a': 'node-a', 'key-b': 'node-b'};
    manager.debugNodeTraffic = () => const [
      NodeTraffic(name: 'node-a', up: 1000, down: 2000),
      NodeTraffic(name: 'node-c', up: 5000, down: 5000),
    ];
    await manager.debugStartWithStatus(_link, _statusWithChannels());
    await manager.debugFlushEvents();

    // The first reading of a node only sets the baseline.
    await manager.debugTickNodes();
    expect(adapter.requests, hasLength(1));

    manager.debugNodeTraffic = () => const [
      NodeTraffic(name: 'node-a', up: 1300, down: 2600),
      NodeTraffic(name: 'node-c', up: 9000, down: 9000),
    ];
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    await manager.debugTickNodes();

    expect(adapter.requests.last.uri.path, '/c/nodes');
    final body = _bodyOf(adapter.requests.last);
    expect(body['window_seconds'], 60);
    expect(body['nodes'], [
      {'key': 'key-a', 'up': 300, 'down': 600},
    ]);
  });

  test(
    'the whole reputation table is reported and a recovery goes once',
    () async {
      adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

      manager.debugTraffic = () => (up: 0, down: 0);
      manager.debugNodeTraffic = () => const [];
      manager.debugNodeKeys = () async => {
        'key-a': 'node-a',
        'key-b': 'node-b',
      };
      manager.debugSilentNodes = () => const {};
      manager.debugReputation = () => const [
        NodeReputation(name: 'node-a', score: -55, fails: 3, streak: 0),
        NodeReputation(name: 'node-b', score: 80, fails: 0, streak: 5),
      ];
      await manager.debugStartWithStatus(_link, _statusWithChannels());
      await manager.debugFlushEvents();

      adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
      await manager.debugTickReliability();

      expect(adapter.requests.last.uri.path, '/c/reliability');
      final first = _bodyOf(adapter.requests.last);
      final reported = (first['nodes'] as List).cast<Map<String, Object?>>();
      // Healthy nodes belong to the snapshot too, not only the problems.
      expect(reported, hasLength(2));
      final flagged = reported.firstWhere((row) => row['key'] == 'key-a');
      expect(flagged['score'], -55);
      expect(flagged['fails'], 3);
      final healthy = reported.firstWhere((row) => row['key'] == 'key-b');
      expect(healthy['score'], 80);
      expect(healthy.containsKey('recovered'), isFalse);

      manager.debugReputation = () => const [
        NodeReputation(name: 'node-a', score: 40, fails: 0, streak: 3),
        NodeReputation(name: 'node-b', score: 80, fails: 0, streak: 6),
      ];
      adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
      await manager.debugTickReliability();

      final second = _bodyOf(adapter.requests.last);
      final recovery = (second['nodes'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((row) => row['key'] == 'key-a');
      expect(recovery['recovered'], isTrue);

      // The recovery is announced once; the healthy snapshot keeps flowing.
      adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
      await manager.debugTickReliability();
      final third = _bodyOf(adapter.requests.last);
      final steady = (third['nodes'] as List).cast<Map<String, Object?>>();
      expect(steady, hasLength(2));
      expect(steady.every((row) => row['recovered'] != true), isTrue);
      expect(adapter.requests, hasLength(4));
    },
  );
}

class _FakeAdapter implements HttpClientAdapter {
  final answers = <FutureOr<ResponseBody> Function(RequestOptions)>[];
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (answers.isEmpty) {
      throw StateError('unexpected request: ${options.uri}');
    }
    return answers.removeAt(0)(options);
  }

  @override
  void close({bool force = false}) {}
}
