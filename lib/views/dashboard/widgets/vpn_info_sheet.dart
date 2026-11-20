import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/features/ip_quality/labels.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/ip_quality.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/route_targets.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/proxies/common.dart' show PoolRotationValue;
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'route_map.dart';

/// What the VPN card stands for: whether the tunnel is up, the profile behind
/// it, the address its traffic leaves by and the takeover it shares a screen
/// with.
Future<void> showVpnInfoSheet(BuildContext context) {
  if (isSheetPage(context)) {
    return Navigator.of(
      context,
    ).push(PagedSheetRoute(builder: (_) => const _VpnInfoSheet()));
  }
  return showSheet<void>(
    context: context,
    builder: (_) => const _VpnInfoSheet(),
  );
}

class _VpnInfoSheet extends ConsumerWidget {
  const _VpnInfoSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final enabled = ref.watch(
      vpnSettingProvider.select((state) => state.enable),
    );
    final profile = ref.watch(currentProfileProvider);
    final tun = ref.watch(
      patchClashConfigProvider.select((state) => state.tun.enable),
    );
    final systemProxy = ref.watch(
      networkSettingProvider.select((state) => state.systemProxy),
    );
    final mixedPort = ref.watch(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    final ip = ref.watch(
      outboundIpProbeProvider.select(
        (state) => state.entryOf(routedOutbound).value?.ip,
      ),
    );
    final exit = ref.watch(
      outboundIpProbeProvider.select(
        (state) => state.entryOf(routedOutbound).stamp?.hits.exitInfo,
      ),
    );
    return CommonScaffold(
      title: 'VPN',
      body: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          bottom: 20 + context.bottomInset,
          top: context.contentTopPadding,
        ),
        children: [
          generateSection(
            items: [
              DetailRow(
                title: appLocalizations.status,
                value: Text(
                  enabled
                      ? appLocalizations.enabled
                      : appLocalizations.disabled,
                ),
              ),
              if (profile != null)
                DetailRow(
                  title: appLocalizations.profile,
                  copyText: profile.realLabel,
                  value: EmojiText(profile.realLabel),
                ),
            ],
          ),
          const RoutedConnectionSection(),
          if (exit case final exit?) _ExitGroupSection(exit: exit),
          const RouteMapSection(),
          generateSection(
            title: appLocalizations.network,
            items: [
              const OutboundIpRow(target: routedOutbound),
              if (ip case final ip?) _IpQualityRow(ip: ip),
              DetailRow(
                title: appLocalizations.tun,
                value: Text(
                  tun ? appLocalizations.enabled : appLocalizations.disabled,
                ),
              ),
              DetailRow(
                title: appLocalizations.systemProxy,
                value: Text(
                  systemProxy
                      ? appLocalizations.portValue(mixedPort)
                      : appLocalizations.disabled,
                ),
              ),
              DetailRow(
                title: appLocalizations.mixedPort,
                copyText: '$mixedPort',
                value: Text('$mixedPort'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The quality of the exit's address, with the whole sheet a tap away: the
/// sheet names the sources a lookup tried, which a row has no room for.
class _IpQualityRow extends ConsumerWidget {
  const _IpQualityRow({required this.ip});

  final String ip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final quality = ref.watch(ipQualityProvider(ip)).value;
    final colorScheme = Theme.of(context).colorScheme;
    final summary = quality == null
        ? appLocalizations.noInfo
        : '${quality.type.label(context)} · ${quality.level.label(context)}';
    return DecorationListItem(
      onPressed: () => showIpQualitySheet(context, ip: ip),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 20,
        children: [
          Text(appLocalizations.ipQualityShort),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Text(
                summary,
                style: AppTextStyle.subheadline
                    .of(context)
                    .copyWith(
                      color:
                          quality?.level.color(context) ??
                          colorScheme.onSurfaceVariant,
                    ),
              ),
              GlyphIcon(
                AppGlyphs.info,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The group the exit comes through and what its pool holds: the same picks a
/// node's own sheet shows, read off the node the tunnel names rather than off
/// a card the user happened to open.
class _ExitGroupSection extends ConsumerWidget {
  const _ExitGroupSection({required this.exit});

  final RouteExit exit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final groups = ref.watch(groupsProvider);
    final targets =
        ref.watch(routeTargetsProvider).value ?? const <RouteTarget>[];
    final group = _exitGroup(groups, targets, exit.name);
    if (group == null) {
      return const SizedBox.shrink();
    }
    final suspicious = group.isSuspicious(exit.name);
    final silent = group.isDataSilent(exit.name);
    return generateSection(
      title: appLocalizations.groupState,
      items: [
        DetailRow(
          title: appLocalizations.proxyGroup,
          copyText: group.name,
          value: EmojiText(group.name),
        ),
        if (group.poolSize case final size?)
          DetailRow(
            title: appLocalizations.poolRotation,
            value: PoolRotationValue(
              inPool: group.pool.contains(exit.name),
              alive: group.aliveInPool,
              size: size,
            ),
          ),
        if (suspicious || silent)
          DetailRow(
            title: appLocalizations.status,
            value: Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                if (suspicious)
                  MetaChip(label: appLocalizations.suspiciousNode),
                if (silent) MetaChip(label: appLocalizations.dataSilentNode),
              ],
            ),
          ),
      ],
    );
  }
}

/// The group that routes through [name] now: one of the outbounds the rules
/// name first, then any other group whose selection is [name].
Group? _exitGroup(List<Group> groups, List<RouteTarget> targets, String name) {
  for (final target in targets) {
    final group = groups.getGroup(target.name);
    if (group != null && group.realNow == name) {
      return group;
    }
  }
  for (final group in groups) {
    if (group.realNow == name) {
      return group;
    }
  }
  return null;
}
