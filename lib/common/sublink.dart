import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/common/dialog.dart';
import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextSpan;
import 'package:shared_preferences/shared_preferences.dart';

/// The protocol version of the share endpoints this client speaks.
const sublinkProtocol = '1';

const _statusTimeout = Duration(seconds: 8);
const _telemetryTimeout = Duration(seconds: 12);
const _sessionFlushTimeout = Duration(seconds: 5);
const _minReportInterval = Duration(seconds: 30);
const _maxReportInterval = Duration(seconds: 600);
const _defaultReportInterval = Duration(seconds: 60);

/// A `…/c/?token=…` link and the sibling endpoints derived from it.
@immutable
class SublinkLink {
  final String url;
  final String token;
  final Uri origin;
  final String endpointPath;

  const SublinkLink({
    required this.url,
    required this.token,
    required this.origin,
    required this.endpointPath,
  });

  Uri get statusUri => origin.replace(path: '$endpointPath/status');

  Uri get telemetryUri => origin.replace(path: '$endpointPath/telemetry');

  String get label => origin.host;

  @override
  bool operator ==(Object other) =>
      other is SublinkLink && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);
}

/// Null unless [url] is a share link this client knows how to talk to.
SublinkLink? parseSublinkLink(String? url) {
  if (url == null) return null;
  final text = url.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  final token = uri.queryParameters['token']?.trim() ?? '';
  if (token.isEmpty) return null;
  final segments = [
    for (final segment in uri.pathSegments)
      if (segment.isNotEmpty) segment,
  ];
  if (segments.isEmpty || segments.last.toLowerCase() != 'c') return null;
  final endpointPath = '/${segments.join('/')}';
  return SublinkLink(
    url: text,
    token: token,
    origin: Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null),
    endpointPath: endpointPath,
  );
}

/// The share state the server reports for a link.
@immutable
class SublinkStatus {
  final String url;
  final bool valid;
  final String reason;
  final String template;
  final bool hideConfig;
  final bool telemetryEnabled;
  final int limitBytes;
  final int reportedBytes;
  final int remainingBytes;
  final int expireAt;
  final bool quotaExhausted;
  final int maxDevices;
  final int activeDevices;
  final String deviceStatus;
  final String? noticeTitle;
  final String? noticeContent;
  final int reportIntervalSeconds;
  final bool expired;
  final DateTime fetchedAt;

  const SublinkStatus({
    required this.url,
    this.valid = true,
    this.reason = '',
    this.template = '',
    this.hideConfig = false,
    this.telemetryEnabled = false,
    this.limitBytes = 0,
    this.reportedBytes = 0,
    this.remainingBytes = 0,
    this.expireAt = 0,
    this.quotaExhausted = false,
    this.maxDevices = 0,
    this.activeDevices = 0,
    this.deviceStatus = '',
    this.noticeTitle,
    this.noticeContent,
    this.reportIntervalSeconds = 60,
    this.expired = false,
    required this.fetchedAt,
  });

  bool get hasQuota => limitBytes > 0;

  bool get hasExpiry => expireAt > 0;

  int get daysLeft {
    if (!hasExpiry) return 0;
    final left = expireAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (left <= 0) return 0;
    return (left / Duration.secondsPerDay).ceil();
  }

  Duration get reportInterval => Duration(
    seconds: reportIntervalSeconds.clamp(
      _minReportInterval.inSeconds,
      _maxReportInterval.inSeconds,
    ),
  );

