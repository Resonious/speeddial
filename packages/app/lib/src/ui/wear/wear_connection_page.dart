import 'package:flutter/material.dart';

import '../../scope.dart';
import 'wear_scaffold.dart';

/// One-time endpoint bootstrap for a standalone watch installation.
///
/// This is intentionally not a daemon settings surface: existing endpoints
/// are only selected elsewhere. A build can bypass it entirely by seeding an
/// endpoint through the Wear target's Dart defines.
class WearConnectionPage extends StatefulWidget {
  const WearConnectionPage({
    super.key,
    required this.data,
    this.showBack = false,
  });

  final AppData data;
  final bool showBack;

  @override
  State<WearConnectionPage> createState() => _WearConnectionPageState();
}

class _WearConnectionPageState extends State<WearConnectionPage> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _token = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String rawUrl = _url.text.trim();
    if (rawUrl.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.data.connections.addEndpoint(
        name: _endpointName(rawUrl),
        url: rawUrl,
        token: _token.text,
      );
      final String id = widget.data.connections.endpoints.last.id;
      widget.data.selection.selectedDaemonId = id;
      if (mounted && widget.showBack) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = wearErrorText(error);
      });
    }
  }

  String _endpointName(String rawUrl) {
    final String normalized = ConnectionsStore.normalizeEndpointUrl(rawUrl);
    return Uri.tryParse(normalized)?.host.isNotEmpty == true
        ? Uri.parse(normalized).host
        : 'SpeedDial daemon';
  }

  @override
  Widget build(BuildContext context) {
    return WearScaffold(
      title: 'Connect',
      showBack: widget.showBack,
      child: ListView(
        padding: wearListPadding,
        children: <Widget>[
          TextField(
            key: const Key('wear-daemon-url'),
            controller: _url,
            enabled: !_saving,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: const InputDecoration(
              labelText: 'Daemon URL',
              hintText: 'wss://host/ws',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wear-daemon-token'),
            controller: _token,
            enabled: !_saving,
            autocorrect: false,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            style: Theme.of(context).textTheme.bodySmall,
            decoration: const InputDecoration(labelText: 'Token (optional)'),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _error!,
              key: const Key('wear-connect-error'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('wear-daemon-save'),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi, size: 18),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
