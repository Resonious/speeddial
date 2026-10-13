import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';

/// Residual heat from recent activity, cooling completely after three hours.
/// A minute-resolution clock updates the data without an animation ticker.
class IdleSessionEmber extends StatefulWidget {
  const IdleSessionEmber({
    super.key,
    required this.lastActivityAt,
    this.dormant = false,
    this.now = DateTime.now,
  });

  final DateTime lastActivityAt;
  final bool dormant;
  final DateTime Function() now;

  @override
  State<IdleSessionEmber> createState() => _IdleSessionEmberState();
}

class _IdleSessionEmberState extends State<IdleSessionEmber>
    with WidgetsBindingObserver {
  static const Duration _coolingTime = Duration(hours: 3);
  Timer? _timer;
  double _heat = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  @override
  void didUpdateWidget(IdleSessionEmber oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(_refresh);
    } else {
      _timer?.cancel();
    }
  }

  void _refresh() {
    _timer?.cancel();
    final Duration age = widget.now().difference(widget.lastActivityAt);
    _heat = widget.dormant
        ? 0
        : (1 - age.inMilliseconds / _coolingTime.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    if (_heat > 0 && TickerMode.valuesOf(context).enabled) {
      final Duration remaining = _coolingTime - age;
      _timer = Timer(
        remaining < const Duration(minutes: 1)
            ? remaining
            : const Duration(minutes: 1),
        () => setState(_refresh),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color ember = Theme.of(context).colorScheme.primary;
    final Color hot = dark ? colors.flameCore : colors.flameTip;
    final Color warm = Color.lerp(colors.idle, ember, (_heat * 2).clamp(0, 1))!;
    final Color core = Color.lerp(warm, hot, (_heat * 2 - 1).clamp(0, 1))!;
    return Center(
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: core,
          boxShadow: _heat == 0
              ? null
              : <BoxShadow>[
                  BoxShadow(
                    color: ember.withValues(
                      alpha: (dark ? 0.65 : 0.35) * _heat,
                    ),
                    blurRadius: 7 * _heat,
                    spreadRadius: 2 * _heat,
                  ),
                ],
        ),
      ),
    );
  }
}
