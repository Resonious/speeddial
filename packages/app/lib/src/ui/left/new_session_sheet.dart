import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../daemon_error_text.dart';

/// Modal sheet used to create a session under [projectId] of [daemonId].
///
/// The sheet asks for the session's initial prompt (sent as the first turn
/// right after creation; the prompt's first line becomes the title) and —
/// when the project is a git repository — for a base branch: the daemon then
/// fetches `origin/<base>` and runs the agent in a fresh worktree branched
/// off the remote tip.
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
    this.messenger,
  });

  final AppData data;
  final String daemonId;
  final String projectId;

  /// Snackbar target for reporting a failed initial-prompt send; captured by
  /// the caller because the sheet route's own context dies when it closes.
  final ScaffoldMessengerState? messenger;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

/// Providers plus the project's branch list (empty for non-git projects).
typedef _SheetData = ({DaemonInfo info, List<Branch> branches});

class _NewSessionSheetState extends State<NewSessionSheet> {
  Future<_SheetData>? _data;
  final TextEditingController _prompt = TextEditingController();

  /// Model id, mirrored from the Autocomplete field (which owns its
  /// controller) via onChanged/onSelected.
  String _modelText = '';
  SessionMode _mode = SessionMode.build;
  String? _providerId;
  String? _baseBranch;
  bool _useWorktree = true;
  bool _yolo = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Sticky across sheet opens: seed from the last choice (kept on
    // AppData) instead of always starting unchecked.
    _yolo = widget.data.newSessionYolo;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<_SheetData> _load() async {
    final client = widget.data.clientFor(widget.daemonId);
    final DaemonInfo info = await client.info();
    List<Branch> branches = const <Branch>[];
    try {
      branches = await client.gitBranches(widget.projectId);
    } on Exception {
      // Not a git repository (or git missing on the daemon host): the
      // worktree controls stay hidden and sessions use the project dir.
    }
    return (info: info, branches: branches);
  }

  /// The session title is the prompt's first line, whitespace-collapsed and
  /// capped so it stays readable in the rail.
  static String _titleFromPrompt(String prompt) {
    final String firstLine =
        prompt.split('\n').first.trim().replaceAll(RegExp(r'\s+'), ' ');
    return firstLine.length <= 60 ? firstLine : '${firstLine.substring(0, 60)}…';
  }

  Future<void> _submit() async {
    final AppData data = widget.data;
    final String prompt = _prompt.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final Session session = await data.sessions.create(
        widget.daemonId,
        projectId: widget.projectId,
        providerId: _providerId!,
        model: _modelText.trim().isEmpty ? null : _modelText.trim(),
        mode: _mode,
        title: prompt.isEmpty ? null : _titleFromPrompt(prompt),
        baseBranch: _useWorktree ? _baseBranch : null,
        yolo: _yolo,
      );
      data.selection.selectedProjectId = session.projectId;
      data.selection.selectedSessionId = session.id;
      if (mounted) Navigator.of(context).pop();
      if (prompt.isNotEmpty) {
        // Fire-and-forget: sendMessage resolves only when the whole turn
        // completes, and the sheet is already closed by then. A failure is
        // surfaced as a snackbar — softened for connection drops (e.g. the
        // device slept mid-turn): the turn keeps running daemon-side and
        // the client reconnects on its own, so a raw error would be noise.
        unawaited(
          data.chat.send(widget.daemonId, session.id, prompt).catchError(
            (Object error) {
              final String text = error is DaemonConnectionError
                  ? kConnectionLostMessage
                  : 'Failed to send the initial prompt: $error';
              widget.messenger?.showSnackBar(SnackBar(content: Text(text)));
            },
          ),
        );
      }
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

  Widget _buildForm(BuildContext context, AsyncSnapshot<_SheetData> snapshot) {
    final ThemeData theme = Theme.of(context);
    final List<ProviderInfo> providers =
        snapshot.data?.info.providers ?? const <ProviderInfo>[];
    final List<Branch> branches =
        snapshot.data?.branches ?? const <Branch>[];

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
    if (branches.isNotEmpty && _baseBranch == null) {
      // Prefer the checked-out branch, then main, then the first listed.
      _baseBranch = branches
          .firstWhere((Branch b) => b.isCurrent,
              orElse: () => branches.firstWhere((Branch b) => b.name == 'main',
                  orElse: () => branches.first))
          .name;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextFormField(
          key: const Key('new-session-prompt'),
          controller: _prompt,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            labelText: 'Initial prompt (optional)',
            hintText: 'What should the agent work on first?',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
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
        Autocomplete<String>(
          // The selected provider's known models, substring-filtered; the
          // field stays free-text so unlisted ids remain valid.
          optionsBuilder: (TextEditingValue value) {
            final List<String> models = providers
                .where((ProviderInfo p) => p.id == _providerId)
                .expand((ProviderInfo p) => p.models)
                .toList(growable: false);
            final String query = value.text.trim().toLowerCase();
            if (query.isEmpty) return models;
            return models
                .where((String m) => m.toLowerCase().contains(query))
                .toList(growable: false);
          },
          onSelected: (String selection) => _modelText = selection,
          fieldViewBuilder: (BuildContext context,
              TextEditingController controller,
              FocusNode focusNode,
              VoidCallback onFieldSubmitted) {
            return TextFormField(
              key: const Key('new-session-model'),
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Model (optional)'),
              onChanged: (String value) => _modelText = value,
            );
          },
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
        const SizedBox(height: 4),
        CheckboxListTile(
          key: const Key('new-session-yolo'),
          value: _yolo,
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Yolo mode'),
          subtitle:
              const Text('Auto-approve every permission request from the agent'),
          onChanged: _submitting
              ? null
              : (bool? value) => setState(() {
                    _yolo = value ?? false;
                    // Sticky even when the sheet is cancelled: the next
                    // sheet seeds from this.
                    widget.data.newSessionYolo = _yolo;
                  }),
        ),
        if (branches.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          CheckboxListTile(
            key: const Key('new-session-worktree'),
            value: _useWorktree,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('New worktree'),
            subtitle: const Text('Branch a worktree off the latest origin tip'),
            onChanged: _submitting
                ? null
                : (bool? value) =>
                      setState(() => _useWorktree = value ?? false),
          ),
          if (_useWorktree) ...<Widget>[
            const SizedBox(height: 8),
            // Searchable dropdown (the model field above uses the same
            // pattern): typing filters the entries case-insensitively by
            // label. Selection stays constrained to listed branches — the
            // daemon fetches origin/<base>, so a free-text typo would just
            // fail at creation time.
            DropdownMenu<String>(
              key: const Key('new-session-base-branch'),
              initialSelection: _baseBranch,
              label: const Text('Base branch'),
              expandedInsets: EdgeInsets.zero,
              enableFilter: true,
              requestFocusOnTap: true,
              enabled: !_submitting,
              dropdownMenuEntries: <DropdownMenuEntry<String>>[
                for (final Branch branch in branches)
                  DropdownMenuEntry<String>(
                    value: branch.name,
                    label: branch.name,
                  ),
              ],
              onSelected: (String? value) =>
                  setState(() => _baseBranch = value),
            ),
          ],
        ],
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
    // Keep the action row above the system navigation bar on edge-to-edge
    // Android: the sheet's background extends to the screen's bottom edge,
    // which the nav bar overlays. The route adds the keyboard's viewInsets
    // below, but those collapse when the keyboard dismisses — `padding`
    // (already consumed to zero while the keyboard is up) covers exactly the
    // remaining nav-bar case without adding a dead gap above the keyboard.
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.paddingOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('New session', style: textTheme.titleMedium),
            const SizedBox(height: 16),
            FutureBuilder<_SheetData>(
              future: _data,
              builder: _buildForm,
            ),
          ],
        ),
      ),
    );
  }
}
