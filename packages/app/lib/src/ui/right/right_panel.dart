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
    return DefaultTabController(
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
    );
  }
}
