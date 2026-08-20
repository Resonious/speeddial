import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../scope.dart';
import '../../state/mcp_store.dart';

Future<bool> _launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Daemon-scoped settings for MCP servers injected into ACP sessions.
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({
    super.key,
    required this.daemonId,
    required this.daemonName,
    this.launchExternal = _launchExternal,
  });

  final String daemonId;
  final String daemonName;

  final Future<bool> Function(Uri uri) launchExternal;
  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _refresh();
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 30),
        (Timer _) => _refresh(silent: true),
      );
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    try {
      final scope = AppScope.of(context);
      await scope.projects.refresh(widget.daemonId);
      await scope.mcp.refresh(widget.daemonId);
    } on Object catch (error) {
      if (!silent && mounted) _showError(error);
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
        projects: AppScope.of(context).projects.projectsFor(widget.daemonId),
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
        authType: profile.authType,
        oauthClientId: profile.oauthClientId,
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

  Future<void> _authorize(McpServerProfile profile) async {
    try {
      final McpStore store = AppScope.of(context).mcp;
      final McpOAuthFlow flow = await store.beginOAuth(
        widget.daemonId,
        profile.id,
      );
      final bool launched = await widget.launchExternal(
        Uri.parse(flow.authorizationUrl),
      );
      if (!launched) {
        throw StateError('Could not open the authorization page');
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => _OAuthProgressDialog(
          daemonId: widget.daemonId,
          serverId: profile.id,
          serverName: profile.name,
          flowId: flow.flowId,
          store: store,
        ),
      );
    } on Object catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _disconnect(McpServerProfile profile) async {
    try {
      await AppScope.of(context).mcp
          .disconnectOAuth(widget.daemonId, profile.id);
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
          final List<Project> projects = AppScope.of(
            context,
          ).projects.projectsFor(widget.daemonId);
          final Map<String, String> projectNames = <String, String>{
            for (final Project project in projects) project.id: project.name,
          };
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
                            scopeLabel:
                                servers[index].projectId == null
                                ? 'All projects'
                                : projectNames[servers[index].projectId] ??
                                      'Project unavailable',
                            onEnabledChanged: (bool value) =>
                                _toggle(servers[index], value),
                            onEdit: () => _openEditor(servers[index]),
                            onDelete: () => _delete(servers[index]),
                            onAuthorize: () => _authorize(servers[index]),
                            onDisconnect: () => _disconnect(servers[index]),
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
    required this.scopeLabel,
    required this.onEnabledChanged,
    required this.onEdit,
    required this.onDelete,
    required this.onAuthorize,
    required this.onDisconnect,
  });

  final McpServerProfile profile;
  final String scopeLabel;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAuthorize;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('mcp-server-${profile.id}'),
    leading: Icon(
      profile.transport == McpTransport.stdio ? Icons.terminal : Icons.language,
    ),
    title: Text(profile.name),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          scopeLabel,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        Text(
          profile.transport == McpTransport.stdio
              ? <String>[profile.command!, ...profile.args].join(' ')
              : profile.url!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (profile.authType == McpAuthType.oauth)
          Text(
            _oauthStatusLabel(profile),
            key: ValueKey<String>('mcp-oauth-status-${profile.id}'),
            style: TextStyle(
              color: _oauthStatusColor(context, profile.oauthStatus),
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Switch(value: profile.enabled, onChanged: onEnabledChanged),
        PopupMenuButton<String>(
          tooltip: 'MCP server actions',
          onSelected: (String action) => switch (action) {
            'authorize' => onAuthorize(),
            'disconnect' => onDisconnect(),
            'edit' => onEdit(),
            'delete' => onDelete(),
            _ => null,
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            if (profile.authType == McpAuthType.oauth)
              PopupMenuItem<String>(
                key: const Key('mcp-oauth-authorize'),
                value: 'authorize',
                child: Text(
                  profile.oauthStatus == McpOAuthStatus.authorized
                      ? 'Reauthorize'
                      : 'Connect account',
                ),
              ),
            if (profile.authType == McpAuthType.oauth &&
                profile.oauthStatus != McpOAuthStatus.notConnected)
              const PopupMenuItem<String>(
                value: 'disconnect',
                child: Text('Disconnect'),
              ),
            const PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
            const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    ),
  );

  static String _oauthStatusLabel(McpServerProfile profile) =>
      switch (profile.oauthStatus) {
        McpOAuthStatus.notConnected => 'OAuth: Not connected',
        McpOAuthStatus.authorizing => 'OAuth: Waiting for authorization',
        McpOAuthStatus.authorized => 'OAuth: Authorized',
        McpOAuthStatus.expired => 'OAuth: Expired — reauthorize',
        McpOAuthStatus.error =>
          'OAuth: ${profile.oauthError ?? 'Authorization failed'}',
      };

  static Color _oauthStatusColor(BuildContext context, McpOAuthStatus status) =>
      switch (status) {
        McpOAuthStatus.authorized => Colors.green.shade700,
        McpOAuthStatus.error ||
        McpOAuthStatus.expired => Theme.of(context).colorScheme.error,
        McpOAuthStatus.notConnected || McpOAuthStatus.authorizing => Theme.of(
          context,
        ).colorScheme.onSurfaceVariant,
      };
}

class _OAuthProgressDialog extends StatefulWidget {
  const _OAuthProgressDialog({
    required this.daemonId,
    required this.serverId,
    required this.serverName,
    required this.flowId,
    required this.store,
  });

  final String daemonId;
  final String serverId;
  final String serverName;
  final String flowId;
  final McpStore store;

  @override
  State<_OAuthProgressDialog> createState() => _OAuthProgressDialogState();
}

class _OAuthProgressDialogState extends State<_OAuthProgressDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _poll());
  }

  Future<void> _poll() async {
    while (mounted) {
      try {
        final McpServerProfile profile = await widget.store.oauthStatus(
          widget.daemonId,
          widget.serverId,
          widget.flowId,
        );
        if (!mounted) return;
        switch (profile.oauthStatus) {
          case McpOAuthStatus.authorized:
            Navigator.of(context).pop();
            return;
          case McpOAuthStatus.error:
          case McpOAuthStatus.expired:
          case McpOAuthStatus.notConnected:
            setState(() {
              _error = profile.oauthError ?? 'Authorization did not complete';
            });
            return;
          case McpOAuthStatus.authorizing:
            await Future<void>.delayed(const Duration(seconds: 1));
        }
      } on Object catch (error) {
        if (!mounted) return;
        setState(() => _error = error.toString());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Connect ${widget.serverName}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_error == null) ...<Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          const Text(
            'Finish authorization in your browser. This window will update '
            'automatically.',
            textAlign: TextAlign.center,
          ),
        ] else
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(_error == null ? 'Cancel' : 'Close'),
      ),
    ],
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
    required this.projects,
    this.existing,
  });

  final String daemonId;
  final List<Project> projects;
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
  late final TextEditingController _oauthClientId;
  late final TextEditingController _oauthClientSecret;
  late McpAuthType _authType;
  late String _scopeProjectId;
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
    _scopeProjectId = existing?.projectId ?? '';
    _authType = existing?.authType ?? McpAuthType.none;
    _name = TextEditingController(text: existing?.name);
    _endpoint = TextEditingController(
      text: existing?.transport == McpTransport.http
          ? existing?.url
          : existing?.command,
    );
    _args = TextEditingController(text: existing?.args.join('\n'));
    _oauthClientId = TextEditingController(text: existing?.oauthClientId);
    _oauthClientSecret = TextEditingController();
    _storedSecrets = Set<String>.of(existing?.secretNames ?? const <String>[]);
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _args.dispose();
    _oauthClientId.dispose();
    _oauthClientSecret.dispose();
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
      if (transport == McpTransport.stdio) {
        _authType = McpAuthType.none;
      }
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
          projectId: _scopeProjectId.isEmpty ? null : _scopeProjectId,
          command: _transport == McpTransport.stdio
              ? _endpoint.text.trim()
              : null,
          args: args,
          url: _transport == McpTransport.http ? _endpoint.text.trim() : null,
          secrets: secrets,
          authType: _transport == McpTransport.http
              ? _authType
              : McpAuthType.none,
          oauthClientId:
              _transport == McpTransport.http && _authType == McpAuthType.oauth
              ? _oauthClientId.text.trim()
              : null,
          oauthClientSecret:
              _transport == McpTransport.http &&
                  _authType == McpAuthType.oauth &&
                  _oauthClientSecret.text.isNotEmpty
              ? _oauthClientSecret.text
              : null,
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
          authType: _transport == McpTransport.http
              ? _authType
              : McpAuthType.none,
          oauthClientId:
              _transport == McpTransport.http && _authType == McpAuthType.oauth
              ? _oauthClientId.text.trim()
              : null,
          oauthClientSecret:
              _transport == McpTransport.http &&
                  _authType == McpAuthType.oauth &&
                  _oauthClientSecret.text.isNotEmpty
              ? _oauthClientSecret.text
              : null,
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
                DropdownButtonFormField<String>(
                  key: const Key('mcp-scope'),
                  initialValue: _scopeProjectId,
                  decoration: const InputDecoration(labelText: 'Available to'),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All projects'),
                    ),
                    for (final Project project in widget.projects)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(project.name),
                      ),
                  ],
                  onChanged: widget.existing == null
                      ? (String? value) {
                          if (value != null) {
                            setState(() => _scopeProjectId = value);
                          }
                        }
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
                if (!stdio) ...<Widget>[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<McpAuthType>(
                    key: const Key('mcp-auth-type'),
                    initialValue: _authType,
                    decoration: const InputDecoration(
                      labelText: 'Authentication',
                    ),
                    items: const <DropdownMenuItem<McpAuthType>>[
                      DropdownMenuItem(
                        value: McpAuthType.none,
                        child: Text('None or static headers'),
                      ),
                      DropdownMenuItem(
                        value: McpAuthType.oauth,
                        child: Text('OAuth 2.1'),
                      ),
                    ],
                    onChanged: (McpAuthType? value) {
                      if (value != null) setState(() => _authType = value);
                    },
                  ),
                  if (_authType == McpAuthType.oauth) ...<Widget>[
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('mcp-oauth-client-id'),
                      controller: _oauthClientId,
                      decoration: const InputDecoration(
                        labelText: 'OAuth client ID (optional)',
                        helperText:
                            'Leave blank to use dynamic client registration',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('mcp-oauth-client-secret'),
                      controller: _oauthClientSecret,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'OAuth client secret (optional)',
                        helperText:
                            widget.existing?.oauthClientSecretConfigured == true
                            ? 'Stored on daemon; enter a value to replace it'
                            : 'Required only by confidential clients',
                      ),
                    ),
                  ],
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
                  stdio
                      ? 'Environment variables'
                      : _authType == McpAuthType.oauth
                      ? 'Additional HTTP headers'
                      : 'HTTP headers',
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
