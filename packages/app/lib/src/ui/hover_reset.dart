import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Forgets abandoned hover positions when the user switches to touch.
///
/// Some mobile devices stop reporting a mouse/stylus without sending a removal
/// event. Flutter then keeps hit-testing its last position on every frame.
class HoverReset extends StatefulWidget {
  const HoverReset({super.key, required this.child});

  final Widget child;

  @override
  State<HoverReset> createState() => _HoverResetState();
}

class _HoverResetState extends State<HoverReset> with WidgetsBindingObserver {
  final Map<int, PointerEvent> _devices = <int, PointerEvent>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
  }

  void _handlePointer(PointerEvent event) {
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.stylus) {
      if (event is PointerRemovedEvent) {
        _devices.remove(event.device);
      } else if (event is! PointerSignalEvent) {
        _devices[event.device] = event;
      }
    } else if (event is PointerDownEvent &&
        event.kind == PointerDeviceKind.touch) {
      _clearHover();
    }
  }

  void _clearHover() {
    final List<PointerEvent> hovering = _devices.values
        .where((PointerEvent event) => !event.down)
        .toList();
    for (final PointerEvent event in hovering) {
      _devices.remove(event.device);
      // Update only hover tracking, not the pointer/gesture stream. This emits
      // normal exits and cancels pending tooltip timers. The next real pointer
      // event registers the device again, even without a new added event.
      RendererBinding.instance.mouseTracker.updateWithEvent(
        PointerRemovedEvent(
          device: event.device,
          kind: event.kind,
          position: event.position,
          viewId: event.viewId,
        ),
        null,
      );
    }
    Tooltip.dismissAllToolTips();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clearHover();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handlePointer);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
