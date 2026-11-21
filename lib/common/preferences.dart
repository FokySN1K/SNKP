import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  static Preferences? _instance;
  var _store = ResolveOnce(_open);

  Future<bool> get isInit async => await _store.value != null;

  Preferences._internal();

  static Future<SharedPreferences?> _open() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  Future<void> rebind() async {
    _store = ResolveOnce(_open);
    await _store.value;
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<int> getVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('version') ?? 0;
  }

  Future<void> setVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('version', version);
  }

  Future<int> getUpgradeVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('upgradeVersion') ?? 0;
  }

  Future<void> setUpgradeVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('upgradeVersion', version);
  }

  Future<void> saveShareState(SharedState shareState) async {
    final preferences = await _store.value;
    await preferences?.setString('sharedState', json.encode(shareState));
  }

  /// The md5 of the config.yaml the Core last accepted, which is also what
  /// the Android service applies when it starts without Flutter.
  Future<String?> getAppliedConfigMd5() async {
    final preferences = await _store.value;
    return preferences?.getString(appliedConfigMd5Key);
  }

  Future<void> saveAppliedConfigMd5(String? md5) async {
    final preferences = await _store.value;
    if (md5 == null) {
      await preferences?.remove(appliedConfigMd5Key);
    } else {
      await preferences?.setString(appliedConfigMd5Key, md5);
    }
  }

  Future<Map<String, Object?>?> getConfigMap() async {
    try {
      final preferences = await _store.value;
      final configString = preferences?.getString(configKey);
      if (configString == null) return null;
      final Map<String, Object?>? configMap = json.decode(configString);
      return configMap;
    } catch (e) {
      commonPrint.log(
        'getConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, Object?>?> getClashConfigMap() async {
    try {
      final preferences = await _store.value;
      final clashConfigString = preferences?.getString(clashConfigKey);
      if (clashConfigString == null) return null;
      return json.decode(clashConfigString);
    } catch (e) {
      commonPrint.log(
        'getClashConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> clearClashConfig() async {
    try {
      final preferences = await _store.value;
      await preferences?.remove(clashConfigKey);
      return;
    } catch (e) {
      commonPrint.log(
        'clearClashConfig error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return;
    }
  }

  Future<Config?> getConfig() async {
    final configMap = await getConfigMap();
    if (configMap == null) {
      return null;
    }
    return Config.fromJson(configMap);
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await _store.value;
    return preferences?.setString(configKey, json.encode(config)) ?? false;
  }

  /// The last state of every node, by test URL: a restart that takes the
  /// Core's own history with it leaves the page with the same picture.
  Future<Map<String, Map<String, int>>> getDelays() =>
      _getMeasurements(proxyDelaysKey, 'getDelays');

  /// The road times of the last checks, by test URL and then proxy name.
  Future<Map<String, Map<String, int>>> getRtts() =>
      _getMeasurements(proxyRttsKey, 'getRtts');

  /// Writes what the cards show, a failed check included, so the next
  /// launch does not blank a node the last run had already measured.
  Future<void> saveDelays(DelayMap delays) =>
      _saveMeasurements(proxyDelaysKey, delays);

  Future<void> saveRtts(DelayMap rtts) =>
      _saveMeasurements(proxyRttsKey, rtts);

  Future<Map<String, Map<String, int>>> _getMeasurements(
    String key,
    String label,
  ) async {
    try {
      final store = await _store.value;
      final raw = store?.getString(key);
      if (raw == null) return {};
      final decoded = json.decode(raw);
      if (decoded is! Map) return {};
      final measurements = <String, Map<String, int>>{};
      for (final entry in decoded.entries) {
        final url = entry.key;
        final values = entry.value;
        if (url is! String || values is! Map) continue;
        final urlValues = <String, int>{};
        for (final value in values.entries) {
          final name = value.key;
          final measured = value.value;
          if (name is! String || measured is! int || measured == 0) continue;
          urlValues[name] = measured;
        }
        if (urlValues.isNotEmpty) {
          measurements[url] = urlValues;
        }
      }
      return measurements;
    } catch (e) {
      commonPrint.log(
        '$label error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return {};
    }
  }

  Future<void> _saveMeasurements(String key, DelayMap measurements) async {
    final store = await _store.value;
    if (store == null) return;
    final measured = <String, Map<String, int>>{};
    for (final entry in measurements.entries) {
      for (final value in entry.value.entries) {
        final measuredValue = value.value;
        if (measuredValue == null || measuredValue == 0) continue;
        (measured[entry.key] ??= {})[value.key] = measuredValue;
      }
    }
    await store.setString(key, json.encode(measured));
  }

  Future<SystemDnsRecord?> getSystemDnsRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(systemDnsRecordKey);
      if (raw == null) {
        return null;
      }
      return SystemDnsRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getSystemDnsRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveSystemDnsRecord(SystemDnsRecord record) async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.setString(
      systemDnsRecordKey,
      json.encode(record),
    );
  }

  Future<void> clearSystemDnsRecord() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.remove(systemDnsRecordKey);
  }

  Future<BootRecord?> getBootRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(bootRecordKey);
      if (raw == null) {
        return null;
      }
      return BootRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getBootRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveBootRecord(BootRecord record) async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.setString(bootRecordKey, json.encode(record));
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.clear();
  }
}

final preferences = Preferences();
