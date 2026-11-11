import 'package:flutter/material.dart';

import 'notes_panel.dart';

/// Right-hand pane: session notes (see [NotesPanel]). Kept as the shell's
/// stable entry point for the side column and the narrow layout's sheet.
class RightPanel extends StatelessWidget {
  const RightPanel({super.key});

  @override
  Widget build(BuildContext context) => const NotesPanel();
}
