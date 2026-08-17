import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';

/// Modal sheet used to create a session under [projectId] of [daemonId].
///
/// Provider options come from the daemon's `DaemonInfo`; the created session
/// is selected in the rail as soon as it exists. [data] is resolved by the
/// caller on the originating context — the sheet route's own context sits
/// above [AppScope], so AppScope.of must not run inside it.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.data,
    required this.daemonId,
    required this.projectId,
  });

  final AppData data;
  final String daemonId;
  final String projectId;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  Future<DaemonInfo>? _info;
  final TextEditingController _model = TextEditingController();
  final TextEditingController _title = TextEditingController();
  SessionMode _mode = SessionMode.build;
  String? _providerId;
  bool _submitting = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _info ??= widget.data.clientFor(widget.daemonId).info();
  }

  @override
  void dispose() {
    _model.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final AppData data = widget.data;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final Session session = await data.sessions.create(
        widget.daemonId,
        projectId: widget.projectId,
        providerId: _providerId!,
        model: _model.text.trim().isEmpty ? null : _model.text.trim(),
        mode: _mode,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      );
      data.selection.selectedProjectId = session.projectId;
      data.selection.selectedSessionId = session.id;
      if (mounted) Navigator.of(context).pop();
    } on DaemonError catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Failed to create session';
      });
    }
  }

  Widget _buildForm(BuildContext context, AsyncSnapshot<DaemonInfo> snapshot) {
    final ThemeData theme = Theme.of(context);
    final List<ProviderInfo> providers = snapshot.data?.providers ?? const <ProviderInfo>[];

    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (snapshot.hasError || providers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          providers.isEmpty ? 'No providers available' : 'Failed to load providers',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }

    _providerId ??= providers
        .firstWhere((ProviderInfo p) => p.available,
            orElse: () => providers.first)
        .id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DropdownButtonFormField<String>(
          key: const Key('new-session-provider'),
          initialValue: _providerId,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: <DropdownMenuItem<String>>[
            for (final ProviderInfo provider in providers)
              DropdownMenuItem<String>(
                value: provider.id,
                child: Text(
                  provider.available
                      ? provider.name
                      : '${provider.name} (unavailable)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _submitting
              ? null
              : (String? value) =>
                    setState(() => _providerId = value),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('new-session-model'),
          controller: _model,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Model (optional)'),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SegmentedButton<SessionMode>(
              key: const Key('new-session-mode'),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          segments: const <ButtonSegment<SessionMode>>[
            ButtonSegment<SessionMode>(
              value: SessionMode.build,
              label: Text('Build'),
            ),
            ButtonSegment<SessionMode>(
              value: SessionMode.plan,
              label: Text('Plan'),
            ),
          ],
          selected: <SessionMode>{_mode},
          onSelectionChanged: _submitting
              ? null
              : (Set<SessionMode> selection) =>
                    setState(() => _mode = selection.single),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('new-session-title'),
          controller: _title,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (String _) => _submit(),
          decoration: const InputDecoration(labelText: 'Title (optional)'),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: _submitting
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('new-session-submit'),
              onPressed: _submitting || _providerId == null ? null : _submit,
              child: const Text('Create session'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('New session', style: textTheme.titleMedium),
          const SizedBox(height: 16),
          FutureBuilder<DaemonInfo>(
            future: _info,
            builder: _buildForm,
          ),
        ],
      ),
    );
  }
}
