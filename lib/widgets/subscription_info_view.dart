import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:material_ui/material_ui.dart';

const _expireGap = 12.0;

class SubscriptionInfoView extends StatelessWidget {
  final SubscriptionInfo? subscriptionInfo;

  const SubscriptionInfoView({super.key, this.subscriptionInfo});

  double _textWidth(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final info = subscriptionInfo;
    if (info == null || info.total == 0) {
      return const SizedBox.shrink();
    }
    final use = info.upload + info.download;
    final total = info.total;
    final remaining = (total - use).clamp(0, total).toInt();
    final progress = (use / total).clamp(0.0, 1.0).toDouble();

    final appLocalizations = context.appLocalizations;
    final expireAt = info.expire;
    final secondsLeft =
        expireAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final daysLeft = secondsLeft > 0
        ? (secondsLeft / Duration.secondsPerDay).ceil()
        : 0;
    final remainingShow = remaining.traffic.show;
    final totalShow = total.traffic.show;
    final expireShow = expireAt != 0
        ? '$daysLeft ${appLocalizations.sublinkDaysLeft}'
        : appLocalizations.infiniteTime;
    final expireDateShow = expireAt != 0
        ? DateTime.fromMillisecondsSinceEpoch(expireAt * 1000).show
        : appLocalizations.infiniteTime;
    final valueStyle = AppTextStyle.subheadline
        .of(context, emphasized: true)
        .copyWith(color: context.colorScheme.onSurfaceVariant);
    final metaStyle = AppTextStyle.footnote.of(context).toLight;
    final trafficLabel = remainingShow;
    final trafficText = Tooltip(
      message: '$remainingShow / $totalShow',
      child: Text(
        trafficLabel,
        style: valueStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final expireText = Tooltip(
      message: expireDateShow,
      child: Text(
        expireShow,
        style: metaStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final showExpire =
                _textWidth(context, trafficLabel, valueStyle) +
                    _expireGap +
                    _textWidth(context, expireShow, metaStyle) <=
                constraints.maxWidth;
            return Row(
              children: [
                Expanded(child: trafficText),
                if (showExpire) ...[
                  const SizedBox(width: _expireGap),
                  expireText,
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          minHeight: 4,
          value: progress,
          backgroundColor: context.colorScheme.primary.opacity15,
        ),
      ],
    );
  }
}

class SubscriptionInfoDetailView extends StatelessWidget {
  final SubscriptionInfo subscriptionInfo;

  const SubscriptionInfoDetailView({super.key, required this.subscriptionInfo});

  Widget _buildItem({String? label, required String value}) {
    return DecorationListItem(
      title: Text(label ?? value),
      subtitle: label == null ? null : TooltipLabel(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final used = subscriptionInfo.upload + subscriptionInfo.download;
    final remaining = (subscriptionInfo.total - used)
        .clamp(0, subscriptionInfo.total)
        .toInt();
    final expire = subscriptionInfo.expire != 0
        ? DateTime.fromMillisecondsSinceEpoch(
            subscriptionInfo.expire * 1000,
          ).show
        : appLocalizations.infiniteTime;
    return SelectionArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          generateSection(
            title: appLocalizations.trafficUsage,
            items: [
              _buildItem(
                label: appLocalizations.usedTraffic,
                value: used.traffic.show,
              ),
              _buildItem(
                label: appLocalizations.sublinkRemaining,
                value: remaining.traffic.show,
              ),
              _buildItem(
                label: appLocalizations.totalTraffic,
                value: subscriptionInfo.total.traffic.show,
              ),
            ],
          ),
          generateSection(
            title: appLocalizations.expireTime,
            items: [_buildItem(value: expire)],
          ),
        ],
      ),
    );
  }
}
