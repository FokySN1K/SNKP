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
const _token = 'abc123';

SublinkStatus _status({int limit = 1000, int remaining = 1000}) =>
    SublinkStatus.fromJson(_link, {
      'share': {
        'traffic_limit_bytes': limit,
        'reported_traffic_bytes': limit - remaining,
        'remaining_bytes': remaining,
        'quota_exhausted': remaining <= 0,
      },
      'telemetry': {
        'enabled': true,
        'sessions': 60,
        'nodes': 0,
        'reliability': 0,
        'report_interval_seconds': 60,
      },
    });

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
  final blocked = <String>[];

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
    blocked.clear();
    SharedPreferences.setMockInitialValues({});
    await manager.debugReset();
    manager.debugOnBlocked = (url) async => blocked.add(url);
    adapter = _FakeAdapter();
    manager.debugDio.httpClientAdapter = adapter;
  });

  tearDown(() async {
    await manager.debugReset();
  });

  testWidgets('a spent quota stops a tunnel the server cannot hear', (
    tester,
  ) async {
    manager.debugTraffic = () => (up: 0, down: 0);
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    // The link confirmed a thousand bytes left, then the network went away and
    // the client kept using it: the report cannot land, the guard must.
    await tester.runAsync(() async {
      await manager.debugStartWithStatus(_link, _status());
      manager.debugTraffic = () => (up: 1001, down: 0);
      await manager.debugTick();
    });
    await tester.pump();

    expect(blocked, [_link]);
    expect(manager.debugActive, isFalse);
    expect(
      find.textContaining(
        currentAppLocalizations.sublinkQuotaExhausted,
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();
  });

  testWidgets('a limit raised in the panel keeps the tunnel running', (
    tester,
  ) async {
    manager.debugTraffic = () => (up: 0, down: 0);
    adapter.handler = (request) {
      if (request.uri.path == '/c/sessions') {
        return _json({'code': 0, 'data': {}});
      }
      return _json({
        'code': 0,
        'data': {
          'traffic_limit_bytes': 5000,
          'reported_traffic_bytes': 0,
          'remaining_bytes': 5000,
          'quota_exhausted': false,
        },
      });
    };
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    await tester.runAsync(() async {
      await manager.debugStartWithStatus(_link, _status());
      manager.debugTraffic = () => (up: 1200, down: 0);
      await manager.debugTick();
    });
    await tester.pump();

    expect(blocked, isEmpty);
    expect(manager.debugActive, isTrue);
    expect(manager.debugPendingBytes, 0);
    expect(manager.statusOf(_link)?.remainingBytes, 5000);
  });

  testWidgets('a restarted app keeps a spent link down while offline', (
    tester,
  ) async {
    manager.debugTraffic = () => (up: 0, down: 0);
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    await tester.runAsync(() async {
      await manager.debugStartWithStatus(_link, _status());
      manager.debugTraffic = () => (up: 1001, down: 0);
      await manager.debugTick();
    });
    await tester.pump();
    expect(blocked, [_link]);
    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();

    // A new app run: memory is gone, preferences are not.
    await tester.runAsync(() async {
      await manager.debugReset();
    });
    blocked.clear();
    manager.debugOnBlocked = (url) async => blocked.add(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sublink.$_token.consent', true);
    manager.debugActiveUrl = () => _link;

    Future<bool>? started;
    await tester.runAsync(() async {
      started = manager.prepareStart();
      // The offline status request has to fail before the guard is consulted.
      for (var i = 0; i < 100 && blocked.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(blocked, [_link]);
    expect(manager.debugActive, isFalse);
    expect(
      find.textContaining(
        currentAppLocalizations.sublinkQuotaExhausted,
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();
    bool? result;
    await tester.runAsync(() async {
      result = await started;
    });
    expect(result, isFalse);
  });
}

/// Answers every request from [handler] and records what was sent.
class _FakeAdapter implements HttpClientAdapter {
  FutureOr<ResponseBody> Function(RequestOptions)? handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final answer = handler;
    if (answer == null) {
      throw StateError('unexpected request: ${options.uri}');
    }
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}
