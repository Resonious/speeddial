import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Searches session titles and messages on every daemon at once for the
/// inbox rail. Owned by the inbox tab; each daemon's reply lands as soon as it
/// arrives so a slow daemon never holds back the others.
class InboxSearchStore extends StoreBase {
  InboxSearchStore(this._clientFor);

  /// Results per daemon. One page is enough for a rail filter; [truncated]
  /// says when a daemon had more.
  static const int pageSize = 100;

  final DaemonClient Function(String daemonId) _clientFor;
  String _query = '';
  bool _includeArchived = false;
  int _revision = 0;
  Map<String, List<SessionSearchResult>> _results =
      <String, List<SessionSearchResult>>{};
  final Set<String> _searching = <String>{};
  final Set<String> _indexing = <String>{};
  final Set<String> _truncated = <String>{};
  final Map<String, Object> _errors = <String, Object>{};

  String get query => _query;
  bool get includeArchived => _includeArchived;

  /// True when [query] is long enough for the daemons to search. Shorter
  /// queries are the caller's to filter locally.
  bool get canSearch =>
      _query.runes.length >= sessionSearchMinLength &&
      _query.length <= sessionSearchMaxLength &&
      !_query.contains('\u0000');

  /// daemonId → that daemon's matches, newest activity first.
  Map<String, List<SessionSearchResult>> get results => _results;
  bool get searching => _searching.isNotEmpty;

  /// Some daemon is still indexing older history; repeat the search.
  bool get indexing => _indexing.isNotEmpty;
  bool get truncated => _truncated.isNotEmpty;
  Map<String, Object> get errors => _errors;
  Object? errorFor(String daemonId) => _errors[daemonId];

  /// Updates the inputs and drops results that no longer apply. Callers then
  /// [search] (typically debounced).
  void update({String? query, bool? includeArchived}) {
    final String nextQuery = query?.trim() ?? _query;
    final bool nextArchived = includeArchived ?? _includeArchived;
    if (nextQuery == _query && nextArchived == _includeArchived) return;
    _query = nextQuery;
    _includeArchived = nextArchived;
    _revision++;
    _results = <String, List<SessionSearchResult>>{};
    _searching.clear();
    _indexing.clear();
    _truncated.clear();
    _errors.clear();
    notifyListeners();
  }

  /// Searches [daemonIds] in parallel. Each daemon's results and failure are
  /// recorded as it replies; the first failure is rethrown once all finish.
  Future<void> search(Iterable<String> daemonIds) async {
    if (!canSearch || isDisposed) return;
    final int revision = ++_revision;
    final Set<String> ids = daemonIds.toSet();
    _results = <String, List<SessionSearchResult>>{
      for (final MapEntry<String, List<SessionSearchResult>> entry
          in _results.entries)
        if (ids.contains(entry.key)) entry.key: entry.value,
    };
    _errors.removeWhere((String id, Object _) => !ids.contains(id));
    _indexing.removeWhere((String id) => !ids.contains(id));
    _truncated.removeWhere((String id) => !ids.contains(id));
    _searching
      ..clear()
      ..addAll(ids);
    notifyListeners();
    await Future.wait<void>(<Future<void>>[
      for (final String id in ids) _searchDaemon(id, revision),
    ]);
  }

  Future<void> _searchDaemon(String daemonId, int revision) async {
    try {
      final SessionSearchPage page = await _clientFor(daemonId).searchSessions(
        query: _query,
        includeArchived: _includeArchived,
        limit: pageSize,
      );
      if (isDisposed || revision != _revision) return;
      _results[daemonId] = page.results;
      _setFlag(_indexing, daemonId, page.indexing);
      _setFlag(_truncated, daemonId, page.nextCursor != null);
      _errors.remove(daemonId);
    } on Object catch (error) {
      if (!isDisposed && revision == _revision) {
        _errors[daemonId] = error;
        _indexing.remove(daemonId);
      }
      rethrow;
    } finally {
      if (!isDisposed && revision == _revision) {
        _searching.remove(daemonId);
        notifyListeners();
      }
    }
  }

  static void _setFlag(Set<String> flags, String daemonId, bool value) {
    if (value) {
      flags.add(daemonId);
    } else {
      flags.remove(daemonId);
    }
  }
}
