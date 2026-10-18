import 'package:flutter/material.dart';

/// A steady ember check marks restoration, matching the copy confirmation.
void showSessionRestoredNotice(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: <Widget>[
          Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text('Session restored'),
        ],
      ),
    ),
  );
}
