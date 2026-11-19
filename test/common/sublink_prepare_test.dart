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

const _link = 'http://127.0.0.1:9/c/?token=start-token';

ResponseBody _json(Object? body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// `prepareStart` is what stands between the Play button and the tunnel: it
/// asks the link whether it still serves, keeps a spent or expired one from
/// building the tunnel, and only opens a telemetry session both the user and
/// the link agreed to.
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
    manager.debugActiveUrl = () => _link;
    adapter = _FakeAdapter();
    manager.debugDio.httpClientAdapter = adapter;
  });

  tearDown(() async {
    await manager.debugReset();
  });

  /// Starts a prepare in the real zone, as a tap would, and leaves the alert
  /// it raises on screen for the test to read.
  Future<Future<bool>> prepare(WidgetTester tester) async {
    late Future<bool> start;
    await tester.runAsync(() async {
      start = manager.prepareStart();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    return start;
  }

  testWidgets('a refused link stops the start and names the reason', (
    tester,
  ) async {
    final blocked = <String>[];
    manager.debugOnBlocked = (url) async => blocked.add(url);
    adapter.answers.add(
      (_) => _json({
        'data': {'valid': false, 'reason': 'invalid_token'},
      }),
    );
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    final start = await prepare(tester);

    expect(
      find.textContaining(
        currentAppLocalizations.sublinkLinkUnavailable,
        findRichText: true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();

    late bool started;
    await tester.runAsync(() async {
      started = await start;
    });
    expect(started, isFalse);
    expect(blocked, [_link]);
    expect(manager.debugActive, isFalse);
  });

  testWidgets('an expired link stops the start', (tester) async {
    adapter.answers.add(
      (_) => _json({
        'data': {'valid': true, 'expire_at_unix': 1},
      }),
    );
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    final start = await prepare(tester);

    expect(
      find.textContaining(
        currentAppLocalizations.sublinkExpired,
        findRichText: true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(currentAppLocalizations.confirm));
    await tester.pumpAndSettle();

    late bool started;
    await tester.runAsync(() async {
      started = await start;
    });
    expect(started, isFalse);
    expect(manager.debugActive, isFalse);
  });

  test('a server that cannot answer lets the tunnel start', () async {
    adapter.answers.add(
      (request) => throw DioException.connectionError(
        requestOptions: request,
        reason: 'unreachable',
      ),
    );

    expect(await manager.prepareStart(), isTrue);
    expect(manager.debugActive, isFalse);
  });

  test('a link without telemetry starts no session', () async {
    adapter.answers.add(
      (_) => _json({
        'data': {
          'valid': true,
          'telemetry': {'enabled': false},
        },
      }),
    );

    expect(await manager.prepareStart(), isTrue);
    expect(manager.debugActive, isFalse);
  });

  testWidgets('telemetry starts only after the user accepts', (tester) async {
    adapter.answers.add(
      (_) => _json({
        'data': {
          'valid': true,
          'telemetry': {'enabled': true},
        },
      }),
    );
    manager.debugTraffic = () => (up: 0, down: 0);
    await tester.pumpWidget(
      const TestApp(child: Scaffold(body: SizedBox.shrink())),
    );

    final start = await prepare(tester);

    expect(
      find.text(currentAppLocalizations.sublinkTelemetryTitle),
      findsOneWidget,
    );
    await tester.tap(find.text(currentAppLocalizations.sublinkTelemetryAccept));
    await tester.pumpAndSettle();

    late bool started;
    await tester.runAsync(() async {
      started = await start;
    });
    expect(started, isTrue);
    expect(manager.debugActive, isTrue);
  });
}

/// Answers the status request from a queue, recording what was asked.
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
