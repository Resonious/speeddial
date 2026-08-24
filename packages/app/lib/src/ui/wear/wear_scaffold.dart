import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A constraint-driven page frame for watch-sized square and round windows.
///
/// Round devices need more room at the upper corners than rectangular phone
/// layouts. The inset is derived from the allocated width rather than a
/// hardware-type check, so previews and resizable windows behave identically.
class WearScaffold extends StatelessWidget {
  const WearScaffold({
    super.key,
    required this.title,
    required this.child,
    this.showBack = false,
    this.action,
  });

  final String title;
  final Widget child;
  final bool showBack;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth <= 260;
          // The header occupies the narrow top arc of a round display. At a
          // 12% inset its icon centers are inside the circle but the glyphs
          // themselves are clipped; 20% plus a slightly lower row keeps the
          // complete touch affordances visible down to 192 logical pixels.
          final double headerInset = compact ? constraints.maxWidth * 0.20 : 12;
          final double contentInset = compact
              ? constraints.maxWidth * 0.075
              : 12;
          return SafeArea(
            minimum: EdgeInsets.only(
              top: compact ? 8 : 0,
              bottom: compact ? 5 : 0,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: headerInset),
                  child: SizedBox(
                    key: const Key('wear-header'),
                    height: compact ? 46 : 48,
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: compact ? 32 : 40,
                          child: showBack
                              ? IconButton(
                                  key: const Key('wear-back'),
                                  tooltip: 'Back',
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.chevron_left,
                                    size: 20,
                                  ),
                                  onPressed: () => Navigator.of(context).pop(),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(width: compact ? 32 : 40, child: action),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: contentInset),
                    child: child,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Standard lazy-list padding that keeps the first and last rows away from
/// the narrowest top and bottom portions of a round screen.
const EdgeInsets wearListPadding = EdgeInsets.fromLTRB(4, 10, 4, 28);

class WearEmptyState extends StatelessWidget {
  const WearEmptyState({
    super.key,
    required this.message,
    this.details,
    this.icon = Icons.hourglass_empty,
    this.action,
  });

  final String message;
  final String? details;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: colors.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (details != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                details!,
                key: const Key('wear-error-details'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.error),
              ),
            ],
            if (action != null) ...<Widget>[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

String wearErrorText(Object error) {
  if (error is PlatformException) {
    final String? message = error.message?.trim();
    return message == null || message.isEmpty ? error.code : message;
  }
  final String text = error.toString();
  return text.startsWith('DaemonError: ')
      ? text.substring('DaemonError: '.length)
      : text;
}
