import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'common.dart';
import 'core.dart';

part 'generated/app.freezed.dart';

typedef DelayMap = Map<String, Map<String, int?>>;

/// Moves the values measured for renamed nodes to the names the same nodes
/// carry now; null when no value moves. A name already measured keeps its
/// newer value instead of being overwritten by the old one.
DelayMap? renameDelayMap(DelayMap delays, Map<String, String> renames) {
  if (renames.isEmpty || delays.isEmpty) return null;
  var changed = false;
  final next = <String, Map<String, int?>>{};
  for (final entry in delays.entries) {
    final urlDelays = <String, int?>{...entry.value};
    for (final rename in renames.entries) {
      if (!urlDelays.containsKey(rename.key)) continue;
      urlDelays.putIfAbsent(rename.value, () => urlDelays[rename.key]);
      urlDelays.remove(rename.key);
      changed = true;
    }
    next[entry.key] = urlDelays;
  }
  return changed ? next : null;
}

@Freezed(toStringOverride: false)
abstract class AppState with _$AppState {
  const factory AppState({
    @Default(false) bool isInit,
    @Default(PageLabel.dashboard) PageLabel pageLabel,
    @Default([]) List<Package> packages,
    @Default(0) int sortNum,
    required Size viewSize,
    @Default(0) double sideWidth,
    @Default({}) DelayMap delayMap,
    @Default([]) List<Group> groups,
    required Brightness brightness,
    int? runTime,
    @Default([]) List<ExternalProvider> providers,
    String? localIp,
    required FixedList<TrackerInfo> requests,
    required int version,
    required FixedList<Log> logs,
    required FixedList<Traffic> traffics,
    required Traffic totalTraffic,
    @Default(TunAuthorizationState.none)
    TunAuthorizationState authorizedTunEnable,
    @Default(false) bool loading,
    required SystemUiOverlayStyle systemUiOverlayStyle,
    @Default(CoreStatus.connecting) CoreStatus coreStatus,
  }) = _AppState;
}

extension AppStateExt on AppState {
  ViewMode get viewMode => getViewMode(viewSize.width);

  bool get isStart => runTime != null;
}
