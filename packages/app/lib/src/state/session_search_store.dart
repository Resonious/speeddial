import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Short-lived state owned by a search dialog, scoped to one daemon.
class SessionSearchStore extends StoreBase {
  SessionSearchStore(this._client);

  final DaemonClient _client;
  String _query = '';
  bool _includeArchived = false;
  int _revision = 0;
  List<SessionSearchResult> _results = const <SessionSearchResult>[];
  SessionSearchCursor? _cursor;
  bool _loading = false;
  bool _indexing = false;
  Object? _lastError;

  String get query => _query;
  bool get includeArchived => _includeArchived;
  List<SessionSearchResult> get results => _results;
  bool get hasMore => _cursor != null;
  bool get loading => _loading;
  bool get indexing => _indexing;
  Object? get lastError => _lastError;
  bool get canSearch =>
      _query.runes.length >= sessionSearchMinLength &&
      _query.length <= sessionSearchMaxLength &&
      !_query.contains('\u0000');

  void update({String? query, bool? includeArchived}) {
    final String nextQuery = query?.trim() ?? _query;
    final bool nextArchived = includeArchived ?? _includeArchived;
    if (nextQuery == _query && nextArchived == _includeArchived) return;
    _query = nextQuery;
    _includeArchived = nextArchived;
    _revision++;
    _results = const <SessionSearchResult>[];
    _cursor = null;
    _indexing = false;
    _lastError = null;
    _loading = canSearch;
    notifyListeners();
  }

  Future<void> search({bool more = false}) async {
    if (!canSearch || isDisposed || more && _cursor == null) return;
    final int revision = ++_revision;
    _loading = true;
    _lastError = null;
    notifyListeners();
    try {
      final SessionSearchPage page = await _client.searchSessions(
        query: _query,
        includeArchived: _includeArchived,
        cursor: more ? _cursor : null,
      );
      if (isDisposed || revision != _revision) return;
      // Sessions can change activity between pages. Preserve uniqueness when
      // a result crosses the cursor while the dialog is open.
      final Set<String> seen = more
          ? _results.map((SessionSearchResult r) => r.session.id).toSet()
          : <String>{};
      _results = List<SessionSearchResult>.unmodifiable(<SessionSearchResult>[
        if (more) ..._results,
        ...page.results.where(
          (SessionSearchResult r) => seen.add(r.session.id),
        ),
      ]);
      _cursor = page.nextCursor;
      _indexing = page.indexing;
    } on Object catch (error) {
      if (!isDisposed && revision == _revision) _lastError = error;
      rethrow;
    } finally {
      if (!isDisposed && revision == _revision) {
        _loading = false;
        notifyListeners();
      }
    }
  }
}
