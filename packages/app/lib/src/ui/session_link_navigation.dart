import 'package:flutter/widgets.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Routes chat links through the same resolver as incoming notification links.
class SessionLinkNavigation extends InheritedWidget {
  const SessionLinkNavigation({
    super.key,
    required this.open,
    required super.child,
  });

  final Future<void> Function(SessionLink link) open;

  static SessionLinkNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionLinkNavigation>();

  @override
  bool updateShouldNotify(SessionLinkNavigation oldWidget) =>
      open != oldWidget.open;
}
