import 'package:flutter/material.dart';

import '../scope.dart';
import '../theme.dart';

/// A spinner while the daemon is connecting, and a steady dot otherwise.
class ConnectionStatusIndicator extends StatelessWidget {
  const ConnectionStatusIndicator({
    required this.status,
    this.size = 10,
    super.key,
  });

  final ConnectionStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color color = connectionStatusColor(context, status);
    if (status == ConnectionStatus.connecting) {
      return SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(color: color, strokeWidth: 1.5),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}
