import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/inbox_search_store.dart';
import '../../state/sessions_store.dart';
import 'inbox_new_session.dart';
import 'session_list.dart';

/// Activity-sorted sessions from every configured daemon.
class InboxTab extends StatefulWidget {
  const InboxTab({super.key, this.onSessionCreated});

  final VoidCallback? onSessionCreated;

  @override
  State<InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<InboxTab> {
  AppData? _data;
  final TextEditingController _search = TextEditingController();
  final Set<String> _requested = <String>{};
  final Set<String> _loading = <String>{};

  /// daemonId → the projects whose git badges this tab has already fetched.
  /// [GitStore] keeps them fresh from then on.
  final Map<String, Set<String>> _summariesRequested = <String, Set<String>>{};
  final Map<String, Object> _errors = <String, Object>{};
  final ValueNotifier<int> _loadRevision = ValueNotifier<int>(0);
  bool _refreshScheduled = false;

  late final InboxSearchStore _searchStore = InboxSearchStore(
    (String daemonId) => _data!.clientFor(daemonId),
  );
  Timer? _searchTimer;
  Timer? _slowSearchTimer;
  bool _searchInFlight = false;
  bool _searchPending = false;

  /// The search has been running long enough to say so (motion rule 5).
  bool _slowSearch = false;

  /// The daemons the current results came from; a change re-runs the search.
  Set<String> _searchedDaemons = <String>{};

  @override
  void initState() {
    super.initState();
    _search.addListener(_queryChanged);
    _searchStore.addListener(_rememberSearchResults);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppData data = AppScope.of(context);
    if (!identical(_data, data)) {
      _data?.connections.removeListener(_scheduleRefresh);
      _data?.projects.removeListener(_scheduleRefresh);
      _data = data;
      data.connections.addListener(_scheduleRefresh);
      data.projects.addListener(_scheduleRefresh);
      _requested.clear();
      _summariesRequested.clear();
      _loading.clear();
      _errors.clear();
      _searchedDaemons = <String>{};
    }
    _scheduleRefresh();
  }

  @override
  void dispose() {
    _data?.connections.removeListener(_scheduleRefresh);
    _data?.projects.removeListener(_scheduleRefresh);
    _loadRevision.dispose();
    _searchTimer?.cancel();
    _slowSearchTimer?.cancel();
    _search.dispose();
    _searchStore.dispose();
    super.dispose();
  }

  Set<String> get _configuredDaemons => <String>{
    for (final DaemonEndpoint endpoint
        in _data?.connections.activeEndpoints ?? const <DaemonEndpoint>[])
      endpoint.id,
  };

  void _queryChanged() {
    if (_search.text.trim() == _searchStore.query) return;
    _searchStore.update(query: _search.text);
    _scheduleSearch(const Duration(milliseconds: 250));
  }

  void _setIncludeArchived(bool value) {
    _searchStore.update(includeArchived: value);
    _scheduleSearch(Duration.zero);
  }

  void _scheduleSearch(Duration delay) {
    _searchTimer?.cancel();
    if (!_searchStore.canSearch) {
      _searchPending = false;
      return;
    }
    _searchTimer = Timer(delay, _requestSearch);
  }

  void _requestSearch() {
    _searchTimer?.cancel();
    _searchPending = true;
    unawaited(_drainSearches());
  }

  /// One search round is in flight at a time; edits during a slow one
  /// coalesce into the latest query and the store drops stale replies.
  Future<void> _drainSearches() async {
    if (_searchInFlight) return;
    _searchInFlight = true;
    _slowSearchTimer?.cancel();
    _slowSearchTimer = Timer(const Duration(milliseconds: 150), () {
      _slowSearch = true;
      if (mounted) _loadRevision.value++;
    });
    try {
      while (_searchPending && mounted) {
        _searchPending = false;
        _searchedDaemons = _configuredDaemons;
        try {
          await _searchStore.search(_searchedDaemons);
        } on Object {
          // The store records each daemon's failure; the status line below
          // the search field renders them with a retry action.
        }
      }
    } finally {
      _searchInFlight = false;
      _slowSearchTimer?.cancel();
      _slowSearch = false;
      if (mounted) _loadRevision.value++;
    }
    if (mounted &&
        _searchStore.indexing &&
        !(_searchTimer?.isActive ?? false)) {
      _scheduleSearch(const Duration(milliseconds: 500));
    }
  }

  /// Hits from daemons whose sessions aren't cached yet (or were never
  /// listed) join the sessions store so rows stay live and actionable.
  void _rememberSearchResults() {
    final AppData? data = _data;
    if (data == null) return;
    for (final MapEntry<String, List<SessionSearchResult>> entry
        in _searchStore.results.entries) {
      for (final SessionSearchResult result in entry.value) {
        if (data.sessions.sessionOnDaemon(entry.key, result.session.id) ==
            null) {
          data.sessions.rememberSearchResult(entry.key, result.session);
        }
      }
    }
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refreshNewEndpoints();
    });
  }

  void _refreshNewEndpoints() {
    final AppData? data = _data;
    if (data == null) return;
    final Set<String> configured = <String>{
      for (final DaemonEndpoint endpoint in data.connections.activeEndpoints)
        endpoint.id,
    };
    _requested.removeWhere((String id) => !configured.contains(id));
    _errors.removeWhere((String id, Object _) => !configured.contains(id));
    _summariesRequested.removeWhere(
      (String id, Set<String> _) => !configured.contains(id),
    );
    for (final String daemonId in configured) {
      // Real WebSocket clients reject requests until the connection handshake
      // finishes. Registered fake clients stay `disconnected` and can be read
      // immediately. The connection listener retries this check on `connected`.
      data.clientFor(daemonId);
      final ConnectionStatus status = data.connections.statusOf(daemonId);
      if (status != ConnectionStatus.connected &&
          status != ConnectionStatus.disconnected) {
        continue;
      }
      _refreshNewSummaries(data, daemonId);
      if (!_requested.add(daemonId)) continue;
      _loading.add(daemonId);
      unawaited(_loadDaemon(data, daemonId));
    }
    if (_searchStore.canSearch &&
        (configured.length != _searchedDaemons.length ||
            !configured.containsAll(_searchedDaemons))) {
      _scheduleSearch(Duration.zero);
    }
    _loadRevision.value++;
  }

  /// Inbox rows span every project, so unlike the Sessions tree there is no
  /// expansion to kick the git badge fetch. Runs again whenever the project
  /// list changes, which also covers the daemon's first load.
  void _refreshNewSummaries(AppData data, String daemonId) {
    final Set<String> requested = _summariesRequested.putIfAbsent(
      daemonId,
      () => <String>{},
    );
    for (final Project project in data.projects.projectsFor(daemonId)) {
      if (requested.add(project.id)) {
        unawaited(data.git.refreshSessionSummaries(daemonId, project.id));
      }
    }
  }

  Future<void> _loadDaemon(AppData data, String daemonId) async {
    try {
      await Future.wait<void>(<Future<void>>[
        data.projects.refresh(daemonId),
        data.sessions.refresh(daemonId),
      ]);
      if (!data.projects.hasLoaded(daemonId)) {
        throw data.projects.lastError ?? StateError('Could not load projects');
      }
      _errors.remove(daemonId);
    } on Object catch (error) {
      _errors[daemonId] = error;
    } finally {
      _loading.remove(daemonId);
      if (mounted) _loadRevision.value++;
    }
  }

  void _retryFailed() {
    _requested.removeAll(_errors.keys);
    _errors.clear();
    _refreshNewEndpoints();
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        data.connections,
        data.projects,
        data.sessions,
        data.selection,
        _loadRevision,
        _search,
        _searchStore,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<DaemonEndpoint> endpoints = data.connections.activeEndpoints;
        final Set<String> daemonIds = <String>{
          for (final DaemonEndpoint endpoint in endpoints) endpoint.id,
        };
        final String rawQuery = _search.text.trim();
        final String query = rawQuery.toLowerCase();
        final bool includeArchived = _searchStore.includeArchived;
        final bool remote = _searchStore.canSearch;
        final Map<String, String> excerpts = <String, String>{
          if (remote)
            for (final MapEntry<String, List<SessionSearchResult>> entry
                in _searchStore.results.entries)
              for (final SessionSearchResult result in entry.value)
                '${entry.key}/${result.session.id}': result.excerpt,
        };
        final List<RecentSession> allSessions = data.sessions.recentSessions(
          daemonIds: daemonIds,
          includeArchived: includeArchived,
        );
        // Titles filter locally so rows answer every keystroke (and follow
        // renames); the daemons add sessions whose messages match.
        final List<RecentSession> sessions = query.isEmpty
            ? allSessions
            : data.sessions.recentSessions(
                daemonIds: daemonIds,
                includeArchived: includeArchived,
                where: (String daemonId, Session session) =>
                    session.title.toLowerCase().contains(query) ||
                    excerpts.containsKey('$daemonId/${session.id}'),
              );
        final bool waitingForConnection = endpoints.any((
          DaemonEndpoint endpoint,
        ) {
          final ConnectionStatus status = data.connections.statusOf(
            endpoint.id,
          );
          return status == ConnectionStatus.connecting ||
              status == ConnectionStatus.reconnecting;
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8, top: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'All sessions',
                      style: textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('inbox-new-session'),
                    tooltip: 'New session',
                    icon: const Icon(Icons.add_comment_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: endpoints.isEmpty
                        ? null
                        : () => showInboxNewSession(
                            context,
                            onSessionCreated: widget.onSessionCreated,
                          ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                key: const Key('inbox-search-field'),
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search sessions…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: _search.clear,
                        ),
                ),
              ),
            ),
            _SearchOptions(
              includeArchived: includeArchived,
              onIncludeArchivedChanged: _setIncludeArchived,
              status: remote ? _searchStatus(endpoints) : null,
              failed: remote && _searchStore.errors.isNotEmpty,
              onRetry: _requestSearch,
            ),
            if (_errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Could not load ${_errors.length} '
                        '${_errors.length == 1 ? 'daemon' : 'daemons'}',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _retryFailed,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: endpoints.isEmpty
                  ? Center(
                      child: Text(
                        'Add a daemon to begin',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : allSessions.isEmpty &&
                        (_loading.isNotEmpty || waitingForConnection)
                  ? const Center(child: CircularProgressIndicator())
                  : sessions.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty
                            ? (includeArchived
                                  ? 'No sessions'
                                  : 'No active sessions')
                            : remote && _searchStore.searching
                            ? 'Searching…'
                            : remote && _searchStore.indexing
                            ? 'Searching saved messages…'
                            : 'No matching sessions',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : InboxSessionList(
                      sessions: sessions,
                      excerpts: excerpts,
                      highlight: remote ? rawQuery : null,
                      daemonNames: <String, String>{
                        for (final DaemonEndpoint endpoint in endpoints)
                          endpoint.id: endpoint.name,
                      },
                      projectNames: <String, Map<String, String>>{
                        for (final DaemonEndpoint endpoint in endpoints)
                          endpoint.id: <String, String>{
                            for (final project in data.projects.projectsFor(
                              endpoint.id,
                            ))
                              project.id: project.name,
                          },
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// One quiet line under the search field while a daemon search is live.
  String? _searchStatus(List<DaemonEndpoint> endpoints) {
    final Map<String, Object> errors = _searchStore.errors;
    if (errors.isNotEmpty) {
      final List<String> names = <String>[
        for (final DaemonEndpoint endpoint in endpoints)
          if (errors.containsKey(endpoint.id)) endpoint.name,
      ];
      return names.length == 1
          ? 'Could not search ${names.single}'
          : 'Could not search ${names.length} daemons';
    }
    if (_searchStore.searching && _slowSearch) return 'Searching…';
    if (_searchStore.indexing) return 'Searching saved messages…';
    if (_searchStore.truncated) {
      return 'Showing the newest ${InboxSearchStore.pageSize} '
          'matches per daemon';
    }
    return null;
  }
}

/// The archived toggle, with the search's status beside it.
class _SearchOptions extends StatelessWidget {
  const _SearchOptions({
    required this.includeArchived,
    required this.onIncludeArchivedChanged,
    required this.status,
    required this.failed,
    required this.onRetry,
  });

  final bool includeArchived;
  final ValueChanged<bool> onIncludeArchivedChanged;
  final String? status;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 4),
      child: Row(
        children: <Widget>[
          InkWell(
            key: const Key('inbox-include-archived'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => onIncludeArchivedChanged(!includeArchived),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Checkbox(
                    value: includeArchived,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (bool? value) =>
                        onIncludeArchivedChanged(value ?? false),
                  ),
                  Text('Archived', style: textTheme.labelMedium),
                ],
              ),
            ),
          ),
          Expanded(
            child: Text(
              status ?? '',
              key: const Key('inbox-search-status'),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: failed ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (failed)
            TextButton(
              key: const Key('inbox-search-retry'),
              onPressed: onRetry,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
