import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// A sparkline of one or two series drawn against a shared scale.
///
/// A null sample is a check that measured nothing: a series breaks its line
/// there, and the primary one leaves a dot on the baseline, so a failed check
/// never reads as the fastest point.
class LineChart extends StatefulWidget {
  const LineChart({
    super.key,
    required this.values,
    this.secondary,
    required this.revision,
    required this.capacity,
    required this.minScale,
    required this.color,
    this.secondaryColor,
    this.failureColor,
    required this.baselineRatio,
  }) : assert(capacity > 1),
       assert(minScale > 0),
       assert(secondary == null || secondary.length == values.length);

  /// The primary samples, a null standing for a check that measured nothing.
  final List<double?> values;

  /// A second series laid over the first, dashed and sharing its scale.
  final List<double?>? secondary;

  /// Advances by one for each sample appended to the series. Any other change,
  /// such as a clear, starts the chart over.
  final int revision;

  final int capacity;

  /// The least value the top stands for, so idle noise stays near the baseline.
  final double minScale;

  final Color color;

  /// The colour of [secondary]; a lighter weight of [color] by default.
  final Color? secondaryColor;

  /// The mark a null sample of [values] leaves on the baseline.
  final Color? failureColor;

  /// Where the zero line sits, as a share of the height from the top.
  final double baselineRatio;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  late _Series _series;
  _Series? _secondary;

  int get _seriesLength => widget.capacity + _Series.radius + 1;

  @override
  void initState() {
    super.initState();
    _series = _Series.of(widget.values, _seriesLength);
    _secondary = _seriesOf(widget.secondary);
  }

  _Series? _seriesOf(List<double?>? values) =>
      values == null ? null : _Series.of(values, _seriesLength);

  @override
  void didUpdateWidget(LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final appended = widget.revision - oldWidget.revision;
    if (widget.capacity != oldWidget.capacity ||
        (widget.secondary == null) != (oldWidget.secondary == null) ||
        appended < 0 ||
        appended > widget.values.length) {
      _series = _Series.of(widget.values, _seriesLength);
      _secondary = _seriesOf(widget.secondary);
      return;
    }
    if (appended == 0) {
      return;
    }
    _series = _series.append(
      widget.values.sublist(widget.values.length - appended),
    );
    final secondary = widget.secondary;
    final shown = _secondary;
    if (secondary != null && shown != null) {
      _secondary = shown.append(secondary.sublist(secondary.length - appended));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _LineChartPainter(
            series: _series,
            secondary: _secondary,
            capacity: widget.capacity,
            minScale: widget.minScale,
            color: widget.color,
            secondaryColor: widget.secondaryColor,
            failureColor: widget.failureColor,
            baselineRatio: widget.baselineRatio,
          ),
        ),
      ),
    );
  }
}

/// A fixed-length window of samples, its blurred heights, and where the
/// padding that keeps the window long ends.
@immutable
class _Series {
  _Series._(this.samples, this.start) : heights = _blur(samples);

  factory _Series.of(List<double?> window, int length) {
    final count = math.min(window.length, length);
    return _Series._(
      List<double?>.filled(length, null)
        ..setAll(length - count, window.sublist(window.length - count)),
      length - count,
    );
  }

  static const _sigma = 1.5;
  static final radius = (_sigma * 2.5).ceil();
  static final _kernel = [
    for (var d = 0; d <= radius; d++) math.exp(-d * d / (2 * _sigma * _sigma)),
  ];

  final List<double?> samples;

  /// The first sample that came from the window rather than from the padding,
  /// which is null and would otherwise pass for a failed check.
  final int start;

  /// The blurred height of each sample; null for a failed check and where
  /// no measured sample is near.
  final List<double?> heights;

  _Series append(List<double?> appended) {
    final next = [...samples, ...appended];
    return _Series._(
      next.sublist(next.length - samples.length),
      math.max(0, start - appended.length),
    );
  }

  /// The longest height in the window, zero when it measured nothing.
  double get top {
    var top = 0.0;
    for (final height in heights) {
      if (height != null && height > top) {
        top = height;
      }
    }
    return top;
  }

  /// The [heights] split into runs of measured samples, each keeping the index
  /// its sample had in the window, so the line breaks where a check failed.
  Iterable<List<({int index, double height})>> get runs sync* {
    List<({int index, double height})>? run;
    for (var i = 0; i < heights.length; i++) {
      final height = heights[i];
      if (height == null) {
        if (run != null) {
          yield run;
          run = null;
        }
      } else {
        (run ??= <({int index, double height})>[]).add((
          index: i,
          height: height,
        ));
      }
    }
    if (run != null) {
      yield run;
    }
  }

  static List<double?> _blur(List<double?> samples) {
    return [for (var i = 0; i < samples.length; i++) _blurAt(samples, i)];
  }