  SublinkStatus copyWith({
    int? limitBytes,
    int? reportedBytes,
    int? remainingBytes,
    bool? quotaExhausted,
    int? expireAt,
    bool? expired,
    int? activeDevices,
    String? deviceStatus,
  }) {
    return SublinkStatus(
      url: url,
      valid: valid,
      reason: reason,
      template: template,
      hideConfig: hideConfig,
      telemetryEnabled: telemetryEnabled,
      limitBytes: limitBytes ?? this.limitBytes,
      reportedBytes: reportedBytes ?? this.reportedBytes,
      remainingBytes:
          remainingBytes ??
          _remainingOf(limitBytes ?? this.limitBytes, reportedBytes ?? this.reportedBytes),
      expireAt: expireAt ?? this.expireAt,
      quotaExhausted: quotaExhausted ?? this.quotaExhausted,
      maxDevices: maxDevices,
      activeDevices: activeDevices ?? this.activeDevices,
      deviceStatus: deviceStatus ?? this.deviceStatus,
      noticeTitle: noticeTitle,
      noticeContent: noticeContent,
      reportIntervalSeconds: reportIntervalSeconds,
      expired: expired ?? this.expired,
      fetchedAt: DateTime.now(),
    );
  }

  static int _remainingOf(int limit, int reported) =>
      limit <= 0 ? 0 : max(0, limit - reported);

  static SublinkStatus fromJson(String url, Map<String, Object?> json) {
    final share = SublinkManager._map(json['share']);
    final group = SublinkManager._map(json['group']);
    final telemetry = SublinkManager._map(json['telemetry']);
    final device = SublinkManager._map(json['device']);
    final devices = SublinkManager._map(json['devices']);
    final notices = json['notices'];
    final notice = notices is List && notices.isNotEmpty
        ? SublinkManager._map(notices.first)
        : const <String, Object?>{};
    final limit = SublinkManager._int(share['traffic_limit_bytes']);
    final reported = SublinkManager._int(
      share['reported_traffic_bytes'] ?? share['used_bytes'],
    );
    final expireAt = SublinkManager._int(
      share['expire_at_unix'] ?? json['expire_at_unix'] ?? share['expire_at'],
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final explicitRemaining = share['remaining_bytes'];
    return SublinkStatus(
      url: url,
      valid: json['valid'] != false,
      reason: SublinkManager._string(json['reason']),
      template: SublinkManager._string(group['template'] ?? json['template']),
      hideConfig: group['hide_config'] == true,
      telemetryEnabled: telemetry['enabled'] == true,
      limitBytes: limit,
      reportedBytes: reported,
      remainingBytes: explicitRemaining is num
          ? max(0, explicitRemaining.toInt())
          : _remainingOf(limit, reported),
      expireAt: expireAt,
      quotaExhausted: share['quota_exhausted'] == true || json['quota_exhausted'] == true,
      maxDevices: SublinkManager._int(group['max_devices']),
      activeDevices: SublinkManager._int(
        devices['active'] ?? group['active_devices'],
      ),
      deviceStatus: SublinkManager._string(device['status']),
      noticeTitle: SublinkManager._stringOrNull(notice['title']),
      noticeContent: SublinkManager._stringOrNull(
        notice['content'] ?? notice['body'],
      ),
      reportIntervalSeconds: SublinkManager._int(
        telemetry['report_interval_seconds'] ??
            telemetry['report_interval_sessions'] ??
            _defaultReportInterval.inSeconds,
      ),
      expired: expireAt > 0 && expireAt <= now,
      fetchedAt: DateTime.now(),
    );
  }
}

/// What the UI shows about the live session.
@immutable
class SublinkRuntime {
  final String? url;
  final bool active;
  final int pendingBytes;
  final DateTime? lastReportAt;
  final String? error;

  const SublinkRuntime({
    this.url,
    this.active = false,
    this.pendingBytes = 0,
    this.lastReportAt,
    this.error,
  });

  static const idle = SublinkRuntime();
}

class _SublinkSession {
  final SublinkLink link;
  final String id;
  final int baseTotal;

  Timer? timer;
  int lastUp;
  int lastDown;
  int total;
  int pendingUp = 0;
  int pendingDown = 0;
  int seq = 0;
  bool sending = false;
  bool quotaNotified = false;

  _SublinkSession({
    required this.link,
    required this.id,
    required this.baseTotal,
  }) : lastUp = 0,
       lastDown = 0,
       total = baseTotal;
}

/// Talks to SublinkPro on behalf of the active profile.
///
/// The manager owns three things the Core cannot know: the device identity the
/// share server binds the link to, the local traffic total that makes reports
/// self-healing, and the consent the user gave to send that total.
class SublinkManager {
  SublinkManager._();

