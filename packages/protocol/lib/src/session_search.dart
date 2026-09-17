import 'models.dart';

const int sessionSearchMinLength = 3;
const int sessionSearchMaxLength = 256;

/// A keyset boundary in newest-activity-first search results.
class SessionSearchCursor {
  const SessionSearchCursor({required this.lastActivityAt, required this.id});

  factory SessionSearchCursor.fromJson(Map<String, Object?> json) =>
      SessionSearchCursor(
        lastActivityAt: DateTime.parse(json['lastActivityAt'] as String)
            .toUtc(),
        id: json['id'] as String,
      );

  final DateTime lastActivityAt;
  final String id;

  Map<String, Object?> toJson() => <String, Object?>{
    'lastActivityAt': lastActivityAt.toUtc().toIso8601String(),
    'id': id,
  };
}

class SessionSearchResult {
  const SessionSearchResult({
    required this.session,
    required this.projectName,
    required this.excerpt,
  });

  factory SessionSearchResult.fromJson(Map<String, Object?> json) =>
      SessionSearchResult(
        session: Session.fromJson(json['session'] as Map<String, Object?>),
        projectName: json['projectName'] as String?,
        excerpt: json['excerpt'] as String,
      );

  final Session session;
  final String? projectName;
  final String excerpt;

  Map<String, Object?> toJson() => <String, Object?>{
    'session': session.toJson(),
    'projectName': projectName,
    'excerpt': excerpt,
  };
}

class SessionSearchPage {
  const SessionSearchPage({
    required this.results,
    this.nextCursor,
    this.indexing = false,
  });

  factory SessionSearchPage.fromJson(Map<String, Object?> json) =>
      SessionSearchPage(
        results: (json['results'] as List<Object?>)
            .map(
              (Object? value) =>
                  SessionSearchResult.fromJson(value as Map<String, Object?>),
            )
            .toList(growable: false),
        nextCursor: json['nextCursor'] == null
            ? null
            : SessionSearchCursor.fromJson(
                json['nextCursor'] as Map<String, Object?>,
              ),
        indexing: json['indexing'] as bool? ?? false,
      );

  final List<SessionSearchResult> results;
  final SessionSearchCursor? nextCursor;

  /// Results may be incomplete while previously stored messages are indexed.
  final bool indexing;

  Map<String, Object?> toJson() => <String, Object?>{
    'results': results.map((SessionSearchResult r) => r.toJson()).toList(),
    'nextCursor': nextCursor?.toJson(),
    'indexing': indexing,
  };
}

/// A bounded, plain-text window around a literal match (never HTML).
String sessionSearchExcerpt(String text, String query) {
  final int match = text.toLowerCase().indexOf(query.toLowerCase());
  final int start = _characterBoundary(text, match > 60 ? match - 60 : 0);
  final int end = _characterBoundary(text, (start + 320).clamp(0, text.length));
  return '${start > 0 ? '…' : ''}'
      '${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}'
      '${end < text.length ? '…' : ''}';
}

int _characterBoundary(String text, int offset) =>
    offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff
    ? offset - 1
    : offset;
