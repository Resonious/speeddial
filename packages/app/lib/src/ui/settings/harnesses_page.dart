import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/daemon_config_store.dart';

/// Installed supported harnesses on one daemon, with native update actions.
class HarnessesPage extends StatefulWidget {
  const HarnessesPage({
    super.key,
    required this.daemonId,
    required this.daemonName,
  });

  final String daemonId;
  final String daemonName;

  @override
  State<HarnessesPage> createState() => _HarnessesPageState();
}

class _HarnessesPageState extends State<HarnessesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await AppScope.of(context).daemonConfig.refreshHarnesses(widget.daemonId);
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _update(HarnessInfo harness) async {
    try {
      final HarnessInfo updated = await AppScope.of(context).daemonConfig
          .updateHarness(widget.daemonId, harness.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${updated.name} is now ${updated.version}')),
        );
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  Widget build(BuildContext context) {
    final DaemonConfigStore store = AppScope.of(context).daemonConfig;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.daemonName} Harnesses')),
      body: ListenableBuilder(
        listenable: store,
        builder: (BuildContext context, Widget? child) {
          final List<HarnessInfo> harnesses = store.harnessesFor(
            widget.daemonId,
          );
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  'Harnesses',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Installed coding-agent CLIs on this daemon. Updating uses '
                  'each harness\'s native update command; running sessions '
                  'continue with their current process.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                if (store.isLoadingHarnesses(widget.daemonId) &&
                    harnesses.isEmpty)
                  const Center(child: CircularProgressIndicator())
                else if (harnesses.isEmpty)
                  const _EmptyHarnesses()
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < harnesses.length;
                          index++
                        ) ...<Widget>[
                          _HarnessTile(
                            harness: harnesses[index],
                            updating: store.isUpdatingHarness(
                              widget.daemonId,
                              harnesses[index].id,
                            ),
                            onUpdate: () => _update(harnesses[index]),
                          ),
                          if (index != harnesses.length - 1)
                            const Divider(height: 1),
                        ],
                      ],
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

class _HarnessTile extends StatelessWidget {
  const _HarnessTile({
    required this.harness,
    required this.updating,
    required this.onUpdate,
  });

  final HarnessInfo harness;
  final bool updating;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('harness-${harness.id}'),
    leading: const Icon(Icons.terminal),
    title: Text(harness.name),
    subtitle: Text(harness.version),
    trailing: OutlinedButton.icon(
      key: ValueKey<String>('harness-update-${harness.id}'),
      onPressed: updating ? null : onUpdate,
      icon: updating
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.system_update_alt, size: 18),
      label: Text(updating ? 'Updating' : 'Update'),
    ),
  );
}

class _EmptyHarnesses extends StatelessWidget {
  const _EmptyHarnesses();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64),
    child: Column(
      children: <Widget>[
        Icon(
          Icons.terminal_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        const Text('No supported harnesses installed'),
      ],
    ),
  );
}
