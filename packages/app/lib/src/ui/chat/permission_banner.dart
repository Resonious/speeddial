import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

/// Amber action bar shown while the agent is awaiting a permission decision.
/// Renders `request.title` plus one button per [PermissionOption]; allow
/// options get filled emphasis, reject options stay outlined.
class PermissionBanner extends StatelessWidget {
  const PermissionBanner({
    super.key,
    required this.request,
    required this.onOptionSelected,
  });

  final PermissionRequest request;

  /// Called with the chosen option's [PermissionOption.optionId].
  final ValueChanged<PermissionOption> onOptionSelected;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final ThemeData theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: colors.waitingPermission.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.waitingPermission.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: colors.waitingPermission,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              for (final PermissionOption option in request.options)
                _OptionButton(
                  option: option,
                  onSelected: () => onOptionSelected(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({required this.option, required this.onSelected});

  final PermissionOption option;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final bool allow =
        option.kind == PermissionKind.allowOnce ||
        option.kind == PermissionKind.allowAlways;
    if (allow) {
      return FilledButton(
        onPressed: onSelected,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Text(option.name),
      );
    }
    return OutlinedButton(
      onPressed: onSelected,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(option.name),
    );
  }
}