  static final SublinkManager instance = SublinkManager._();

  final ValueNotifier<Map<String, SublinkStatus>> statuses = ValueNotifier({});

  final ValueNotifier<SublinkRuntime> runtime = ValueNotifier(
    SublinkRuntime.idle,
  );

  CoreController? _core;
  String? Function()? _activeUrl;
  bool Function()? _onlyStatisticsProxy;

  final Dio _dio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 10)),
  );

  SharedPreferences? _prefs;
  _SublinkSession? _session;
  String? _installId;
  String? _deviceName;

  /// Mirror of the persisted per-token device secret so a header captured
  /// during a download is visible to the very next request.
  final Map<String, String> _secrets = {};

  void attach({
    required CoreController core,
    required String? Function() activeUrl,
    required bool Function() onlyStatisticsProxy,
  }) {
    _core = core;
    _activeUrl = activeUrl;
    _onlyStatisticsProxy = onlyStatisticsProxy;
  }

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  String _key(String token, String name) => 'sublink.$token.$name';

  // --- identity -----------------------------------------------------------

  Future<String> get installId async {
    final cached = _installId;
    if (cached != null) return cached;
    final store = await _store;
    final id = store.getString('sublink.install_id');
    if (id != null && id.isNotEmpty) {
      _installId = id;
      return id;
    }
    final next = _randomHex(16);
    await store.setString('sublink.install_id', next);
    _installId = next;
    return next;
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return [
      for (var i = 0; i < bytes; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  Future<String> _deviceLabel() async {
    final cached = _deviceName;
    if (cached != null) return cached;
    var label = Platform.localHostname;
    try {
      final info = DeviceInfoPlugin();
      if (system.isAndroid) {
        final android = await info.androidInfo;
        label = '${android.manufacturer} ${android.model}'.trim();
      } else if (system.isWindows) {
        label = (await info.windowsInfo).computerName;
      } else if (system.isMacOS) {
        label = (await info.macOsInfo).computerName;
      } else if (system.isLinux) {
        label = (await info.linuxInfo).prettyName;
      }
    } catch (_) {}
    _deviceName = label.isEmpty ? Platform.localHostname : label;
    return _deviceName!;
  }

  Future<Map<String, String>> headersFor(String url) async {
    final link = parseSublinkLink(url);
    if (link == null) return const {};
    return _identityHeaders(link);
  }

  Future<Map<String, String>> _identityHeaders(SublinkLink link) async {
    final store = await _store;
    final secret =
        _secrets[link.token] ?? store.getString(_key(link.token, 'secret'));
    return {
      'X-Sublink-Client': 'snkp',
      'X-Sublink-Proto': sublinkProtocol,
      'X-HWID': await installId,
      'X-Device-ID': await installId,
      'X-Device-Name': await _deviceLabel(),
      'X-Device-Platform': Platform.operatingSystem,
      'X-App-Version': globalState.packageInfo.version,
      if (secret != null && secret.isNotEmpty)
        'X-Sublink-Device-Secret': secret,
    };
  }

  // --- status -------------------------------------------------------------

  SublinkStatus? statusOf(String? url) {
    final link = parseSublinkLink(url);
    if (link == null) return null;
    return statuses.value[link.token];
  }

  bool hiddenFor(String? url) => statusOf(url)?.hideConfig ?? false;

  bool get activeHidden => hiddenFor(_activeUrl?.call());

  Future<SublinkStatus?> refreshStatus(String url, {Duration? timeout}) async {
    final link = parseSublinkLink(url);
    if (link == null) return null;
    try {
      final response = await _dio.getUri<Object?>(
        link.statusUri.replace(queryParameters: {'token': link.token}),
        options: Options(
          headers: await _identityHeaders(link),
          receiveTimeout: timeout ?? _statusTimeout,
          sendTimeout: timeout ?? _statusTimeout,
          validateStatus: (_) => true,
        ),
      );
      final payload = _payload(response.data);
      if (payload == null) return null;
      final status = SublinkStatus.fromJson(link.url, payload);
      _putStatus(link, status);
      return status;
    } catch (error) {
      commonPrint.log('sublink status error: $error', logLevel: LogLevel.warning);
      return null;
    }
  }

  Future<void> refreshActive() async {
    final url = _activeUrl?.call();
    if (url == null) return;
    await refreshStatus(url);
  }

  void _putStatus(SublinkLink link, SublinkStatus status) {
    statuses.value = {...statuses.value, link.token: status};
  }

  // --- telemetry ----------------------------------------------------------

  Future<bool> prepareStart() async {
    final url = _activeUrl?.call();
    final link = parseSublinkLink(url);
    if (link == null) {
      await stopSession();
      return true;
    }
    final status = await refreshStatus(link.url);
    if (status != null) {
      if (!status.valid) {
        await _alert(_reasonMessage(status.reason));
        return false;
      }
      if (status.expired) {
        await _alert(currentAppLocalizations.sublinkExpired);
        return false;
      }
      if (status.quotaExhausted) {
        await _alert(currentAppLocalizations.sublinkQuotaExhausted);
        return false;
      }
      if (!status.telemetryEnabled) {
        await stopSession();
        return true;
      }
      if (!await _ensureConsent(link)) {
        return false;
      }
      await _startSession(link, status);
      return true;
    }
    // A server that cannot answer must not block the tunnel; the session runs
    // without reporting until the next status refresh succeeds.
    if (await _hasConsent(link)) {
      await _startSession(link, null);
    }
    return true;
  }

  Future<void> stopSession() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    session.timer?.cancel();
    try {
      await _sample(session).timeout(_sessionFlushTimeout);
      await _send(session).timeout(_sessionFlushTimeout);
    } catch (error) {
      commonPrint.log('sublink flush error: $error', logLevel: LogLevel.warning);
    }
    await _persist(session);
    runtime.value = SublinkRuntime.idle;
  }

  Future<void> _startSession(SublinkLink link, SublinkStatus? status) async {
    if (_session?.link.token == link.token) return;
    await stopSession();
    final core = _core;
    if (core == null) return;
    final store = await _store;
    // The local counter is this installation's own, never the link total the
    // server reports: that one aggregates every device of the share.
    final saved =
        int.tryParse(store.getString(_key(link.token, 'total')) ?? '') ?? 0;
    final session = _SublinkSession(
      link: link,
      id: _randomHex(4),
      baseTotal: saved,
    );
    try {
      final traffic = await core.getTotalTraffic(_onlyStatisticsProxy?.call() ?? true);
      session.lastUp = traffic.up.toInt();
      session.lastDown = traffic.down.toInt();
    } catch (error) {
      commonPrint.log('sublink sample error: $error', logLevel: LogLevel.warning);
    }
    _session = session;
    final interval = status?.reportInterval ?? _defaultReportInterval;
    session.timer = Timer.periodic(interval, (_) => unawaited(_tick(session)));
    runtime.value = SublinkRuntime(
      url: link.url,
      active: true,
      pendingBytes: session.pendingUp + session.pendingDown,
    );
  }

  Future<void> _tick(_SublinkSession session) async {
    if (!identical(_session, session)) return;
    await _sample(session);
    await _send(session);
    await _persist(session);
  }

  Future<void> _sample(_SublinkSession session) async {
    final core = _core;
    if (core == null) return;
    try {
      final traffic = await core.getTotalTraffic(
        _onlyStatisticsProxy?.call() ?? true,
      );
      final up = traffic.up.toInt();
      final down = traffic.down.toInt();
      var deltaUp = up - session.lastUp;
      var deltaDown = down - session.lastDown;
      if (deltaUp < 0 || deltaDown < 0) {
        // The Core restarted and its counters with it; what it reports now is
        // the whole of this run.
        deltaUp = max(0, up);
        deltaDown = max(0, down);
      }
      session.lastUp = up;
      session.lastDown = down;
      if (deltaUp + deltaDown <= 0) return;
      session.pendingUp += deltaUp;
      session.pendingDown += deltaDown;
      session.total += deltaUp + deltaDown;
      runtime.value = SublinkRuntime(
        url: session.link.url,
        active: true,
        pendingBytes: session.pendingUp + session.pendingDown,
        lastReportAt: runtime.value.lastReportAt,
      );
    } catch (error) {
      commonPrint.log('sublink sample error: $error', logLevel: LogLevel.warning);
    }
  }

  Future<void> _send(_SublinkSession session) async {
    if (session.sending) return;
    if (session.pendingUp + session.pendingDown <= 0) return;
    session.sending = true;
    try {
      final id = await installId;
      final response = await _dio.postUri<Object?>(
        session.link.telemetryUri.replace(
          queryParameters: {'token': session.link.token},
        ),
        data: {
          'up': session.pendingUp,
          'down': session.pendingDown,
          'report_id': '$id:${session.id}:${session.seq}',
          'reported_total_bytes': session.total,
          'install_id': id,
        },
        options: Options(
          headers: await _identityHeaders(session.link),
          receiveTimeout: _telemetryTimeout,
          sendTimeout: _telemetryTimeout,
          validateStatus: (_) => true,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        commonPrint.log(
          'sublink telemetry rejected: $code',
          logLevel: LogLevel.warning,
        );
        return;
      }
      final payload = _payload(response.data);
      if (payload == null) return;
      // Either applied now or already applied by an earlier delivery of the
      // same report; both mean the batch is no longer pending.
      session.pendingUp = 0;
      session.pendingDown = 0;
      session.seq += 1;
      _applyTelemetry(session, payload);
      runtime.value = SublinkRuntime(
        url: session.link.url,
        active: true,
        pendingBytes: 0,
        lastReportAt: DateTime.now(),
      );
    } catch (error) {
      commonPrint.log('sublink telemetry error: $error', logLevel: LogLevel.warning);
    } finally {
      session.sending = false;
    }
  }

  void _applyTelemetry(_SublinkSession session, Map<String, Object?> payload) {
    final current = statuses.value[session.link.token];
    final limit = _int(payload['traffic_limit_bytes']);
    final reported = _int(payload['reported_traffic_bytes']);
    final remaining = payload['remaining_bytes'];
    final exhausted = payload['quota_exhausted'] == true;
    final next = SublinkStatus(
      url: session.link.url,
      valid: current?.valid ?? true,
      reason: current?.reason ?? '',
      template: current?.template ?? '',
      hideConfig: current?.hideConfig ?? false,
      telemetryEnabled: current?.telemetryEnabled ?? true,
      limitBytes: limit > 0 ? limit : current?.limitBytes ?? 0,
      reportedBytes: reported > 0 ? reported : current?.reportedBytes ?? 0,
      remainingBytes: remaining is num
          ? max(0, remaining.toInt())
          : SublinkStatus._remainingOf(
              limit > 0 ? limit : current?.limitBytes ?? 0,
              reported > 0 ? reported : current?.reportedBytes ?? 0,
            ),
      expireAt: current?.expireAt ?? 0,
      quotaExhausted: exhausted,
      maxDevices: current?.maxDevices ?? 0,
      activeDevices: current?.activeDevices ?? 0,
      deviceStatus: current?.deviceStatus ?? '',
      noticeTitle: current?.noticeTitle,
      noticeContent: current?.noticeContent,
      reportIntervalSeconds: current?.reportIntervalSeconds ?? 60,
      expired: current?.expired ?? false,
      fetchedAt: DateTime.now(),
    );
    statuses.value = {...statuses.value, session.link.token: next};
    if (exhausted && !(current?.quotaExhausted ?? false) && !session.quotaNotified) {
      session.quotaNotified = true;
      unawaited(_alert(currentAppLocalizations.sublinkQuotaExhausted));
    }
  }

  Future<void> _persist(_SublinkSession session) async {
    final store = await _store;
    await store.setString(_key(session.link.token, 'total'), '${session.total}');
    await store.setString(_key(session.link.token, 'last_up'), '${session.lastUp}');
    await store.setString(
      _key(session.link.token, 'last_down'),
      '${session.lastDown}',
    );
  }

  Future<bool> _hasConsent(SublinkLink link) async {
    final store = await _store;
    return store.getBool(_key(link.token, 'consent')) == true;
  }

  Future<bool> _ensureConsent(SublinkLink link) async {
    if (await _hasConsent(link)) return true;
    final accepted = await dialogs.showMessage(
      title: currentAppLocalizations.sublinkTelemetryTitle,
      message: TextSpan(text: currentAppLocalizations.sublinkTelemetryMessage),
      confirmText: currentAppLocalizations.sublinkTelemetryAccept,
    );
    if (accepted != true) return false;
    final store = await _store;
    await store.setBool(_key(link.token, 'consent'), true);
    return true;
  }

  Future<void> _alert(String message) async {
    await dialogs.showAlert(message: TextSpan(text: message));
  }

  String _reasonMessage(String reason) {
    final appLocalizations = currentAppLocalizations;
    return switch (reason) {
      'quota_exhausted' => appLocalizations.sublinkQuotaExhausted,
      'expired' => appLocalizations.sublinkExpired,
      'device_limit' || 'device_blocked' => appLocalizations.sublinkDeviceBlocked,
      'device_pending' => appLocalizations.sublinkDevicePending,
      'invalid_token' || 'group_disabled' || 'template_disabled' =>
        appLocalizations.sublinkLinkUnavailable,
      _ => appLocalizations.sublinkStatusUnavailable,
    };
  }

  /// Called when a subscription download comes back: keeps the device secret
  /// the server bound to this identity and turns a stub into an error instead
  /// of letting it overwrite a working profile.
  void captureDownload(String url, Headers headers) {
    final link = parseSublinkLink(url);
    if (link == null) return;
    final secret = headers.value('x-sublink-device-secret')?.trim();
    if (secret != null && secret.isNotEmpty) {
      _secrets[link.token] = secret;
      unawaited(_saveSecret(link, secret));
    }
    final reason = headers.value('x-sublink-reason')?.trim();
    final stub = headers.value('x-sublink-stub') != null ||
        (reason != null &&
            reason.isNotEmpty &&
            reason != 'ok' &&
            reason != 'served');
    if (stub) {
      throw MessageException(
        reason == null || reason.isEmpty
            ? currentAppLocalizations.sublinkStatusUnavailable
            : _reasonMessage(reason),
      );
    }
    unawaited(refreshStatus(link.url));
  }

  Future<void> _saveSecret(SublinkLink link, String secret) async {
    final store = await _store;
    await store.setString(_key(link.token, 'secret'), secret);
  }

  Future<void> forget(String url) async {
    final link = parseSublinkLink(url);
    if (link == null) return;
    _secrets.remove(link.token);
    final store = await _store;
    for (final name in ['secret', 'consent', 'total', 'last_up', 'last_down']) {
      await store.remove(_key(link.token, name));
    }
    final next = {...statuses.value}..remove(link.token);
    statuses.value = next;
  }

  // --- parsing helpers ----------------------------------------------------

  static Map<String, Object?> _map(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return {
        for (final entry in value.entries) '${entry.key}': entry.value,
      };
    }
    return const {};
  }

  static int _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static String _string(Object? value) => value is String ? value : '';

  static String? _stringOrNull(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  /// The `data` envelope every SublinkPro endpoint answers with, or the body
  /// itself when the endpoint answers bare.
  static Map<String, Object?>? _payload(Object? body) {
    final map = _map(body);
    if (map.isEmpty) return null;
    final data = map['data'];
    if (data is Map) return _map(data);
    if (map.containsKey('code') && map['code'] != 0 && data == null) {
      return null;
    }
    return map;
  }
}
