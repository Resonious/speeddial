import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Sets the touch slop for drag recognizers built in [child], keeping the
/// rest of the inherited [MediaQueryData]. A null [slop] means the
/// framework default.
///
/// Competing recognizers resolve by whichever crosses its slop first, so a
/// larger slop makes a gesture yield to its neighbours.
class TouchSlop extends StatelessWidget {
  const TouchSlop({super.key, required this.slop, required this.child});

  final double? slop;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(gestureSettings: DeviceGestureSettings(touchSlop: slop)),
    child: child,
  );
}