  static double? _blurAt(List<double?> samples, int i) {
    if (samples[i] == null) {
      return null;
    }
    var sum = 0.0;
    var weight = 0.0;
    final from = math.max(i - radius, 0);
    final to = math.min(i + radius, samples.length - 1);
    for (var j = from; j <= to; j++) {
      final value = samples[j];
      if (value == null) {
        continue;
      }
      final w = _kernel[(j - i).abs()];
      sum += w * value;
      weight += w;
    }
    return weight == 0 ? null : sum / weight;
  }

  /// Catmull-Rom slopes, clamped so no control point and no curve dips below 0.
  static List<double> slopesOf(List<double> values) {
    final last = values.length - 1;
    return [
      for (var i = 0; i <= last; i++)
        i == 0 || i == last
            ? 0.0
            : ((values[i + 1] - values[i - 1]) / 2).clamp(
                -3 * values[i],
                3 * values[i],
              ),
    ];
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.series,
    required this.secondary,
    required this.capacity,
    required this.minScale,
    required this.color,
    required this.secondaryColor,
    required this.failureColor,
    required this.baselineRatio,
  }) : _strokePaint = Paint()
         ..color = color
         ..strokeWidth = _strokeWidth
         ..strokeCap = StrokeCap.round
         ..strokeJoin = StrokeJoin.round
         ..style = PaintingStyle.stroke,
       _secondaryPaint = Paint()
         ..color = secondaryColor ?? color.withValues(alpha: color.a * 0.55)
         ..strokeWidth = _secondaryStrokeWidth
         ..strokeCap = StrokeCap.round
         ..strokeJoin = StrokeJoin.round
         ..style = PaintingStyle.stroke;

  static const _strokeWidth = 2.0;
  static const _secondaryStrokeWidth = 1.4;
  static const _dash = 3.5;
  static const _dashGap = 2.5;
  static const _markRadius = 1.6;
  static const _fillOpacity = 0.14;

  final _Series series;
  final _Series? secondary;
  final int capacity;
  final double minScale;
  final Color color;
  final Color? secondaryColor;
  final Color? failureColor;
  final double baselineRatio;

  final Paint _strokePaint;
  final Paint _secondaryPaint;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / (capacity - 1);
    final baseline = size.height * baselineRatio;
    final firstX = size.width - (series.heights.length - 1) * step;
    final overlay = secondary;
    var top = minScale;
    for (final run in series.runs) {
      top = math.max(top, -_curve(run, firstX, step).getBounds().top);
    }
    if (overlay != null) {
      for (final run in overlay.runs) {
        top = math.max(top, -_curve(run, firstX, step).getBounds().top);
      }
    }
    final yScale = (baseline - _strokeWidth) / top;
    final matrix =
        (Matrix4.identity()
              ..translateByDouble(0, baseline, 0, 1)
              ..scaleByDouble(1, yScale, 1, 1))
            .storage;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: color.a * _fillOpacity);
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    for (final run in series.runs) {
      final line = _curve(run, firstX, step).transform(matrix);
      if (run.length > 1) {
        final area = Path.from(line)
          ..lineTo(firstX + run.last.index * step, size.height)
          ..lineTo(firstX + run.first.index * step, size.height)
          ..close();
        canvas.drawPath(area, fillPaint);
      }
      canvas.drawPath(line, _strokePaint);
    }
    if (overlay != null) {
      for (final run in overlay.runs) {
        _drawDashed(
          canvas,
          _curve(run, firstX, step).transform(matrix),
          _secondaryPaint,
        );
      }
    }
    final failureColor = this.failureColor;
    if (failureColor != null) {
      final markPaint = Paint()..color = failureColor;
      for (var i = series.start; i < series.samples.length; i++) {
        if (series.samples[i] != null) {
          continue;
        }
        canvas.drawCircle(
          Offset(firstX + i * step, baseline),
          _markRadius,
          markPaint,
        );
      }
    }
    canvas.restore();
  }

  /// [run] as a Catmull-Rom curve through its samples, drawn in height space:
  /// the y axis runs up, and the painter scales it onto the canvas at once.
  Path _curve(
    List<({int index, double height})> run,
    double firstX,
    double step,
  ) {
    final path = Path();
    final first = run.first;
    var x = firstX + first.index * step;
    var y = -first.height;
    path.moveTo(x, y);
    final slopes = _Series.slopesOf([for (final point in run) point.height]);
    for (var i = 1; i < run.length; i++) {
      final nextX = firstX + run[i].index * step;
      final nextY = -run[i].height;
      path.cubicTo(
        x + step / 3,
        y - slopes[i - 1] / 3,
        nextX - step / 3,
        nextY + slopes[i] / 3,
        nextX,
        nextY,
      );
      x = nextX;
      y = nextY;
    }
    return path;
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + _dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.secondary != secondary ||
        oldDelegate.capacity != capacity ||
        oldDelegate.minScale != minScale ||
        oldDelegate.color != color ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.failureColor != failureColor ||
        oldDelegate.baselineRatio != baselineRatio;
  }
}
