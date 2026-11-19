import 'package:dio/dio.dart' show Headers;
import 'package:fl_clash/common/sublink.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _link = 'http://127.0.0.1:1/c/?token=abc123';

void main() {
  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.packageInfo = PackageInfo(
      appName: 'SNKP',
      packageName: 'com.follow.clash',
      version: '1.0.61',
      buildNumber: '61',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parseSublinkLink', () {
    test('derives the status and telemetry endpoints', () {
      final link = parseSublinkLink(_link);
      expect(link, isNotNull);
      expect(link!.token, 'abc123');
      expect(link.statusUri.toString(), 'http://127.0.0.1:1/c/status');
      expect(link.telemetryUri.toString(), 'http://127.0.0.1:1/c/telemetry');
      expect(
        link.statusUri.replace(queryParameters: {'token': link.token}).toString(),
        'http://127.0.0.1:1/c/status?token=abc123',
      );
    });

    test('keeps the port, the scheme and a nested prefix', () {
      final link = parseSublinkLink('https://sub.example.com:7443/api/c?token=t');
      expect(link?.origin.port, 7443);
      expect(link?.origin.scheme, 'https');
      expect(link?.endpointPath, '/api/c');
      expect(
        link?.statusUri.toString(),
        'https://sub.example.com:7443/api/c/status',
      );
      expect(
        link?.telemetryUri.toString(),
        'https://sub.example.com:7443/api/c/telemetry',
      );
    });

    test('rejects everything that is not a share link', () {
      expect(parseSublinkLink(null), isNull);
      expect(parseSublinkLink(''), isNull);
      expect(parseSublinkLink('https://example.com/c/?token='), isNull);
      expect(parseSublinkLink('https://example.com/sub?token=abc'), isNull);
      expect(parseSublinkLink('not a url'), isNull);
    });
  });

  group('SublinkStatus', () {
    Map<String, Object?> payload({
      int limit = 10 << 30,
      int reported = 4 << 30,
      int expireAt = 0,
    }) => {
      'valid': true,
      'share': {
        'traffic_limit_bytes': limit,
        'reported_traffic_bytes': reported,
        if (expireAt > 0) 'expire_at_unix': expireAt,
      },
      'group': {
        'template': 'mihomo_snkp',
        'hide_config': true,
        'max_devices': 3,
      },
      'telemetry': {'enabled': true, 'report_interval_seconds': 900},
      'device': {'status': 'active'},
      'devices': {'active': 2},
      'notices': [
        {'title': 'Heads up', 'content': 'Template changed'},
      ],
    };

    test('reads the share, group, device and telemetry blocks', () {
      final status = SublinkStatus.fromJson(_link, payload());
      expect(status.valid, isTrue);
      expect(status.limitBytes, 10 << 30);
      expect(status.reportedBytes, 4 << 30);
      expect(status.remainingBytes, 6 << 30);
      expect(status.hideConfig, isTrue);
      expect(status.telemetryEnabled, isTrue);
      expect(status.template, 'mihomo_snkp');
      expect(status.maxDevices, 3);
      expect(status.activeDevices, 2);
      expect(status.deviceStatus, 'active');
      expect(status.noticeTitle, 'Heads up');
      expect(status.reportInterval, const Duration(seconds: 600));
    });

    test('computes the remaining bytes when the server omits them', () {
      final status = SublinkStatus.fromJson(
        _link,
        payload(limit: 1000, reported: 1200),
      );
      expect(status.remainingBytes, 0);
    });

    test('marks a past expiry and counts the days left', () {
      final past = DateTime.now().subtract(const Duration(days: 1));
      final expired = SublinkStatus.fromJson(
        _link,
        payload(expireAt: past.millisecondsSinceEpoch ~/ 1000),
      );
      expect(expired.expired, isTrue);
      expect(expired.daysLeft, 0);

      final future = DateTime.now().add(const Duration(days: 10));
      final active = SublinkStatus.fromJson(
        _link,
        payload(expireAt: future.millisecondsSinceEpoch ~/ 1000),
      );
      expect(active.expired, isFalse);
      expect(active.daysLeft, inInclusiveRange(9, 10));
    });

    test('clamps a hostile report interval', () {
      final status = SublinkStatus.fromJson(_link, {
        'telemetry': {'enabled': true, 'report_interval_seconds': 5},
      });
      expect(status.reportInterval, const Duration(seconds: 30));
    });
  });

  group('SublinkManager identity', () {
    test('adds the identity headers for a share link only', () async {
      final share = await SublinkManager.instance.headersFor(_link);
      expect(share['X-Sublink-Client'], 'snkp');
      expect(share['X-Sublink-Proto'], sublinkProtocol);
      expect(share['X-HWID'], isNotEmpty);
      expect(share['X-Device-ID'], isNotEmpty);
      expect(share['X-App-Version'], '1.0.61');

      final plain = await SublinkManager.instance.headersFor(
        'https://example.com/sub?token=abc',
      );
      expect(plain, isEmpty);
    });

    test('keeps the device secret the server returned', () async {
      final headers = {
        'x-sublink-device-secret': ['secret-1'],
        'x-sublink-reason': ['served'],
      };
      SublinkManager.instance.captureDownload(
        _link,
        _FakeHeaders.of(headers),
      );
      await Future<void>.delayed(Duration.zero);
      final next = await SublinkManager.instance.headersFor(_link);
      expect(next['X-Sublink-Device-Secret'], 'secret-1');
    });

    test('turns a stub into an error instead of a config', () {
      final headers = {
        'x-sublink-reason': ['quota_exhausted'],
        'x-sublink-stub': ['1'],
      };
      expect(
        () => SublinkManager.instance.captureDownload(
          _link,
          _FakeHeaders.of(headers),
        ),
        throwsA(
          isA<SublinkStubException>().having(
            (error) => error.reason,
            'reason',
            'quota_exhausted',
          ),
        ),
      );
    });

    test('does not report hidden mode without a fetched status', () {
      expect(SublinkManager.instance.hiddenFor(_link), isFalse);
      expect(SublinkManager.instance.statusOf('https://example.com/x'), isNull);
    });
  });
}

/// The slice of dio's Headers the manager reads, without a live response.
class _FakeHeaders implements Headers {
  _FakeHeaders(this._values);

  factory _FakeHeaders.of(Map<String, List<String>> values) =>
      _FakeHeaders(values);

  final Map<String, List<String>> _values;

  @override
  String? value(String name) {
    final values = _values[name.toLowerCase()];
    if (values == null || values.isEmpty) return null;
    return values.first;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
