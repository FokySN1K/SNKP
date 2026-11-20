import 'package:fl_clash/common/context.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

const proxyGridSpacing = 8.0;

/// Why the group does not route through the pin, in words a user reads. A
/// reason the Core reports but this build has no words for is shown as it is.
String pinSkipReason(BuildContext context, Group group) {
  final appLocalizations = context.appLocalizations;
  return switch (group.nowReason) {
    'fixed-unavailable' => appLocalizations.pinSkippedUnavailable,
    'fixed-suspicious' => appLocalizations.pinSkippedSuspicious,
    final reason? => reason,
    null => appLocalizations.pinSkippedUnavailable,
  };
}

/// Whether a pool routes through a member, and how many of its members can
/// carry traffic now: a check or a cross beside the share.
class PoolRotationValue extends StatelessWidget {
  const PoolRotationValue({
    super.key,
    required this.inPool,
    required this.alive,
    required this.size,
  });

  final bool inPool;
  final int alive;
  final int size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        GlyphIcon(
          inPool ? AppGlyphs.check : AppGlyphs.close,
          size: 16,
          color: inPool ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        Text('$alive / $size'),
      ],
    );
  }
}

double get listHeaderHeight {
  final measure = globalState.measure;
  return 20 +
      measure.textHeight(AppTextStyle.callout) +
      2 +
      measure.textHeight(AppTextStyle.caption1) +
      2;
}

double getItemHeight(ProxyCardType proxyCardType) {
  final measure = globalState.measure;
  final baseHeight =
      16 +
      measure.textHeight(AppTextStyle.subheadline) * 2 +
      measure.textHeight(AppTextStyle.footnote) +
      8 +
      4;
  return switch (proxyCardType) {
    ProxyCardType.loose =>
      baseHeight + measure.textHeight(AppTextStyle.caption2) + 6,
    ProxyCardType.standard => baseHeight,
    ProxyCardType.compact =>
      baseHeight - measure.textHeight(AppTextStyle.subheadline),
  };
}

double getRowExtent(ProxyCardType proxyCardType) =>
    getItemHeight(proxyCardType) + proxyGridSpacing;

class GroupOffsets {
  const GroupOffsets(this.groups, this.offsets);

  static const empty = GroupOffsets(<Group>[], <double>[]);

  final List<Group> groups;
  final List<double> offsets;

  bool get isEmpty => offsets.isEmpty;

  double offsetOf(String groupName) {
    final index = groups.indexWhere((group) => group.name == groupName);
    if (index < 0 || index >= offsets.length) {
      return 0;
    }
    return offsets[index];
  }
}

double? selectedRowOffset({
  required List<Proxy> proxies,
  required String? selectedProxyName,
  required int columns,
  required double rowExtent,
}) {
  final index = proxies.indexWhere((proxy) => proxy.name == selectedProxyName);
  if (index < 0) {
    return null;
  }
  return (index ~/ columns) * rowExtent;
}

void animateScrollTo(ScrollController controller, double offset) {
  if (!controller.hasClients) {
    return;
  }
  final position = controller.position;
  controller.animateTo(
    offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );
}
