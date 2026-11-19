import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/common/dialog.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/models/node_telemetry.dart';
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
const _minChannelInterval = Duration(seconds: 30);
const _maxChannelInterval = Duration(seconds: 3600);

/// A stopped session whose event never reached the server is retried for
/// this long before it is dropped from the queue.
const _eventRetention = Duration(days: 3);
const _maxPendingEvents = 64;

/// The keys of the active config are re-read after this long; a profile
/// update invalidates them sooner.
const _keyCacheTtl = Duration(minutes: 15);

const _maxNodeRows = 200;
const _maxReliabilityRows = 100;

/// A node scoring below this is not trusted, which is what the reliability
/// channel reports; the value matches the Core's `reputation.Trusted`.
const _trustedScore = 30;

/// The share server answered with a stub instead of a config: the link is
/// spent, expired, hidden from this client or its device is not allowed to run
/// it. It is an error, not a config, so nothing installs it as a profile, and
/// the file the link used to serve no longer has a reason to stay.
final class SublinkStubException implements Exception {
  final String reason;
  final String message;

  const SublinkStubException(this.reason, this.message);

  @override
  String toString() => message;
}

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

  Uri get sessionsUri => origin.replace(path: '$endpointPath/sessions');

  Uri get nodesUri => origin.replace(path: '$endpointPath/nodes');

  Uri get reliabilityUri => origin.replace(path: '$endpointPath/reliability');

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
    origin: Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ),
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

  /// Seconds between session events; zero when the server does not take
  /// them from this link.
  final int sessionsIntervalSeconds;

  /// Seconds between per-node traffic reports; zero when the server does
  /// not take them from this link.
  final int nodesIntervalSeconds;

  /// Seconds between reliability snapshots; zero when the server does not
  /// take them from this link.
  final int reliabilityIntervalSeconds;
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
    this.sessionsIntervalSeconds = 0,
    this.nodesIntervalSeconds = 0,
    this.reliabilityIntervalSeconds = 0,
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

  bool get sessionsEnabled => sessionsIntervalSeconds > 0;

  bool get nodesEnabled => nodesIntervalSeconds > 0;

  bool get reliabilityEnabled => reliabilityIntervalSeconds > 0;

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
          _remainingOf(
            limitBytes ?? this.limitBytes,
            reportedBytes ?? this.reportedBytes,
          ),
      expireAt: expireAt ?? this.expireAt,
      quotaExhausted: quotaExhausted ?? this.quotaExhausted,
      maxDevices: maxDevices,
      activeDevices: activeDevices ?? this.activeDevices,
      deviceStatus: deviceStatus ?? this.deviceStatus,
      noticeTitle: noticeTitle,
      noticeContent: noticeContent,
      reportIntervalSeconds: reportIntervalSeconds,
      sessionsIntervalSeconds: sessionsIntervalSeconds,
      nodesIntervalSeconds: nodesIntervalSeconds,
      reliabilityIntervalSeconds: reliabilityIntervalSeconds,
      expired: expired ?? this.expired,
      fetchedAt: DateTime.now(),
    );
  }

  static int _remainingOf(int limit, int reported) =>
      limit <= 0 ? 0 : max(0, limit - reported);

  /// A channel the status says is on: the server may name the interval
  /// itself, send a flag with the shared interval behind it, or send zero
  /// for a channel it does not take from this link.
  static int _channelSeconds(
    Object? value,
    bool telemetryEnabled,
    int fallback,
  ) {
    if (!telemetryEnabled) return 0;
    if (value is bool) return value ? fallback : 0;
    final seconds = SublinkManager._int(value);
    if (seconds <= 0) return 0;
    return seconds.clamp(
      _minChannelInterval.inSeconds,
      _maxChannelInterval.inSeconds,
    );
  }

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
    final telemetryEnabled = telemetry['enabled'] == true;
    final baseInterval = SublinkManager._int(
      telemetry['report_interval_seconds'] ??
          telemetry['report_interval_sessions'] ??
          _defaultReportInterval.inSeconds,
    );
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
      quotaExhausted:
          share['quota_exhausted'] == true || json['quota_exhausted'] == true,
      maxDevices: SublinkManager._int(group['max_devices']),
      activeDevices: SublinkManager._int(
        devices['active'] ?? group['active_devices'],
      ),
      deviceStatus: SublinkManager._string(device['status']),
      noticeTitle: SublinkManager._stringOrNull(notice['title']),
      noticeContent: SublinkManager._stringOrNull(
        notice['content'] ?? notice['body'],
      ),
      reportIntervalSeconds: baseInterval,
      sessionsIntervalSeconds: _channelSeconds(
        telemetry['sessions'],
        telemetryEnabled,
        baseInterval,
      ),
      nodesIntervalSeconds: _channelSeconds(
        telemetry['nodes'],
        telemetryEnabled,
        baseInterval,
      ),
      reliabilityIntervalSeconds: _channelSeconds(
        telemetry['reliability'],
        telemetryEnabled,
        baseInterval,
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
  Timer? nodesTimer;
  Timer? reliabilityTimer;
  int sessionsInterval = 0;
  int nodesInterval = 0;
  int nodeSeq = 0;
  int reliabilitySeq = 0;
  bool sendingNodes = false;
  final Map<String, ({int up, int down})> nodeTotals = {};
  final Map<String, ({int up, int down})> nodePending = {};
  int lastUp;
  int lastDown;
  int total;
  int pendingUp = 0;
  int pendingDown = 0;
  int seq = 0;
  bool sending = false;
  bool quotaNotified = false;
  // The quota the server last confirmed and the absolute total it arrived
  // at: every confirmed byte lowers the remaining by the same amount the
  // total grew, so the pair tells when the link is spent even offline.
  int? quotaRemaining;
  int quotaRemainingTotal = 0;

  _SublinkSession({
    required this.link,
    required this.id,
    required this.baseTotal,
  }) : lastUp = 0,
       lastDown = 0,
       total = baseTotal;
}

