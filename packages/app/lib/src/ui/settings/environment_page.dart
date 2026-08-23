import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../state/daemon_config_store.dart';

/// Write-only daemon environment applied to harnesses spawned in the future.
class EnvironmentPage extends StatefulWidget {
  const EnvironmentPage({
    super.key,
    required this.daemonId,
    required this.daemonName,
  });

  final String daemonId;
  final String daemonName;

  @override
  State<EnvironmentPage> createState() => _EnvironmentPageState();
}

class _EnvironmentPageState extends State<EnvironmentPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await AppScope.of(context).daemonConfig
          .refreshEnvironment(widget.daemonId);
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _openEditor([String? existingName]) => showDialog<void>(
    context: context,
    builder: (BuildContext context) => _EnvironmentVariableDialog(
      daemonId: widget.daemonId,
      store: AppScope.of(this.context).daemonConfig,
      existingName: existingName,
    ),
  );

  Future<void> _remove(String name) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Remove environment variable?'),
            content: Text('Remove "$name" from future harness processes?'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('environment-remove-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await AppScope.of(context).daemonConfig
          .removeEnvironmentVariable(widget.daemonId, name);
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
      appBar: AppBar(title: Text('${widget.daemonName} Environment')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('environment-add-variable'),
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: const Text('Add variable'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (BuildContext context, Widget? child) {
          final List<String> names = store.environmentNamesFor(widget.daemonId);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: <Widget>[
                Text(
                  'Environment',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Values are write-only and stored on this daemon. They are '
                  'passed to every new or resumed harness process; running '
                  'sessions are not restarted.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                if (store.isLoadingEnvironment(widget.daemonId) &&
                    names.isEmpty)
                  const Center(child: CircularProgressIndicator())
                else if (names.isEmpty)
                  const _EmptyEnvironment()
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < names.length;
                          index++
                        ) ...<Widget>[
                          ListTile(
                            key: ValueKey<String>(
                              'environment-variable-${names[index]}',
                            ),
                            leading: const Icon(Icons.key_outlined),
                            title: Text(names[index]),
                            subtitle: const Text('Stored on daemon'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  key: ValueKey<String>(
                                    'environment-edit-${names[index]}',
                                  ),
                                  tooltip: 'Replace value',
                                  onPressed: () => _openEditor(names[index]),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  key: ValueKey<String>(
                                    'environment-remove-${names[index]}',
                                  ),
                                  tooltip: 'Remove variable',
                                  onPressed: () => _remove(names[index]),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                          if (index != names.length - 1)
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

class _EnvironmentVariableDialog extends StatefulWidget {
  const _EnvironmentVariableDialog({
    required this.daemonId,
    required this.store,
    this.existingName,
  });

  final String daemonId;
  final DaemonConfigStore store;
  final String? existingName;

  @override
  State<_EnvironmentVariableDialog> createState() =>
      _EnvironmentVariableDialogState();
}

class _EnvironmentVariableDialogState
    extends State<_EnvironmentVariableDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.existingName,
  );
  final TextEditingController _value = TextEditingController();
  bool _obscureValue = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.setEnvironmentVariable(
        widget.daemonId,
        _name.text.trim(),
        _value.text,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existingName == null
          ? 'Add environment variable'
          : 'Replace value',
    ),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextFormField(
              key: const Key('environment-name'),
              controller: _name,
              readOnly: widget.existingName != null,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (String? value) {
                final String name = value?.trim() ?? '';
                if (name.isEmpty) return 'Enter a name';
                if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
                  return 'Use letters, numbers, and underscores';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('environment-value'),
              controller: _value,
              obscureText: _obscureValue,
              decoration: InputDecoration(
                labelText: 'Value',
                helperText: widget.existingName == null
                    ? 'Stored on daemon and never returned to the app'
                    : 'The existing value is write-only; enter its replacement',
                suffixIcon: IconButton(
                  tooltip: _obscureValue ? 'Show value' : 'Hide value',
                  onPressed: () => setState(() {
                    _obscureValue = !_obscureValue;
                  }),
                  icon: Icon(
                    _obscureValue ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('environment-save'),
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Save'),
      ),
    ],
  );
}

class _EmptyEnvironment extends StatelessWidget {
  const _EmptyEnvironment();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64),
    child: Column(
      children: <Widget>[
        Icon(
          Icons.key_off_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        const Text('No daemon environment variables'),
      ],
    ),
  );
}
