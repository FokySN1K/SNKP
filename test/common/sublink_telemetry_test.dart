import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Scaffold, SizedBox;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';

const _link = 'http://127.0.0.1:7004/c/?token=abc123';

/// The JSON body a telemetry post carried, whichever form dio left on the
/// request by the time the adapter saw it.
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

  test('a rejected report stays pending and keeps its id for the retry', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}, status: 503));
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

    manager.debugTraffic = () => (up: 1000, down: 0);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 1600, down: 0);
    await manager.debugTick();

    expect(manager.debugPendingBytes, 600);
    expect(manager.debugTotal, 600);
    expect(adapter.requests, hasLength(1));
    final first = _bodyOf(adapter.requests.single);
    expect(first['up'], 600);
    expect(first['reported_total_bytes'], 600);

    await manager.debugTick();

    expect(manager.debugPendingBytes, 0);
    expect(adapter.requests, hasLength(2));
    final second = _bodyOf(adapter.requests.last);
    expect(second['report_id'], first['report_id']);
    expect(second['up'], 600);
    expect(second['reported_total_bytes'], 600);
  });

  test('a timed-out report is kept for the next attempt', () async {
    adapter.answers.add(
      (request) => throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 12),
        requestOptions: request,
      ),
    );
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

    manager.debugTraffic = () => (up: 10, down: 20);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 110, down: 220);
    await manager.debugTick();

    expect(manager.debugPendingBytes, 300);
    expect(manager.debugTotal, 300);

    await manager.debugTick();

    expect(manager.debugPendingBytes, 0);
    final sent = _bodyOf(adapter.requests.last);
    expect(sent['up'], 100);
    expect(sent['down'], 200);
    expect(sent['reported_total_bytes'], 300);
  });

  test('a delivered report is cleared even when the body is unreadable', () async {
    adapter.answers.add(
      (_) => ResponseBody.fromString(
        '<html>maintenance</html>',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.textPlainContentType],
        },
      ),
    );

    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 512, down: 0);
    await manager.debugTick();

    expect(adapter.requests, hasLength(1));
    expect(manager.debugPendingBytes, 0);
    expect(manager.debugTotal, 512);
    expect(manager.runtime.value.lastReportAt, isNotNull);
  });

  test('stopping the session flushes what is still pending', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));

    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 1024, down: 512);
    await manager.debugReset();

    expect(adapter.requests, hasLength(1));
    final sent = _bodyOf(adapter.requests.single);
    expect(sent['up'], 1024);
    expect(sent['down'], 512);
    expect(sent['reported_total_bytes'], 1536);
  });

  test('a batch lost at stop is healed by the absolute total on restart', () async {
    adapter.answers.add((_) => _json({'code': 0, 'data': {}}, status: 500));

    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 300, down: 0);
    await manager.debugReset();

    expect(manager.debugActive, isFalse);

    adapter.answers.add((_) => _json({'code': 0, 'data': {}}));
    manager.debugTraffic = () => (up: 0, down: 0);
    await manager.debugStart(_link);
    manager.debugTraffic = () => (up: 100, down: 0);
    await manager.debugTick();

    final sent = _bodyOf(adapter.requests.last);
    expect(sent['up'], 100);
    expect(sent['reported_total_bytes'], 400);
    expect(manager.debugTotal, 400);
  });

  testWidgets('a spent quota blocks the link once and tells the user', (
    tester,
  ) async {
    final blocked = <String>[];
    manager.debugOnBlocked = (url) async => blocked.add(url);
    adapter.answers.add(
      (_) => _json({
        'code': 0,
        'data': {
          'traffic_limit_bytes': 1000,
          'reported_traffic_bytes': 1000,
          'remaining_bytes': 0,
          'quota_exhausted': true,
        },
      }),
    );
    adapter.answers.add(
      (_) => _json({
        'code': 0,
        'data': {'quota_exhausted': true, 'remaining_bytes': 0},
      }),
    );

    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    await tester.runAsync(() async {
      manager.debugTraffic = () => (up: 600, down: 0);
      await manager.debugStart(_link);
      manager.debugTraffic = () => (up: 1200, down: 0);
      await manager.debugTick();
    });
    await tester.pump();

    expect(blocked, [_link]);
    expect(manager.statusOf(_link)?.quotaExhausted, isTrue);
    expect(
      find.textContaining(
        currentAppLocalizations.sublinkQuotaExhausted,
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      manager.debugTraffic = () => (up: 1800, down: 0);
      await manager.debugTick();
    });
    await tester.pump();

    expect(blocked, [_link]);
    expect(
      find.textContaining(
        currentAppLocalizations.sublinkQuotaExhausted,
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();
    await manager.debugReset();
  });
}

/// Answers telemetry posts from a queue, recording what was sent.
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