/// A session event that has to outlive the session it belongs to: a stop the
/// network refused is retried until the server takes it, and the queue is
/// persisted so an app restart does not lose it.
class _SublinkEvent {
  const _SublinkEvent({
    required this.url,
    required this.event,
    required this.sessionId,
    required this.total,
    required this.createdAt,
  });

  final String url;
  final String event;
  final String sessionId;
  final int total;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'url': url,
    'event': event,
    'session_id': sessionId,
    'reported_total_bytes': total,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  static _SublinkEvent? fromJson(Object? value) {
    if (value is! Map) return null;
    final url = value['url'];
    final event = value['event'];
    final sessionId = value['session_id'];
    if (url is! String || url.isEmpty) return null;
    if (event is! String || event.isEmpty) return null;
    if (sessionId is! String || sessionId.isEmpty) return null;
    return _SublinkEvent(
      url: url,
      event: event,
      sessionId: sessionId,
      total: SublinkManager._int(value['reported_total_bytes']),
      createdAt:
          DateTime.tryParse('${value['created_at'] ?? ''}') ?? DateTime.now(),
    );
  }
}

const _sessionStartEvent = 'session_start';
const _sessionStopEvent = 'session_stop';

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
  Future<void> Function(String url)? _onBlocked;

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

  /// The per-channel intervals the config download announced, which the
  /// status endpoint may not repeat.
  final Map<String, ({int sessions, int nodes, int reliability})> _intervals =
      {};

  /// `node name -> sublinkpro_unique_key` of the active config.
  Future<Map<String, String>> Function()? _nodeKeys;
  Map<String, String>? _keysByNameCache;
  DateTime? _keysByNameAt;

  final List<_SublinkEvent> _events = [];
  bool _eventsLoaded = false;
  Future<void>? _flushingFuture;

  void attach({
    required CoreController core,
    required String? Function() activeUrl,
    required bool Function() onlyStatisticsProxy,
    Future<void> Function(String url)? onBlocked,
    Future<Map<String, String>> Function()? nodeKeys,
  }) {
    _core = core;
    _activeUrl = activeUrl;
    _onlyStatisticsProxy = onlyStatisticsProxy;
    _onBlocked = onBlocked;
    _nodeKeys = nodeKeys;
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
      commonPrint.log(
        'sublink status error: $error',
        logLevel: LogLevel.warning,
      );
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

  /// Whether a start has to wait for the link before the tunnel is built:
  /// `prepareStart` weighs what the link's status, consent and session say.
  bool get startNeedsLink =>
      _session != null || parseSublinkLink(_activeUrl?.call()) != null;

  /// Whether a stop has a session whose traffic still needs a flush.
  bool get hasSession => _session != null;

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
        _notifyBlocked(link);
        await _alert(_reasonMessage(status.reason));
        return false;
      }
      if (status.expired) {
        _notifyBlocked(link);
        await _alert(currentAppLocalizations.sublinkExpired);
        return false;
      }
      if (status.quotaExhausted) {
        _notifyBlocked(link);
        await _alert(currentAppLocalizations.sublinkQuotaExhausted);
        return false;
      }
      await _rememberQuotaTrip(link, false);
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
    // without reporting until the next status refresh succeeds. A link the
    // guard already found spent is the exception: without a server to say
    // otherwise, the tunnel stays down instead of running past its quota.
    if (await _hasConsent(link)) {
      if (await _quotaTripRemembered(link)) {
        _notifyBlocked(link);
        await _alert(currentAppLocalizations.sublinkQuotaExhausted);
        return false;
      }
      await _startSession(link, null);
    }
    return true;
  }

  Future<void> stopSession() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    session.timer?.cancel();
    session.nodesTimer?.cancel();
    session.reliabilityTimer?.cancel();
    try {
      await _sample(session).timeout(_sessionFlushTimeout);
      await _send(session).timeout(_sessionFlushTimeout);
      await _tickNodes(session).timeout(_sessionFlushTimeout);
    } catch (error) {
      commonPrint.log(
        'sublink flush error: $error',
        logLevel: LogLevel.warning,
      );
    }
    if (session.sessionsInterval > 0) {
      _enqueueEvent(session, _sessionStopEvent);
      try {
        await _flushEvents().timeout(_sessionFlushTimeout);
      } catch (error) {
        commonPrint.log(
          'sublink session flush error: $error',
          logLevel: LogLevel.warning,
        );
      }
    }
    await _persist(session);
    runtime.value = SublinkRuntime.idle;
  }

  Future<void> _startSession(SublinkLink link, SublinkStatus? status) async {
    if (_session?.link.token == link.token) return;
    await stopSession();
    if (_core == null && debugTraffic == null) return;
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
    final traffic = await _readTraffic();
    if (traffic != null) {
      session.lastUp = traffic.up;
      session.lastDown = traffic.down;
    }
    final intervals = _intervals[link.token];
    session.sessionsInterval = _preferredInterval(
      status?.sessionsIntervalSeconds ?? 0,
      intervals?.sessions,
    );
    session.nodesInterval = _preferredInterval(
      status?.nodesIntervalSeconds ?? 0,
      intervals?.nodes,
    );
    final reliabilityInterval = _preferredInterval(
      status?.reliabilityIntervalSeconds ?? 0,
      intervals?.reliability,
    );
    if (status != null && status.hasQuota) {
      session.quotaRemaining = status.remainingBytes;
      session.quotaRemainingTotal = session.total;
    }
    _session = session;
    await _loadEvents();
    final interval = status?.reportInterval ?? _defaultReportInterval;
    session.timer = Timer.periodic(interval, (_) => unawaited(_tick(session)));
    if (session.nodesInterval > 0) {
      session.nodesTimer = Timer.periodic(
        Duration(seconds: session.nodesInterval),
        (_) {
          if (identical(_session, session)) unawaited(_tickNodes(session));
        },
      );
      await _sampleNodes(session);
    }
    if (reliabilityInterval > 0) {
      session.reliabilityTimer = Timer.periodic(
        Duration(seconds: reliabilityInterval),
        (_) {
          if (identical(_session, session)) {
            unawaited(_tickReliability(session));
          }
        },
      );
    }
    if (session.sessionsInterval > 0) {
      _enqueueEvent(session, _sessionStartEvent);
      unawaited(_flushEvents());
    }
    runtime.value = SublinkRuntime(
      url: link.url,
      active: true,
      pendingBytes: session.pendingUp + session.pendingDown,
    );
  }

  Future<void> _tick(_SublinkSession session) async {
    if (!identical(_session, session)) return;
    // A start the network refused goes before the report that names its
    // session, so the server sees the session before its bytes.
    await _flushEvents();
    await _sample(session);
    if (await _stopOnSpentQuota(session)) return;
    await _send(session);
    await _persist(session);
  }

  /// The counters this run has moved: the Core's, or a test's stand-in.
  Future<({int up, int down})?> _readTraffic() async {
    final debug = debugTraffic;
    if (debug != null) return debug();
    final core = _core;
    if (core == null) return null;
    try {
      final traffic = await core.getTotalTraffic(
        _onlyStatisticsProxy?.call() ?? true,
      );
      return (up: traffic.up.toInt(), down: traffic.down.toInt());
    } catch (error) {
      commonPrint.log(
        'sublink sample error: $error',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> _sample(_SublinkSession session) async {
    final traffic = await _readTraffic();
    if (traffic == null) return;
    try {
      final up = traffic.up;
      final down = traffic.down;
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
      commonPrint.log(
        'sublink sample error: $error',
        logLevel: LogLevel.warning,
      );
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
          'session_id': session.id,
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
      // Either applied now or already applied by an earlier delivery of the
      // same report; both mean the batch is no longer pending. The body only
      // carries the live quota: one that does not parse must not keep a
      // delivered batch pending forever.
      session.pendingUp = 0;
      session.pendingDown = 0;
      session.seq += 1;
      final payload = _payload(response.data);
      if (payload != null) {
        _applyTelemetry(session, payload);
      }
      runtime.value = SublinkRuntime(
        url: session.link.url,
        active: true,
        pendingBytes: 0,
        lastReportAt: DateTime.now(),
      );
    } catch (error) {
      commonPrint.log(
        'sublink telemetry error: $error',
        logLevel: LogLevel.warning,
      );
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
      sessionsIntervalSeconds: current?.sessionsIntervalSeconds ?? 0,
      nodesIntervalSeconds: current?.nodesIntervalSeconds ?? 0,
      reliabilityIntervalSeconds: current?.reliabilityIntervalSeconds ?? 0,
      expired: current?.expired ?? false,
      fetchedAt: DateTime.now(),
    );
    statuses.value = {...statuses.value, session.link.token: next};
    if (next.hasQuota) {
      session.quotaRemaining = next.remainingBytes;
      session.quotaRemainingTotal = session.total;
      if (!exhausted) {
        unawaited(_rememberQuotaTrip(session.link, false));
      }
    } else {
      session.quotaRemaining = null;
    }
    if (exhausted &&
        !(current?.quotaExhausted ?? false) &&
        !session.quotaNotified) {
      session.quotaNotified = true;
      // A spent link can no longer serve its config: the tunnel and the file
      // it runs go away with the alert.
      _notifyBlocked(session.link);
      unawaited(_alert(currentAppLocalizations.sublinkQuotaExhausted));
    }
  }

  /// Stops the tunnel when the confirmed quota is used up: the local total
  /// outgrew what the last server answer left. Returns true when it stopped
  /// the session.
  ///
  /// The math is exact while no other device spends from the same link: a
  /// confirmed report lowers the remaining by the delta it added to the total,
  /// so both sides meet where the server would call the link spent. A final
  /// report settles it when the link is reachable, so a limit raised in the
  /// panel never stops a tunnel that still has traffic; a link that cannot be
  /// reached is stopped on the last confirmed numbers.
  Future<bool> _stopOnSpentQuota(_SublinkSession session) async {
    final remaining = session.quotaRemaining;
    if (remaining == null || remaining < 0) return false;
    if (session.total - session.quotaRemainingTotal < remaining) return false;
    await _send(session);
    final settled = session.quotaRemaining;
    if (settled != null &&
        session.total - session.quotaRemainingTotal < settled) {
      return false;
    }
    if (!session.quotaNotified) {
      session.quotaNotified = true;
      _notifyBlocked(session.link);
      unawaited(_alert(currentAppLocalizations.sublinkQuotaExhausted));
    }
    await _rememberQuotaTrip(session.link, true);
    await stopSession();
    return true;
  }

  Future<bool> _quotaTripRemembered(SublinkLink link) async {
    final store = await _store;
    return store.getBool(_key(link.token, 'quota_tripped')) == true;
  }

  Future<void> _rememberQuotaTrip(SublinkLink link, bool tripped) async {
    final store = await _store;
    final key = _key(link.token, 'quota_tripped');
    if (tripped) {
      if (store.getBool(key) != true) {
        await store.setBool(key, true);
      }
      return;
    }
    if (store.getBool(key) == true) {
      await store.remove(key);
    }
  }

  Future<void> _persist(_SublinkSession session) async {
    final store = await _store;
    await store.setString(
      _key(session.link.token, 'total'),
      '${session.total}',
    );
    await store.setString(
      _key(session.link.token, 'last_up'),
      '${session.lastUp}',
    );
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
      'device_limit' ||
      'device_blocked' => appLocalizations.sublinkDeviceBlocked,
      'device_pending' => appLocalizations.sublinkDevicePending,
      'invalid_token' ||
      'group_disabled' ||
      'template_disabled' => appLocalizations.sublinkLinkUnavailable,
      _ => appLocalizations.sublinkStatusUnavailable,
    };
  }

  /// Called when a subscription download comes back: keeps the device secret
  /// the server bound to this identity and turns a stub into an error instead
  /// of letting it overwrite a working profile.
  void captureDownload(String url, Headers headers) {
    final link = parseSublinkLink(url);
    if (link == null) return;
    final announced = (
      sessions: _headerSeconds(headers, 'x-sublink-report-interval-sessions'),
      nodes: _headerSeconds(headers, 'x-sublink-report-interval-nodes'),
      reliability: _headerSeconds(
        headers,
        'x-sublink-report-interval-reliability',
      ),
    );
    if (announced.sessions != null ||
        announced.nodes != null ||
        announced.reliability != null) {
      _intervals[link.token] = (
        sessions: announced.sessions ?? 0,
        nodes: announced.nodes ?? 0,
        reliability: announced.reliability ?? 0,
      );
    }
    // The config that carries the keys is being replaced.
    _keysByNameCache = null;
    _keysByNameAt = null;
    final secret = headers.value('x-sublink-device-secret')?.trim();
    if (secret != null && secret.isNotEmpty) {
      _secrets[link.token] = secret;
      unawaited(_saveSecret(link, secret));
    }
    final reason = headers.value('x-sublink-reason')?.trim();
    final stub =
        headers.value('x-sublink-stub') != null ||
        (reason != null &&
            reason.isNotEmpty &&
            reason != 'ok' &&
            reason != 'served');
    if (stub) {
      throw SublinkStubException(
        reason ?? '',
        reason == null || reason.isEmpty
            ? currentAppLocalizations.sublinkStatusUnavailable
            : _reasonMessage(reason),
      );
    }
    unawaited(refreshStatus(link.url));
  }

  static int? _headerSeconds(Headers headers, String name) {
    final value = headers.value(name)?.trim();
    if (value == null || value.isEmpty) return null;
    final seconds = int.tryParse(value);
    if (seconds == null || seconds <= 0) return null;
    return seconds.clamp(
      _minChannelInterval.inSeconds,
      _maxChannelInterval.inSeconds,
    );
  }

  /// The interval a channel runs at: the status wins, the config download
  /// fills in what the status did not say, zero switches the channel off.
  static int _preferredInterval(int fromStatus, int? fromHeader) {
    if (fromStatus > 0) return fromStatus;
    final header = fromHeader ?? 0;
    if (header <= 0) return 0;
    return header.clamp(
      _minChannelInterval.inSeconds,
      _maxChannelInterval.inSeconds,
    );
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
    for (final name in [
      'secret',
      'consent',
      'total',
      'last_up',
      'last_down',
      'problems',
      'quota_tripped',
    ]) {
      await store.remove(_key(link.token, name));
    }
    _events.removeWhere((event) => event.url == link.url);
    _intervals.remove(link.token);
    _keysByNameCache = null;
    _keysByNameAt = null;
    final next = {...statuses.value}..remove(link.token);
    statuses.value = next;
  }

  void _notifyBlocked(SublinkLink link) {
    final onBlocked = _onBlocked;
    if (onBlocked == null) return;
    unawaited(onBlocked(link.url));
  }

  // --- sessions, nodes and reliability ------------------------------------

  void _enqueueEvent(_SublinkSession session, String event) {
    _events.add(
      _SublinkEvent(
        url: session.link.url,
        event: event,
        sessionId: session.id,
        total: session.total,
        createdAt: DateTime.now(),
      ),
    );
    if (_events.length > _maxPendingEvents) {
      _events.removeRange(0, _events.length - _maxPendingEvents);
    }
    unawaited(_persistEvents());
  }

  Future<void> _loadEvents() async {
    if (_eventsLoaded) return;
    _eventsLoaded = true;
    final store = await _store;
    final raw = store.getString('sublink.events');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final now = DateTime.now();
      for (final item in decoded) {
        final event = _SublinkEvent.fromJson(item);
        if (event == null) continue;
        if (now.difference(event.createdAt) > _eventRetention) continue;
        _events.add(event);
      }
    } catch (error) {
      commonPrint.log(
        'sublink event load error: $error',
        logLevel: LogLevel.warning,
      );
    }
  }

  Future<void> _persistEvents() async {
    final store = await _store;
    await store.setString(
      'sublink.events',
      jsonEncode([for (final event in _events) event.toJson()]),
    );
  }

  /// Delivers the queued session events in order; a refused event keeps the
  /// queue, and the next tick or the next start retries it with the same
  /// session id.
  Future<void> _flushEvents() {
    final running = _flushingFuture;
    if (running != null) return running;
    if (_events.isEmpty) return Future.value();
    final future = _flushEventsNow().whenComplete(() {
      _flushingFuture = null;
    });
    _flushingFuture = future;
    return future;
  }

  Future<void> _flushEventsNow() async {
    try {
      final id = await installId;
      while (_events.isNotEmpty) {
        final event = _events.first;
        final link = parseSublinkLink(event.url);
        if (link == null) {
          _events.removeAt(0);
          continue;
        }
        final payload = event.toJson()..remove('url');
        final response = await _dio.postUri<Object?>(
          link.sessionsUri.replace(queryParameters: {'token': link.token}),
          data: {...payload, 'install_id': id},
          options: Options(
            headers: await _identityHeaders(link),
            receiveTimeout: _telemetryTimeout,
            sendTimeout: _telemetryTimeout,
            validateStatus: (_) => true,
          ),
        );
        final code = response.statusCode ?? 0;
        if (code < 200 || code >= 300) break;
        _events.removeAt(0);
      }
    } catch (error) {
      commonPrint.log(
        'sublink session error: $error',
        logLevel: LogLevel.warning,
      );
    } finally {
      unawaited(_persistEvents());
    }
  }

  Future<List<NodeTraffic>?> _readNodeTraffic() async {
    final debug = debugNodeTraffic;
    if (debug != null) return debug();
    final core = _core;
    if (core == null) return null;
    try {
      return await core.getNodeTraffic();
    } catch (error) {
      commonPrint.log(
        'sublink node sample error: $error',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<List<NodeReputation>?> _readReputation() async {
    final debug = debugReputation;
    if (debug != null) return debug();
    final core = _core;
    if (core == null) return null;
    try {
      return await core.getReputation();
    } catch (error) {
      commonPrint.log(
        'sublink reputation error: $error',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  /// The nodes any group holds silent right now, which is the data-plane
  /// observer's mark on top of the reputation score.
  Future<Set<String>> _readSilent() async {
    final debug = debugSilentNodes;
    if (debug != null) return debug();
    final core = _core;
    if (core == null) return const {};
    try {
      final data = await core.getProxiesData();
      final silent = <String>{};
      for (final value in data.proxies.values) {
        if (value is! Map) continue;
        final names = value['dataSilent'];
        if (names is! List) continue;
        for (final name in names) {
          if (name is String && name.isNotEmpty) silent.add(name);
        }
      }
      return silent;
    } catch (error) {
      commonPrint.log(
        'sublink silent read error: $error',
        logLevel: LogLevel.warning,
      );
      return const {};
    }
  }

  /// `node name -> key` of the config that is running, cached so a report does
  /// not parse the profile every time.
  Future<Map<String, String>> _keysByName() async {
    final cached = _keysByNameCache;
    final at = _keysByNameAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _keyCacheTtl) {
      return cached;
    }
    final read = debugNodeKeys ?? _nodeKeys;
    if (read == null) return cached ?? const {};
    try {
      final byKey = await read();
      final byName = <String, String>{};
      for (final entry in byKey.entries) {
        if (entry.key.isEmpty || entry.value.isEmpty) continue;
        byName[entry.value] = entry.key;
      }
      _keysByNameCache = byName;
      _keysByNameAt = DateTime.now();
      return byName;
    } catch (error) {
      commonPrint.log(
        'sublink key read error: $error',
        logLevel: LogLevel.warning,
      );
      return cached ?? const {};
    }
  }

  /// Turns two Core readings into the bytes each node moved between them. A
  /// node seen for the first time only sets the baseline: the Core counts from
  /// its own start, not from this session.
  Future<void> _sampleNodes(_SublinkSession session) async {
    final nodes = await _readNodeTraffic();
    if (nodes == null) return;
    final keys = await _keysByName();
    for (final node in nodes) {
      final last = session.nodeTotals[node.name];
      session.nodeTotals[node.name] = (up: node.up, down: node.down);
      if (last == null) continue;
      var deltaUp = node.up - last.up;
      var deltaDown = node.down - last.down;
      if (deltaUp < 0 || deltaDown < 0) {
        // The Core restarted and its counters with it.
        deltaUp = max(0, node.up);
        deltaDown = max(0, node.down);
      }
      if (deltaUp + deltaDown <= 0) continue;
      final key = keys[node.name];
      if (key == null || key.isEmpty) continue;
      final pending = session.nodePending[key] ?? (up: 0, down: 0);
      session.nodePending[key] = (
        up: pending.up + deltaUp,
        down: pending.down + deltaDown,
      );
    }
  }

  Future<void> _tickNodes(_SublinkSession session) async {
    if (session.nodesInterval <= 0) return;
    await _sampleNodes(session);
    await _sendNodes(session);
  }

  Future<void> _sendNodes(_SublinkSession session) async {
    if (session.nodePending.isEmpty || session.sendingNodes) return;
    session.sendingNodes = true;
    try {
      final id = await installId;
      final rows = session.nodePending.entries.toList()
        ..sort((a, b) {
          final totalA = a.value.up + a.value.down;
          final totalB = b.value.up + b.value.down;
          if (totalA != totalB) return totalB.compareTo(totalA);
          return a.key.compareTo(b.key);
        });
      final sent = rows.take(_maxNodeRows).toList();
      final response = await _dio.postUri<Object?>(
        session.link.nodesUri.replace(
          queryParameters: {'token': session.link.token},
        ),
        data: {
          'report_id': '$id:${session.id}:n${session.nodeSeq}',
          'session_id': session.id,
          'install_id': id,
          'window_seconds': session.nodesInterval,
          'nodes': [
            for (final row in sent)
              {'key': row.key, 'up': row.value.up, 'down': row.value.down},
          ],
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
          'sublink nodes rejected: $code',
          logLevel: LogLevel.warning,
        );
        return;
      }
      for (final row in sent) {
        session.nodePending.remove(row.key);
      }
      session.nodeSeq += 1;
    } catch (error) {
      commonPrint.log(
        'sublink nodes error: $error',
        logLevel: LogLevel.warning,
      );
    } finally {
      session.sendingNodes = false;
    }
  }

  Future<Map<String, String>> _loadProblems(String token) async {
    final store = await _store;
    final raw = store.getString(_key(token, 'problems'));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _saveProblems(String token, Map<String, String> problems) async {
    final store = await _store;
    await store.setString(_key(token, 'problems'), jsonEncode(problems));
  }

  /// Reports the nodes this device does not trust and, once, every node that
  /// was on the previous report and has recovered since.
  Future<void> _tickReliability(_SublinkSession session) async {
    final snapshot = await _readReputation();
    if (snapshot == null) return;
    final silent = await _readSilent();
    final keys = await _keysByName();
    final byName = {for (final entry in snapshot) entry.name: entry};
    final problems = <String, Map<String, Object?>>{};
    final names = <String, String>{};
    for (final entry in snapshot) {
      final key = keys[entry.name];
      if (key == null || key.isEmpty) continue;
      final isSilent = silent.contains(entry.name);
      final isProblem =
          entry.score < _trustedScore || entry.fails > 0 || isSilent;
      if (!isProblem) continue;
      problems[key] = {
        'key': key,
        'score': entry.score,
        'fails': entry.fails,
        'streak': entry.streak,
        'silent': isSilent,
        'last_seen': entry.lastSeen?.toUtc().toIso8601String(),
      };
      names[key] = entry.name;
    }
    for (final name in silent) {
      final key = keys[name];
      if (key == null || key.isEmpty || problems.containsKey(key)) continue;
      problems[key] = {
        'key': key,
        'score': 0,
        'fails': 0,
        'streak': 0,
        'silent': true,
        'last_seen': null,
      };
      names[key] = name;
    }
    final previous = await _loadProblems(session.link.token);
    final recovered = <Map<String, Object?>>[];
    for (final entry in previous.entries) {
      if (problems.containsKey(entry.key)) continue;
      final current = byName[entry.value];
      recovered.add({
        'key': entry.key,
        'score': current?.score ?? _trustedScore,
        'fails': current?.fails ?? 0,
        'streak': current?.streak ?? 0,
        'silent': false,
        'last_seen': current?.lastSeen?.toUtc().toIso8601String(),
        'recovered': true,
      });
    }
    if (problems.isEmpty && recovered.isEmpty) {
      if (previous.isNotEmpty) {
        await _saveProblems(session.link.token, const {});
      }
      return;
    }
    final ranked = problems.values.toList()
      ..sort((a, b) {
        final scoreA = a['score'] as int? ?? 0;
        final scoreB = b['score'] as int? ?? 0;
        if (scoreA != scoreB) return scoreA.compareTo(scoreB);
        return ('${a['key']}').compareTo('${b['key']}');
      });
    final rows = [...ranked.take(_maxReliabilityRows), ...recovered];
    try {
      final id = await installId;
      final response = await _dio.postUri<Object?>(
        session.link.reliabilityUri.replace(
          queryParameters: {'token': session.link.token},
        ),
        data: {
          'report_id': '$id:${session.id}:r${session.reliabilitySeq}',
          'install_id': id,
          'reported_at': DateTime.now().toUtc().toIso8601String(),
          'nodes': rows,
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
          'sublink reliability rejected: $code',
          logLevel: LogLevel.warning,
        );
        return;
      }
      session.reliabilitySeq += 1;
      await _saveProblems(session.link.token, names);
    } catch (error) {
      commonPrint.log(
        'sublink reliability error: $error',
        logLevel: LogLevel.warning,
      );
    }
  }

  // --- test seams ---------------------------------------------------------

  /// The traffic a test feeds the sampler instead of the Core's counters.
  @visibleForTesting
  ({int up, int down}) Function()? debugTraffic;

  @visibleForTesting
  List<NodeTraffic> Function()? debugNodeTraffic;

  @visibleForTesting
  List<NodeReputation> Function()? debugReputation;

  @visibleForTesting
  Set<String> Function()? debugSilentNodes;

  @visibleForTesting
  Future<Map<String, String>> Function()? debugNodeKeys;

  @visibleForTesting
  List<Map<String, Object?>> get debugEvents => [
    for (final event in _events) event.toJson(),
  ];

  @visibleForTesting
  Dio get debugDio => _dio;

  @visibleForTesting
  int get debugPendingBytes =>
      (_session?.pendingUp ?? 0) + (_session?.pendingDown ?? 0);

  @visibleForTesting
  int get debugTotal => _session?.total ?? 0;

  @visibleForTesting
  bool get debugActive => _session != null;

  /// The callback `attach` would have wired, for a test without a Core.
  @visibleForTesting
  set debugOnBlocked(Future<void> Function(String url)? callback) =>
      _onBlocked = callback;

  /// The profile URL `attach` would have wired, for a test without a Core.
  @visibleForTesting
  set debugActiveUrl(String? Function()? read) => _activeUrl = read;

  @visibleForTesting
  Future<void> debugStart(String url) async {
    final link = parseSublinkLink(url);
    if (link == null) return;
    await _startSession(link, null);
  }

  @visibleForTesting
  Future<void> debugStartWithStatus(String url, SublinkStatus status) async {
    final link = parseSublinkLink(url);
    if (link == null) return;
    await _startSession(link, status);
  }

  @visibleForTesting
  Future<void> debugTick() async {
    final session = _session;
    if (session == null) return;
    await _tick(session);
  }

  @visibleForTesting
  Future<void> debugFlushEvents() => _flushEvents();

  @visibleForTesting
  Future<void> debugTickNodes() async {
    final session = _session;
    if (session == null) return;
    await _tickNodes(session);
  }

  @visibleForTesting
  Future<void> debugTickReliability() async {
    final session = _session;
    if (session == null) return;
    await _tickReliability(session);
  }

  @visibleForTesting
  Future<void> debugReset() async {
    await stopSession();
    _prefs = null;
    _installId = null;
    _deviceName = null;
    _secrets.clear();
    _onBlocked = null;
    _activeUrl = null;
    debugTraffic = null;
    debugNodeTraffic = null;
    debugReputation = null;
    debugSilentNodes = null;
    debugNodeKeys = null;
    _nodeKeys = null;
    _keysByNameCache = null;
    _keysByNameAt = null;
    _intervals.clear();
    _events.clear();
    _eventsLoaded = false;
    _flushingFuture = null;
    statuses.value = {};
    runtime.value = SublinkRuntime.idle;
  }

  // --- parsing helpers ----------------------------------------------------

  static Map<String, Object?> _map(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return {for (final entry in value.entries) '${entry.key}': entry.value};
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
