import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// What one group did while the page has been reading it: where its route
/// moved, what a user pinned, and which members a pool took out of play.
Future<void> showGroupHistory(
  BuildContext context, {
  required String groupName,
}) {
  Widget build(BuildContext _) => _GroupHistorySheet(groupName: groupName);
  if (isSheetPage(context)) {
    return Navigator.of(context).push(PagedSheetRoute(builder: build));
  }
  return showSheet<void>(context: context, builder: build);
}

class _GroupHistorySheet extends ConsumerWidget {
  const _GroupHistorySheet({required this.groupName});

  final String groupName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(groupHistoryProvider);
    final events = ref
        .read(groupHistoryProvider.notifier)
        .log
        .of(groupName)
        .reversed
        .toList();
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      title: appLocalizations.groupHistory,
      body: events.isEmpty
          ? Center(
              child: Text(
                appLocalizations.groupHistoryEmpty,
                style: AppTextStyle.subheadline
                    .of(context)
                    .copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
                bottom: 20 + context.bottomInset,
                top: context.contentTopPadding,
              ),
              children: [
                generateSection(
                  items: [
                    for (final event in events)
                      DetailRow(
                        title:
                            '${event.time.showTime}  '
                            '${_label(context, event.type)}',
                        value: Text(
                          _detail(event),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  String _label(BuildContext context, GroupEventType type) {
    final appLocalizations = context.appLocalizations;
    return switch (type) {
      GroupEventType.now => appLocalizations.historyEventNow,
      GroupEventType.pin => appLocalizations.historyEventPin,
      GroupEventType.unpin => appLocalizations.historyEventUnpin,
      GroupEventType.suspicious => appLocalizations.historyEventSuspicious,
      GroupEventType.recovered => appLocalizations.historyEventRecovered,
      GroupEventType.dataSilent => appLocalizations.historyEventDataSilent,
      GroupEventType.pool => appLocalizations.historyEventPool,
    };
  }

  String _detail(GroupEvent event) {
    return switch (event.type) {
      GroupEventType.now || GroupEventType.pin || GroupEventType.pool =>
        event.from.isEmpty ? event.to : '${event.from} → ${event.to}',
      GroupEventType.unpin => event.from,
      GroupEventType.suspicious ||
      GroupEventType.recovered ||
      GroupEventType.dataSilent => event.to,
    };
  }
}
