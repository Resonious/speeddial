import 'package:flutter/material.dart';

import '../theme.dart';

/// A quiet expansion of the mobile header, with room to read and copy its title.
Future<void> showSessionTitleDialog(BuildContext context, String title) {
  final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.4),
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      child: Dialog(
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: context.speedDialColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Session title',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close session title',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 12),
                  child: SelectableText(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(height: 1.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (reduceMotion) return child;
      final Animation<double> eased = animation.drive(
        CurveTween(curve: Curves.easeOutCubic),
      );
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          alignment: Alignment.topCenter,
          scale: eased.drive(Tween<double>(begin: 0.94, end: 1)),
          child: child,
        ),
      );
    },
  );
}
