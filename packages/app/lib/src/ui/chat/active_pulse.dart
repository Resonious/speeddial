import 'package:flutter/material.dart';

class ActivePulse extends StatefulWidget {
  const ActivePulse({
    super.key,
    required this.active,
    required this.child,
    this.pulseKey,
  });

  final bool active;
  final Widget child;
  final Key? pulseKey;

  @override
  State<ActivePulse> createState() => _ActivePulseState();
}

class _ActivePulseState extends State<ActivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(ActivePulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && oldWidget.active) {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return widget.child;
    }
    return FadeTransition(
      key: widget.pulseKey,
      opacity: _opacity,
      child: widget.child,
    );
  }
}
