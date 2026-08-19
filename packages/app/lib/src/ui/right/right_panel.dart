import 'package:flutter/material.dart';

import 'files_tab.dart';
import 'git_tab.dart';

/// Right-hand workspace panel: tabbed Files | Git surface driven by the
/// [AppScope] store graph. Both tabs stay no-arg so the shell can build
/// them inline; selection comes from [AppScope.selection].
class RightPanel extends StatelessWidget {
  const RightPanel({super.key});

  @override
  Widget build(BuildContext context) {
    // Bottom-only: the panel's tab content must clear the system navigation
    // area on edge-to-edge Android. The narrow layout's bottom sheet already
    // applies a SafeArea, so this is a no-op there.
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const <Widget>[
            TabBar(
              tabs: <Widget>[Tab(text: 'Files'), Tab(text: 'Git')],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[FilesTab(), GitTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
