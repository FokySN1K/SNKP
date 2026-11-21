import 'package:fl_clash/ui/line_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _color = Color(0xFF3366FF);
const _secondaryColor = Color(0xFF00AA55);
const _failureColor = Color(0xFFCC0000);

final _canvas = find.descendant(
  of: find.byType(LineChart),
  matching: find.byType(CustomPaint),
);

Widget _chart(
  List<double?> values, {
  required int revision,
  double baselineRatio = 1,
  List<double?>? secondary,
  Color? secondaryColor,
  Color? failureColor,
}) {
  return Center(
    child: SizedBox(
      width: 290,
      height: 100,
      child: LineChart(
        values: values,
        secondary: secondary,
        revision: revision,
        capacity: 30,
        minScale: 1,
        color: _color,
        secondaryColor: secondaryColor,
        failureColor: failureColor,
        baselineRatio: baselineRatio,
      ),
    ),
  );
}

Rect _lineBounds(WidgetTester tester) {
  late Rect bounds;
  expect(
    tester.renderObject(_canvas),
    paints..something((method, arguments) {
      if (method != #drawPath ||
          (arguments[1] as Paint).style != PaintingStyle.stroke) {
        return false;
      }
      bounds = (arguments[0] as Path).getBounds();
      return true;
    }),
  );
  return bounds;
}

void main() {
  testWidgets('a new sample redraws the chart and leaves nothing animating', (
    tester,
  ) async {
    await tester.pumpWidget(_chart(const [1, 2, 3], revision: 3));
    await tester.pumpWidget(_chart(const [1, 2, 3, 40], revision: 4));

    expect(
      tester.hasRunningAnimations,
      isFalse,
      reason: 'an animation here repaints the whole window on every vsync',
    );
    expect(
      tester.renderObject(_canvas),
      paints
        ..path(style: PaintingStyle.fill)
        ..path(color: _color, style: PaintingStyle.stroke),
    );
  });

  testWidgets('a spike stays below the top', (tester) async {
    final idle = List.filled(20, 0.0);
    await tester.pumpWidget(_chart([...idle, 10], revision: 21));
    expect(_lineBounds(tester).top, greaterThan(0));

    await tester.pumpWidget(_chart([...idle, 10, 0], revision: 22));
    expect(_lineBounds(tester).top, greaterThan(0));
  });

  testWidgets('an idle chart lies on its baseline', (tester) async {
    await tester.pumpWidget(
      _chart(List.filled(10, 0.0), revision: 10, baselineRatio: 0.9),
    );

    expect(_lineBounds(tester).top, closeTo(90, 0.01));
  });

  testWidgets('a clear starts the chart over', (tester) async {
    await tester.pumpWidget(_chart(const [1, 2, 3], revision: 3));
    expect(_lineBounds(tester).height, greaterThan(0));

    await tester.pumpWidget(_chart(const [], revision: 0));
    expect(
      tester.renderObject(_canvas),
      isNot(paints..path(style: PaintingStyle.stroke)),
    );
  });

  testWidgets('a failed check breaks the line and marks the baseline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chart([10, 12, null, 8, 9], revision: 5, failureColor: _failureColor),
    );

    expect(
      tester.renderObject(_canvas),
      paints
        ..path(style: PaintingStyle.fill)
        ..path(color: _color, style: PaintingStyle.stroke)
        ..path(style: PaintingStyle.fill)
        ..path(color: _color, style: PaintingStyle.stroke)
        ..circle(color: _failureColor),
    );
  });

  testWidgets('a second series is dashed over the first', (tester) async {
    await tester.pumpWidget(
      _chart(
        [10, 11, 12, 13],
        revision: 4,
        secondary: [4, 4, 5, 5],
        secondaryColor: _secondaryColor,
      ),
    );

    final dashes = <Rect>[];
    expect(
      tester.renderObject(_canvas),
      // An "everything" step, unlike "something", keeps calling the predicate
      // after the first hit, so every dash is counted. Paint.color
      // round-trips through float32, so colours are compared in 8-bit space.
      paints..everything((method, arguments) {
        if (method == #drawPath &&
            (arguments[1] as Paint).color.toARGB32() ==
                _secondaryColor.toARGB32()) {
          dashes.add((arguments[0] as Path).getBounds());
        }
        return true;
      }),
    );
    expect(
      dashes.length,
      greaterThan(1),
      reason: 'the overlay is drawn as dashes, not one solid stroke',
    );
    expect(
      dashes.every((bounds) => bounds.top >= 0 && bounds.bottom <= 100.01),
      isTrue,
      reason: 'the overlay shares the scale of the primary series',
    );
  });
}
