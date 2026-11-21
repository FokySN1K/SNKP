import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/proxy_details.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// How a node has been behaving: the verdict of its last check for the
/// group's target, the checks before it, and the transports it offers.
class ProxyHealthSection extends ConsumerWidget {
  const ProxyHealthSection({
    super.key,
    required this.proxy,
    required this.groupName,
    this.testUrl,
  });

  final Proxy proxy;
  final String groupName;
  final String? testUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final details = ref
        .watch(proxyDetailsProvider(proxyName: proxy.name, testUrl: testUrl))
        .value;
    final history = details?.history ?? const <DelaySample>[];
    final transports = details?.transports ?? const <String>[];
    final last = details?.last;
    final alive = last != null && last.delay > 0 && (details?.alive ?? false);
    return generateSection(
      title: appLocalizations.healthCheck,
      items: [
        DetailRow(
          title: appLocalizations.status,
          value: last == null
              ? Text(appLocalizations.noInfo)
              : Text(
                  alive
                      ? appLocalizations.serviceAvailable
                      : appLocalizations.serviceUnavailable,
                  style: TextStyle(
                    color: alive
                        ? context.colorScheme.success
                        : context.colorScheme.error,
                  ),
                ),
        ),
        _DelayHistoryRow(
          proxy: proxy,
          groupName: groupName,
          testUrl: testUrl,
          history: history,
        ),
        // The full delay decides which node the pool picks; RTT explains
        // where that delay comes from, so an interactive user can tell a
        // close node from a fast server.
        if (last != null && last.rtt > 0)
          DetailRow(
            title: appLocalizations.rtt,
            value: Text(
              '${last.rtt} ms',
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
        if (last != null)
          DetailRow(
            title: appLocalizations.lastUpdated,
            value: LastUpdateTimeText(
              lastUpdateDate: last.checkedAt,
              compact: true,
            ),
          ),
        if (transports.isNotEmpty)
          DetailRow(
            title: appLocalizations.transport,
            value: Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                for (final transport in transports) MetaChip(label: transport),
              ],
            ),
          ),
      ],
    );
  }
}

/// The delay of the last check with the checks before it as a sparkline, and
/// the test that starts another one.
class _DelayHistoryRow extends ConsumerWidget {
  const _DelayHistoryRow({
    required this.proxy,
    required this.groupName,
    required this.testUrl,
    required this.history,
  });

  final Proxy proxy;
  final String groupName;
  final String? testUrl;
  final List<DelaySample> history;

  void _test(WidgetRef ref) {
    ref.read(proxiesActionProvider.notifier).proxyDelayTest(proxy, testUrl);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final testing =
        ref.watch(
          delayTestPhaseProvider(
            proxyName: proxy.name,
            testUrl: testUrl,
            groupName: groupName,
          ),
        ) !=
        null;
    final shown = delay ?? (history.isEmpty ? null : history.last.delay);
    final colorScheme = context.colorScheme;
    final lastDelay = _lastMeasuredDelay(history);
    return DetailRow(
      title: appLocalizations.delay,
      value: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          if (testing)
            const CommonCircleLoading(size: 14)
          else if (shown == null)
            Text(appLocalizations.noInfo)
          else
            Text(
              shown > 0
                  ? '$shown ms'
                  : delayFailureText(shown, appLocalizations),
              style: TextStyle(color: context.colorScheme.delayColor(shown)),
            ),
          if (history.length > 1) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 88,
              height: 24,
              child: LineChart(
                values: [
                  for (final sample in history)
                    sample.delay > 0 ? sample.delay.toDouble() : null,
                ],
                secondary: history.any((sample) => sample.rtt > 0)
                    ? [
                        for (final sample in history)
                          sample.rtt > 0 ? sample.rtt.toDouble() : null,
                      ]
                    : null,
                revision: history.last.time,
                capacity: math.max(history.length, 10),
                minScale: 200,
                color: lastDelay == null
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.delayColor(lastDelay) ??
                          colorScheme.onSurfaceVariant,
                secondaryColor: colorScheme.onSurfaceVariant,
                failureColor: colorScheme.error,
                baselineRatio: 0.9,
              ),
            ),
          ],
          IconButton(
            tooltip: appLocalizations.delayTest,
            onPressed: () => _test(ref),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const GlyphIcon(AppGlyphs.bolt),
          ),
        ],
      ),
    );
  }
}

/// The delay of the last check that measured one: a run of failures keeps the
/// chart the colour of the traffic it broke away from.
int? _lastMeasuredDelay(List<DelaySample> history) {
  for (final sample in history.reversed) {
    if (sample.delay > 0) {
      return sample.delay;
    }
  }
  return null;
}
