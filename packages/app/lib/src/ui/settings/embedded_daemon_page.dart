import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../state/embedded_daemon_store.dart';

/// Settings for the embedded in-process daemon: bind interface, fixed port,
/// and auth token. Applying restarts the daemon and repoints its endpoint.
///
/// Desktop only (the page is reachable only when [AppData.localDaemon]
/// exists); non-desktop builds keep whatever is persisted for a future
/// desktop launch.
class EmbeddedDaemonPage extends StatefulWidget {
  const EmbeddedDaemonPage({super.key, required this.initial});

  /// The configuration to seed the form with ([EmbeddedDaemonStore.config]).
  final EmbeddedDaemonConfig initial;

  @override
  State<EmbeddedDaemonPage> createState() => _EmbeddedDaemonPageState();
}

class _EmbeddedDaemonPageState extends State<EmbeddedDaemonPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _customHost = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _token = TextEditingController();

  /// Sentinel dropdown values for the two common interfaces; anything else
  /// maps to the custom text field.
  static const String _loopback = '127.0.0.1';
  static const String _anyInterface = '0.0.0.0';
  static const String _custom = '\u0000custom';

  String _interface = _loopback;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final EmbeddedDaemonConfig config = widget.initial;
    _interface = switch (config.host) {
      _loopback || 'localhost' => _loopback,
      _anyInterface => _anyInterface,
      _ => _custom,
    };
    if (_interface == _custom) _customHost.text = config.host;
    _port.text = config.port == 0 ? '' : '${config.port}';
    _token.text = config.token;
  }

  @override
  void dispose() {
    _customHost.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  EmbeddedDaemonConfig _currentConfig() {
    final String host = _interface == _custom
        ? _customHost.text.trim()
        : _interface;
    final int port = int.tryParse(_port.text.trim()) ?? 0;
    return EmbeddedDaemonConfig(
      host: host,
      port: port,
      token: _token.text.trim(),
    );
  }

  Future<void> _apply() async {
    final AppData data = AppScope.of(context);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Restarting kills the daemon's agent processes; sessions survive and
    // respawn on their next turn, but a running turn is interrupted.
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Restart built-in daemon?'),
            content: const Text(
              'The built-in daemon restarts with the new settings. Running '
              'agent turns are interrupted; their sessions resume on the '
              'next message.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('embedded-daemon-restart-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Restart'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _applying = true);
    try {
      await data.applyEmbeddedDaemonConfig(_currentConfig());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to restart: $error')));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Built-in daemon')),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          data.embeddedDaemon,
          data.connections,
        ]),
        builder: (BuildContext context, Widget? _) {
          final EmbeddedDaemonStore store = data.embeddedDaemon;
          DaemonEndpoint? endpoint;
          for (final DaemonEndpoint e in data.connections.endpoints) {
            if (e.id == AppData.embeddedDaemonId) endpoint = e;
          }
          final Object? error = store.lastError;
          final bool busy = _applying || store.restarting;
          return Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (endpoint != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Running at ${endpoint.url}',
                      key: const Key('embedded-daemon-url'),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Last start failed: $error',
                      key: const Key('embedded-daemon-error'),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                DropdownButtonFormField<String>(
                  key: const Key('embedded-daemon-interface'),
                  initialValue: _interface,
                  decoration: const InputDecoration(
                    labelText: 'Interface',
                    helperText: 'Where the daemon accepts connections.',
                  ),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: _loopback,
                      child: Text('Loopback only (127.0.0.1)'),
                    ),
                    DropdownMenuItem<String>(
                      value: _anyInterface,
                      child: Text('All interfaces (0.0.0.0)'),
                    ),
                    DropdownMenuItem<String>(
                      value: _custom,
                      child: Text('Custom address'),
                    ),
                  ],
                  onChanged: (String? value) {
                    if (value == null) return;
                    setState(() => _interface = value);
                  },
                ),
                if (_interface == _custom) ...<Widget>[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('embedded-daemon-custom-host'),
                    controller: _customHost,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Bind address',
                      hintText: '192.168.1.10 or ::1',
                    ),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty)
                        ? 'Bind address is required'
                        : null,
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('embedded-daemon-port'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: 'Automatic',
                    helperText: 'Fixed port, or leave blank to pick a free '
                        'one at each launch.',
                  ),
                  validator: (String? value) {
                    final String trimmed = value?.trim() ?? '';
                    if (trimmed.isEmpty) return null;
                    final int? port = int.tryParse(trimmed);
                    if (port == null || port < 1 || port > 65535) {
                      return 'Enter a port between 1 and 65535';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('embedded-daemon-token'),
                  controller: _token,
                  decoration: InputDecoration(
                    labelText: 'Token',
                    helperText: 'Required for non-loopback interfaces. '
                        'Clients sign in with this token.',
                    suffixIcon: IconButton(
                      key: const Key('embedded-daemon-generate-token'),
                      tooltip: 'Generate random token',
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      onPressed: () => setState(
                        () => _token.text = generateEmbeddedDaemonToken(),
                      ),
                    ),
                  ),
                  validator: (String? value) {
                    if (_currentConfig().isLoopback) return null;
                    if (value == null || value.trim().isEmpty) {
                      return 'A token is required unless the daemon is '
                          'loopback-only';
                    }
                    return null;
                  },
                ),
                if (!_currentConfig().isLoopback)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'The daemon becomes reachable from your network.',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('embedded-daemon-apply'),
                  onPressed: busy ? null : _apply,
                  child: Text(busy ? 'Restarting…' : 'Apply & restart'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
