import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_paths.dart';

const _served =
    'proxies:\n'
    '  - {name: Tokyo, type: ss, cipher: aes-128-gcm, password: p, '
    'server: 127.0.0.1, port: 443, sublinkpro_unique_key: key-a}\n';

/// The download path end to end: a real loopback server answers the link the
/// way SublinkPro does, and the profile either installs the config or drops
/// the one it was running when the answer is a stub.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = SublinkManager.instance;
  late Directory tempDir;
  late HttpServer server;
  late ProviderContainer container;
  late String url;
  var stub = false;
  final paths = <String>[];
  final clients = <String?>[];

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('profile_update_test');
    await useAppPaths(tempDir);
    await AppLocalizations.load(const Locale('en'));
    globalState.packageInfo = PackageInfo(
      appName: 'SNKP',
      packageName: 'com.follow.clash',
      version: '1.0.61',
      buildNumber: '61',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/c/?token=share-token';
    server.listen((request) async {
      paths.add(request.uri.path);
      clients.add(request.headers.value('x-sublink-client'));
      final response = request.response;
      if (request.uri.path == '/c' || request.uri.path == '/c/') {
        if (stub) {
          response.headers.set('x-sublink-stub', '1');
          response.headers.set('x-sublink-reason', 'quota_exhausted');
          response.write('{"error":"quota_exhausted"}');
        } else {
          response.headers.contentType = ContentType(
            'text',
            'yaml',
            charset: 'utf-8',
          );
          response.headers.set('x-sublink-device-secret', 'secret-1');
          response.headers.set(
            'subscription-userinfo',
            'upload=0; download=0; total=1000; expire=0',
          );
          response.write(_served);
        }
      } else {
        response.headers.contentType = ContentType.json;
        response.write(
          '{"data":{"valid":true,"share":{"traffic_limit_bytes":1000,'
          '"reported_traffic_bytes":0,"remaining_bytes":1000}}}',
        );
      }
      await response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    stub = false;
    paths.clear();
    clients.clear();
    SharedPreferences.setMockInitialValues({});
    // The test binding answers every socket itself; these tests need a real
    // loopback server to prove what the app does with the answer.
    final bindingOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = bindingOverrides);
    // The download reads the user agent through the app container.
    container = ProviderContainer();
    globalState.container = container;
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await manager.debugReset();
  });

  Future<Profile> update(Profile profile) async {
    return profile.update(
      validate: (_, _) async => '',
      headers: await manager.headersFor(profile.url),
      onHeaders: (headers) => manager.captureDownload(profile.url, headers),
    );
  }

  test('a stub answer drops the config the link used to serve', () async {
    final profile = Profile.normal(label: 'share', url: url);
    await profile.saveFile(
      Uint8List.fromList(utf8.encode(_served)),
      validate: (_, _) async => '',
    );
    final path = await appPath.getProfilePath(profile.id.toString());
    expect(File(path).existsSync(), isTrue);

    stub = true;
    await expectLater(
      update(profile),
      throwsA(
        isA<SublinkStubException>().having(
          (error) => error.reason,
          'reason',
          'quota_exhausted',
        ),
      ),
    );

    expect(File(path).existsSync(), isFalse);
    expect(paths, contains('/c/'));
    expect(clients, contains('snkp'));
  });

  test('a served config replaces the file and keeps its node keys', () async {
    final profile = Profile.normal(label: 'share', url: url);

    final saved = await update(profile);

    expect(saved.subscriptionInfo?.total, 1000);
    expect(await saved.nodeKeys(), {'key-a': 'Tokyo'});
    final path = await appPath.getProfilePath(saved.id.toString());
    expect(
      await File(path).readAsString(),
      contains('sublinkpro_unique_key: key-a'),
    );
    expect(
      await manager.headersFor(url),
      containsPair('X-Sublink-Device-Secret', 'secret-1'),
    );
  });
}
