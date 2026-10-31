import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Optional client-local history capability; no daemon wire API is involved.
abstract interface class SavedHistoryClient {
  Future<({List<SessionEvent> events, bool hasMore, bool complete})?>
  savedHistory(String sessionId, {required int limit, int? beforeSeq});
}
