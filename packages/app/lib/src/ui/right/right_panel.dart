import 'package:flutter/material.dart';

/// Placeholder right panel: tabbed workspace surface. Later phases fill in
/// the lazy file tree and git views.
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
              children: <Widget>[
                _NotConnectedBody(icon: Icons.folder_outlined),
                _NotConnectedBody(icon: Icons.account_tree_outlined),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotConnectedBody extends StatelessWidget {
  const _NotConnectedBody({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? hintStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 32, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text('Not connected', style: hintStyle),
        ],
      ),
    );
  }
}
