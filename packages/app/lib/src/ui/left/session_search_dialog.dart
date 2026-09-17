import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../api/daemon_client.dart';
import '../../state/session_search_store.dart';

class SessionSearchDialog extends StatefulWidget {
  const SessionSearchDialog({
    super.key,
    required this.client,
    required this.daemonName,
  });

  final DaemonClient client;
  final String daemonName;

  @override
  State<SessionSearchDialog> createState() => _SessionSearchDialogState();
}

class _SessionSearchDialogState extends State<SessionSearchDialog> {
  late final SessionSearchStore _store = SessionSearchStore(widget.client);
  final TextEditingController _text = TextEditingController();
  Timer? _timer;
  bool _inFlight = false;
  bool _pending = false;
  bool _more = false;

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    _store.dispose();
    super.dispose();
  }

  void _changed(String query) {
    _store.update(query: query);
    _pending = false;
    _schedule(const Duration(milliseconds: 250));
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_store.canSearch) return;
    _timer = Timer(delay, () => _request());
  }

  void _request({bool more = false}) {
    _timer?.cancel();
    _pending = true;
    _more = more;
    _drain();
  }

  /// At most one request per dialog is in flight. Edits during a slow search
  /// coalesce into the latest query; the store rejects stale replies.
  Future<void> _drain() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      while (_pending && mounted) {
        _pending = false;
        try {
          await _store.search(more: _more);
        } on Object {
          // The store records and rethrows failures; this UI boundary renders
          // them below with an explicit retry action.
        }
      }
    } finally {
      _inFlight = false;
    }
    if (mounted &&
        _store.indexing &&
        _store.lastError == null &&
        !(_timer?.isActive ?? false)) {
      _schedule(const Duration(milliseconds: 500));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 640,
        height: 580,
        child: ListenableBuilder(
          listenable: _store,
          builder: (BuildContext context, Widget? _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Search sessions',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close search',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Titles and messages in ${widget.daemonName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: TextField(
                  key: const Key('session-search-field'),
                  controller: _text,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(sessionSearchMaxLength),
                  ],
                  onChanged: _changed,
                  onSubmitted: (_) => _request(),
                  decoration: InputDecoration(
                    hintText: 'Search text…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _text.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _text.clear();
                              _changed('');
                            },
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: const Text('Include archived'),
                    selected: _store.includeArchived,
                    onSelected: (bool selected) {
                      _store.update(includeArchived: selected);
                      _request();
                    },
                  ),
                ),
              ),
              if (_store.loading)
                const LinearProgressIndicator(minHeight: 2)
              else
                const Divider(height: 2),
              if (_store.indexing)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Indexing saved messages… Results will update.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (_store.lastError != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _errorMessage(_store.lastError!),
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _request(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              Expanded(child: _results(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _results(BuildContext context) {
    if (_store.results.isEmpty) {
      final String message = !_store.canSearch
          ? 'Enter at least 3 characters to search.'
          : _store.loading
          ? 'Searching…'
          : _store.lastError != null
          ? ''
          : _store.indexing
          ? 'Searching saved messages…'
          : 'No sessions found.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      key: const Key('session-search-results'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _store.results.length + (_store.hasMore ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index == _store.results.length) {
          return Center(
            child: TextButton(
              onPressed: _store.loading ? null : () => _request(more: true),
              child: const Text('Load more'),
            ),
          );
        }
        final SessionSearchResult result = _store.results[index];
        final ColorScheme colors = Theme.of(context).colorScheme;
        return ListTile(
          key: ValueKey<String>('search-result-${result.session.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          title: Text(
            result.session.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                <String>[
                  result.projectName ?? 'Removed project',
                  result.session.providerId,
                  if (result.session.archived) 'Archived',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (result.excerpt != result.session.title) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  result.excerpt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          onTap: () => Navigator.of(context).pop(result),
        );
      },
    );
  }
}

String _errorMessage(Object error) {
  if (error is DaemonError) {
    if (error.code == -32601) {
      return 'Update this daemon to search its sessions.';
    }
    return error.message;
  }
  return 'Could not search sessions. Check the daemon connection and retry.';
}
