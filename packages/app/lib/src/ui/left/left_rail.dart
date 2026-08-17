import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../theme.dart';

/// Daemon rail: lists configured endpoints with connection status dots and an
/// "Add daemon" action. Rendered inside the wide-layout rail slot or a drawer
/// on narrow screens.
class LeftRail extends StatelessWidget {
  const LeftRail({super.key});

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[data.connections, data.selection]),
        builder: (BuildContext context, Widget? _) {
          final List<DaemonEndpoint> endpoints = data.connections.endpoints;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Daemons',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (endpoints.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      'No daemons yet',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: endpoints.length,
                    itemBuilder: (BuildContext context, int index) {
                      final DaemonEndpoint endpoint = endpoints[index];
                      return _EndpointTile(
                        endpoint: endpoint,
                        status: data.connections.statusOf(endpoint.id),
                        selected:
                            data.selection.selectedDaemonId == endpoint.id,
                        onTap: () =>
                            data.selection.selectedDaemonId = endpoint.id,
                      );
                    },
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: () => _showAddDaemonDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add daemon'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAddDaemonDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          _AddDaemonDialog(connections: AppScope.of(context).connections),
    );
  }
}

class _EndpointTile extends StatelessWidget {
  const _EndpointTile({
    required this.endpoint,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final DaemonEndpoint endpoint;
  final ConnectionStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 24,
        height: 24,
        child: _StatusDot(color: connectionStatusColor(context, status)),
      ),
      title: Text(
        endpoint.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyMedium,
      ),
      subtitle: Text(
        endpoint.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      selected: selected,
      selectedTileColor: scheme.surfaceContainerHighest,
      onTap: onTap,
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

class _AddDaemonDialog extends StatefulWidget {
  const _AddDaemonDialog({required this.connections});

  final ConnectionsStore connections;

  @override
  State<_AddDaemonDialog> createState() => _AddDaemonDialogState();
}

class _AddDaemonDialogState extends State<_AddDaemonDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _token = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String url = _url.text.trim();
    final String name = _name.text.trim().isEmpty ? url : _name.text.trim();
    setState(() => _submitting = true);
    await widget.connections.addEndpoint(
      name: name,
      url: url,
      token: _token.text.trim(),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add daemon'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              key: const Key('add-daemon-name'),
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('add-daemon-url'),
              controller: _url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Host or URL',
                hintText: 'localhost:7331',
              ),
              validator: (String? value) =>
                  (value == null || value.trim().isEmpty)
                      ? 'Host or URL is required'
                      : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('add-daemon-token'),
              controller: _token,
              obscureText: true,
              onFieldSubmitted: (String _) => _submit(),
              decoration: const InputDecoration(labelText: 'Token (optional)'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-daemon-submit'),
          onPressed: _submitting ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
