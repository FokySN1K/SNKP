import 'dart:io';

import 'package:fl_clash/common/sublink.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The instance is real, so the whole file is opt-in:
///   SUBLINK_LIVE_URL='http://127.0.0.1:7004/c/?token=…' flutter test …
final _url = Platform.environment['SUBLINK_LIVE_URL'];

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

  group('live SublinkPro', () {
    test('status answers the contract the UI depends on', () async {
      final status = await SublinkManager.instance.refreshStatus(_url!);
      expect(status, isNotNull);
      expect(status!.valid, isTrue);
      expect(status.template, isNotEmpty);
      expect(status.telemetryEnabled, isTrue);
      expect(status.reportInterval.inSeconds, inInclusiveRange(30, 600));
      expect(status.remainingBytes, greaterThanOrEqualTo(0));
      expect(status.deviceStatus, isNotEmpty);
    }, skip: _url == null ? 'SUBLINK_LIVE_URL is not set' : false);

    test('identity headers are accepted and the secret is kept', () async {
      final headers = await SublinkManager.instance.headersFor(_url!);
      expect(headers['X-Sublink-Client'], 'snkp');
      expect(headers['X-Device-ID'], isNotEmpty);
    }, skip: _url == null ? 'SUBLINK_LIVE_URL is not set' : false);
  });
}
