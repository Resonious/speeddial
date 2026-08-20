import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/mcp_store.dart';

/// Daemon-scoped settings for MCP servers injected into ACP sessions.
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({
    super.key,
    required this.daemonId,
    required this.daemonName,
  });

  final String daemonId;
  final String daemonName;

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await AppScope.of(context).mcp.refresh(widget.daemonId);
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _openEditor([McpServerProfile? existing]) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _McpServerDialog(
        daemonId: widget.daemonId,
        store: AppScope.of(context).mcp,
        existing: existing,
      ),
    );
  }

  Future<void> _toggle(McpServerProfile profile, bool enabled) async {
    try {
      await AppScope.of(context).mcp.update(
        widget.daemonId,
        id: profile.id,
        name: profile.name,
        transport: profile.transport,
        enabled: enabled,
        command: profile.command,
        args: profile.args,
        url: profile.url,
      );
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _delete(McpServerProfile profile) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete MCP server?'),
            content: Text(
              'Delete "${profile.name}" and its stored credentials?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('mcp-delete-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await AppScope.of(context).mcp.remove(widget.daemonId, profile.id);
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final McpStore store = AppScope.of(context).mcp;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.daemonName} settings')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('mcp-add-server'),
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: const Text('Add MCP server'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (BuildContext context, Widget? child) {
          final List<McpServerProfile> servers = store.serversFor(
            widget.daemonId,
          );
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: <Widget>[
                Text(
                  'MCP servers',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Enabled servers are registered directly with each agent. '
                  'Credentials stay on this daemon and are never returned to '
                  'the app. Changes apply before the next turn for reloadable '
                  'sessions and to all new sessions.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                if (store.isLoading(widget.daemonId) && servers.isEmpty)
                  const Center(child: CircularProgressIndicator())
                else if (servers.isEmpty)
                  const _EmptyMcpServers()
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < servers.length;
                          index++
                        ) ...<Widget>[
                          _McpServerTile(
                            profile: servers[index],
                            onEnabledChanged: (bool value) =>
                                _toggle(servers[index], value),
                            onEdit: () => _openEditor(servers[index]),
                            onDelete: () => _delete(servers[index]),
                          ),
                          if (index != servers.length - 1)
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

class _EmptyMcpServers extends StatelessWidget {
  const _EmptyMcpServers();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64),
    child: Column(
      children: <Widget>[
        Icon(
          Icons.extension_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        const Text('No MCP servers configured'),
      ],
    ),
  );
}

class _McpServerTile extends StatelessWidget {
  const _McpServerTile({
    required this.profile,
    required this.onEnabledChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final McpServerProfile profile;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('mcp-server-${profile.id}'),
    leading: Icon(
      profile.transport == McpTransport.stdio ? Icons.terminal : Icons.language,
    ),
    title: Text(profile.name),
    subtitle: Text(
      profile.transport == McpTransport.stdio
          ? <String>[profile.command!, ...profile.args].join(' ')
          : profile.url!,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Switch(value: profile.enabled, onChanged: onEnabledChanged),
        PopupMenuButton<String>(
          tooltip: 'MCP server actions',
          onSelected: (String action) => switch (action) {
            'edit' => onEdit(),
            'delete' => onDelete(),
            _ => null,
          },
          itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
            PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    ),
  );
}

class _SecretDraft {
  _SecretDraft()
    : name = TextEditingController(),
      value = TextEditingController();

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _McpServerDialog extends StatefulWidget {
  const _McpServerDialog({
    required this.daemonId,
    required this.store,
    this.existing,
  });

  final String daemonId;
  final McpStore store;
  final McpServerProfile? existing;

  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _args;
  late McpTransport _transport;
  late bool _enabled;
  late final Set<String> _storedSecrets;
  final Set<String> _removedSecrets = <String>{};
  final List<_SecretDraft> _secretDrafts = <_SecretDraft>[];
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final McpServerProfile? existing = widget.existing;
    _transport = existing?.transport ?? McpTransport.stdio;
    _enabled = existing?.enabled ?? true;
    _name = TextEditingController(text: existing?.name);
    _endpoint = TextEditingController(
      text: existing?.transport == McpTransport.http
          ? existing?.url
          : existing?.command,
    );
    _args = TextEditingController(text: existing?.args.join('\n'));
    _storedSecrets = Set<String>.of(existing?.secretNames ?? const <String>[]);
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _args.dispose();
    for (final _SecretDraft draft in _secretDrafts) {
      draft.dispose();
    }
    super.dispose();
  }

  void _changeTransport(McpTransport? transport) {
    if (transport == null || transport == _transport) return;
    setState(() {
      _transport = transport;
      _endpoint.clear();
      _args.clear();
    });
  }

  void _addSecret() => setState(() => _secretDrafts.add(_SecretDraft()));

  void _removeDraft(_SecretDraft draft) {
    setState(() => _secretDrafts.remove(draft));
    draft.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final Map<String, String> secrets = <String, String>{};
    for (final _SecretDraft draft in _secretDrafts) {
      final String name = draft.name.text.trim();
      if (name.isNotEmpty) secrets[name] = draft.value.text;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final List<String> args = _args.text
          .split('\n')
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      final McpServerProfile? existing = widget.existing;
      if (existing == null) {
        await widget.store.create(
          widget.daemonId,
          name: _name.text.trim(),
          transport: _transport,
          enabled: _enabled,
          command: _transport == McpTransport.stdio
              ? _endpoint.text.trim()
              : null,
          args: args,
          url: _transport == McpTransport.http ? _endpoint.text.trim() : null,
          secrets: secrets,
        );
      } else {
        await widget.store.update(
          widget.daemonId,
          id: existing.id,
          name: _name.text.trim(),
          transport: _transport,
          enabled: _enabled,
          command: _transport == McpTransport.stdio
              ? _endpoint.text.trim()
              : null,
          args: args,
          url: _transport == McpTransport.http ? _endpoint.text.trim() : null,
          secrets: secrets,
          removeSecretNames: _removedSecrets.toList(growable: false),
        );
      }
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
  Widget build(BuildContext context) {
    final bool stdio = _transport == McpTransport.stdio;
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add MCP server' : 'Edit MCP server',
      ),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextFormField(
                  key: const Key('mcp-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty
                      ? 'Enter a name'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<McpTransport>(
                  key: const Key('mcp-transport'),
                  initialValue: _transport,
                  decoration: const InputDecoration(labelText: 'Transport'),
                  items: const <DropdownMenuItem<McpTransport>>[
                    DropdownMenuItem(
                      value: McpTransport.stdio,
                      child: Text('Local command (stdio)'),
                    ),
                    DropdownMenuItem(
                      value: McpTransport.http,
                      child: Text('Remote server (HTTP)'),
                    ),
                  ],
                  onChanged: _changeTransport,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('mcp-endpoint'),
                  controller: _endpoint,
                  decoration: InputDecoration(
                    labelText: stdio ? 'Command' : 'URL',
                    hintText: stdio
                        ? '/path/to/mcp-server'
                        : 'https://example.com/mcp',
                  ),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty
                      ? 'Enter ${stdio ? 'a command' : 'a URL'}'
                      : null,
                ),
                if (stdio) ...<Widget>[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('mcp-args'),
                    controller: _args,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Arguments',
                      helperText: 'One argument per line',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  value: _enabled,
                  onChanged: (bool value) => setState(() => _enabled = value),
                ),
                const Divider(),
                Text(
                  stdio ? 'Environment variables' : 'HTTP headers',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Values are write-only and remain on the daemon.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final String name in _storedSecrets)
                  if (!_removedSecrets.contains(name))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(name),
                      subtitle: const Text('Stored on daemon'),
                      trailing: IconButton(
                        tooltip: 'Remove credential',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => _removedSecrets.add(name)),
                      ),
                    ),
                for (final _SecretDraft draft in _secretDrafts)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: TextFormField(
                          key: ValueKey<String>(
                            'mcp-secret-name-${_secretDrafts.indexOf(draft)}',
                          ),
                          controller: draft.name,
                          decoration: const InputDecoration(labelText: 'Name'),
                          validator: (String? value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter a name'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          key: ValueKey<String>(
                            'mcp-secret-value-${_secretDrafts.indexOf(draft)}',
                          ),
                          controller: draft.value,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Value'),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove row',
                        onPressed: () => _removeDraft(draft),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('mcp-add-secret'),
                    onPressed: _addSecret,
                    icon: const Icon(Icons.add),
                    label: Text(stdio ? 'Add variable' : 'Add header'),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('mcp-save'),
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
}
