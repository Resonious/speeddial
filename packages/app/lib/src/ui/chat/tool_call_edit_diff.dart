/// Recognition of agent edit-tool payloads and line-diff computation.
///
/// Agents report file edits in many shapes: a typed ACP diff (old/new
/// content), a provider-computed numbered hunk block (Ante's
/// `details.diff`), a codex-style structured patch (sometimes a
/// string-encoded JSON value), an old/new snippet pair in the tool input, or
/// a bare unified diff string. This module normalizes all of them into
/// [ToolEditLine] lists so the card renders aligned, line-numbered hunks
/// instead of raw JSON.
///
/// Pure (protocol models only, no Flutter), so it stays unit-testable in
/// plain Dart.
library;

import 'dart:convert';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// One rendered line of an edit diff.
class ToolEditLine {
  const ToolEditLine(this.sign, this.text, {this.oldNum, this.newNum});

  /// '+', '-', ' ' for context, or '@' for header/marker lines.
  final String sign;

  /// Line content without the leading sign; descriptive text for markers.
  final String text;

  /// 1-based line number in the pre-edit file, or null when the line has no
  /// counterpart there.
  final int? oldNum;

  /// 1-based line number in the post-edit file, or null when the line has no
  /// counterpart there.
  final int? newNum;

  bool get isChange => sign == '+' || sign == '-';

  bool get isHeader => sign == '@';
}

/// A normalized file edit ready for rendering.
class ToolEditDiff {
  const ToolEditDiff({
    this.path,
    required this.lines,
    this.absorbsRawOutput = false,
  });

  /// File touched, when known (tool input, provider payload, or location).
  final String? path;

  final List<ToolEditLine> lines;

  /// True when the tool call's raw output is the same change already shown
  /// by [lines]; the card may then skip rendering the raw JSON again.
  final bool absorbsRawOutput;

  bool get isEmpty => lines.every((ToolEditLine line) => !line.isChange);

  int get additions =>
      lines.where((ToolEditLine line) => line.sign == '+').length;

  int get deletions =>
      lines.where((ToolEditLine line) => line.sign == '-').length;
}

const int _contextLines = 3;
const int _maxLcsCells = 250000;
const int _maxDiffInputLines = 1500;
const int _maxBlockLines = 400;
const int _maxPatchEntries = 50;
const int _maxTotalLines = 1500;

final RegExp _numberedLinePattern = RegExp(
  r'^(\s*|[-+])(\d+)\|(.*)$',
);
final RegExp _unifiedHunkPattern = RegExp(
  r'@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@',
);

/// Normalizes a tool call's edit payload into a line diff, or null when the
/// call carries nothing renderable as a diff (the card then falls back to
/// its raw payload views).
ToolEditDiff? extractEditDiffFromToolCall(ToolCall toolCall) {
  if (toolCall.kind != 'edit' &&
      toolCall.kind != 'write' &&
      toolCall.kind != 'create' &&
      toolCall.kind != 'delete') {
    return null;
  }

  final Map<Object?, Object?>? input =
      toolCall.rawInput is Map<Object?, Object?>
          ? toolCall.rawInput as Map<Object?, Object?>
          : null;
  final String? path = _inputPath(input) ??
      _outputPatchPath(toolCall.rawOutput) ??
      (toolCall.locations.length == 1 ? toolCall.locations.single : null);

  final ToolEditDiff? provider = _providerDiff(toolCall.rawOutput, path);
  if (provider != null) return provider;

  if (input != null) {
    final ToolEditDiff? derived =
        _oldNewDiff(input, path) ?? _unifiedInInput(input, path);
    if (derived != null) return derived;
  }
  return null;
}

/// Computes a line diff between two complete contents with up to three
/// context lines around each changed region.
///
/// Inputs too large for a safe LCS degrade to a capped whole-file
/// replacement so a card never spins.
List<ToolEditLine> diffFileLines(String oldText, String newText) {
  final List<String> oldLines = _splitFileLines(oldText);
  final List<String> newLines = _splitFileLines(newText);
  if (oldLines.isEmpty && newLines.isEmpty) return const <ToolEditLine>[];

  final int n = oldLines.length;
  final int m = newLines.length;
  if (n > _maxDiffInputLines ||
      m > _maxDiffInputLines ||
      n * m > _maxLcsCells) {
    return _wholeFileLines(oldLines, newLines);
  }

  // Classic LCS table: dp[i][j] = longest common subsequence of the first
  // i old lines and the first j new lines.
  final List<List<int>> dp =
      List.generate(n + 1, (int i) => List<int>.filled(m + 1, 0));
  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      dp[i][j] = oldLines[i - 1] == newLines[j - 1]
          ? dp[i - 1][j - 1] + 1
          : _maxInt(dp[i - 1][j], dp[i][j - 1]);
    }
  }

  // Back-track to mark which lines survived the edit.
  final List<bool> keepOld = List<bool>.filled(n, false);
  final List<bool> keepNew = List<bool>.filled(m, false);
  int i = n;
  int j = m;
  while (i > 0 && j > 0) {
    if (oldLines[i - 1] == newLines[j - 1]) {
      keepOld[i - 1] = true;
      keepNew[j - 1] = true;
      i--;
      j--;
    } else if (dp[i - 1][j] >= dp[i][j - 1]) {
      i--;
    } else {
      j--;
    }
  }

  // One entry per consumed line as (oldIndex, newIndex); a null side marks a
  // deletion or a pure addition.
  final List<(int?, int?)> ops = <(int?, int?)>[];
  i = 0;
  j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && keepOld[i] && keepNew[j] && oldLines[i] == newLines[j]) {
      ops.add((i, j));
      i++;
      j++;
    } else if (i < n && !keepOld[i]) {
      ops.add((i, null));
      i++;
    } else if (j < m && !keepNew[j]) {
      ops.add((null, j));
      j++;
    } else {
      // Defensive: kept lines exhausted out of alignment (cannot happen for
      // a coherent back-track, but never crash on it).
      if (i < n) {
        ops.add((i, null));
        i++;
      } else {
        ops.add((null, j));
        j++;
      }
    }
  }

  final List<int> changed = <int>[
    for (int k = 0; k < ops.length; k++)
      if (ops[k].$1 == null || ops[k].$2 == null) k,
  ];
  if (changed.isEmpty) return const <ToolEditLine>[];

  // Expand each change run by the context margin, merging runs whose
  // context windows touch so closely spaced edits read as one hunk.
  final List<ToolEditLine> lines = <ToolEditLine>[];
  int c = 0;
  while (c < changed.length) {
    int start = changed[c] - _contextLines;
    if (start < 0) start = 0;
    int end = changed[c] + _contextLines;
    if (end >= ops.length) end = ops.length - 1;
    while (c + 1 < changed.length &&
        changed[c + 1] - changed[c] <= 2 * _contextLines + 1) {
      c++;
      end = changed[c] + _contextLines;
      if (end >= ops.length) end = ops.length - 1;
    }
    c++;
    for (int k = start; k <= end; k++) {
      final (int? oldIndex, int? newIndex) = ops[k];
      if (oldIndex != null && newIndex != null) {
        lines.add(
          ToolEditLine(
            ' ',
            oldLines[oldIndex],
            oldNum: oldIndex + 1,
            newNum: newIndex + 1,
          ),
        );
      } else if (oldIndex != null) {
        lines.add(ToolEditLine('-', oldLines[oldIndex], oldNum: oldIndex + 1));
      } else {
        lines.add(ToolEditLine('+', newLines[newIndex!], newNum: newIndex + 1));
      }
    }
  }
  return _capLines(lines);
}

/// Parses a provider unified diff into numbered lines. Header lines
/// (`diff`, `---`, `+++`, `@@`) become '@' marker lines.
List<ToolEditLine> unifiedDiffLines(String text) {
  final List<ToolEditLine> lines = <ToolEditLine>[];
  int? oldCounter;
  int? newCounter;
  for (final String raw in _splitFileLines(text)) {
    if (raw.startsWith('@@')) {
      final RegExpMatch? match = _unifiedHunkPattern.firstMatch(raw);
      if (match != null) {
        oldCounter = (int.tryParse(match.group(1)!) ?? 1) - 1;
        newCounter = (int.tryParse(match.group(2)!) ?? 1) - 1;
      } else {
        oldCounter = null;
        newCounter = null;
      }
      lines.add(ToolEditLine('@', raw.trim()));
      continue;
    }
    if (raw.isEmpty) continue;
    if (raw.startsWith('diff ') ||
        raw.startsWith('index ') ||
        raw.startsWith('--- ') ||
        raw.startsWith('+++ ') ||
        raw.startsWith('new file') ||
        raw.startsWith('deleted file') ||
        raw.startsWith('similarity') ||
        raw.startsWith('rename ') ||
        raw.startsWith('old mode') ||
        raw.startsWith('new mode') ||
        raw.startsWith('Binary ')) {
      lines.add(ToolEditLine('@', raw.trim()));
      continue;
    }
    lines.add(_unifiedLine(raw, () => oldCounter, (int value) => oldCounter = value,
        () => newCounter, (int value) => newCounter = value));
  }
  return _capLines(lines);
}

ToolEditLine _unifiedLine(
  String raw,
  int? Function() peekOld,
  void Function(int) stepOld,
  int? Function() peekNew,
  void Function(int) stepNew,
) {
  final String sign = raw.startsWith('+')
      ? '+'
      : raw.startsWith('-')
          ? '-'
          : ' ';
  final String text = switch (sign) {
    '+' || '-' => raw.substring(1),
    _ => raw.startsWith(' ') ? raw.substring(1) : raw,
  };
  final int? oldNum = _step(peekOld(), stepOld, sign == '-' || sign == ' ');
  final int? newNum = _step(peekNew(), stepNew, sign == '+' || sign == ' ');
  return ToolEditLine(sign, text, oldNum: oldNum, newNum: newNum);
}

int? _step(int? current, void Function(int) step, bool take) {
  if (!take || current == null) return null;
  final int next = current + 1;
  step(next);
  return next;
}

List<ToolEditLine> _wholeFileLines(List<String> oldLines, List<String> newLines) {
  final List<ToolEditLine> lines = <ToolEditLine>[];
  for (int i = 0; i < oldLines.length; i++) {
    if (lines.length >= _maxBlockLines) {
      lines.add(
        ToolEditLine(' ', '… ${oldLines.length - _maxBlockLines} more lines omitted'),
      );
      break;
    }
    lines.add(ToolEditLine('-', oldLines[i], oldNum: i + 1));
  }
  for (int i = 0; i < newLines.length; i++) {
    final int added = lines.length - oldLines.length;
    if (added >= _maxBlockLines) {
      lines.add(
        ToolEditLine(' ', '… ${newLines.length - _maxBlockLines} more lines omitted'),
      );
      break;
    }
    lines.add(ToolEditLine('+', newLines[i], newNum: i + 1));
  }
  return _capLines(lines);
}

/// Leading/head-truncates a line list, with an omission marker in between.
List<ToolEditLine> _capLines(List<ToolEditLine> lines) {
  if (lines.length <= _maxTotalLines) return lines;
  const int headCount = 750;
  const int tailCount = 200;
  final int omitted = lines.length - headCount - tailCount;
  return <ToolEditLine>[
    ...lines.take(headCount),
    ToolEditLine(' ', '… $omitted lines omitted'),
    ...lines.skip(lines.length - tailCount),
  ];
}

// ---------------------------------------------------------------------------
// Provider (output-side) payload shapes
// ---------------------------------------------------------------------------

ToolEditDiff? _providerDiff(Object? rawOutput, String? path) {
  if (rawOutput is! Map<Object?, Object?>) return null;

  // Ante: {content: [...], details: {path?, diff: "N|…\n- N|…"}}.
  final Object? details = rawOutput['details'];
  if (details is Map<Object?, Object?>) {
    final String? detailsPath =
        _firstString(details, const ['path', 'file_path', 'filePath']) ?? path;
    final ToolEditDiff? fromDetails = _structuredPatchValue(
      details['diff'] ?? details['patch'] ?? details['changes'],
      detailsPath,
    );
    if (fromDetails != null) return fromDetails;
  }

  final ToolEditDiff? structured =
      _structuredPatchValue(_rawPatchValue(rawOutput), path);
  if (structured != null) return structured;

  // {old_lines: [...], new_lines: [...]} — two signed text columns.
  final List<Object?> oldLines =
      _stringListAt(rawOutput, const ['old_lines', 'oldLines']);
  final List<Object?> newLines =
      _stringListAt(rawOutput, const ['new_lines', 'newLines']);
  if (oldLines.isNotEmpty || newLines.isNotEmpty) {
    final List<ToolEditLine> lines = <ToolEditLine>[
      for (final Object? row in oldLines.take(_maxBlockLines))
        if (row is String) ToolEditLine('-', _stripSign(row)),
      for (final Object? row in newLines.take(_maxBlockLines))
        if (row is String) ToolEditLine('+', _stripSign(row)),
    ];
    if (lines.any((ToolEditLine line) => line.isChange)) {
      return ToolEditDiff(
        path: _firstString(
          rawOutput,
          const ['path', 'file_path', 'filePath'],
        ) ??
            path,
        lines: lines,
        absorbsRawOutput: true,
      );
    }
  }
  return null;
}

Object? _rawPatchValue(Map<Object?, Object?> rawOutput) =>
    rawOutput['patch'] ??
    rawOutput['changes'] ??
    rawOutput['diff'] ??
    rawOutput['unified_diff'] ??
    rawOutput['unifiedDiff'] ??
    rawOutput['patch_text'];

/// Parses a structural patch value: a string-encoded JSON patch, a unified
/// diff string, a `{hunks: [...]}` map, or a list of file/hunk entries.
ToolEditDiff? _structuredPatchValue(Object? value, String? path) {
  if (value is String) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        return null;
      }
      return _structuredPatchValue(decoded, path);
    }
    if (_looksLikeNumberedHunks(trimmed)) {
      final List<ToolEditLine> lines = _numberedHunks(trimmed);
      if (lines.any((ToolEditLine line) => line.isChange)) {
        return ToolEditDiff(path: path, lines: lines, absorbsRawOutput: true);
      }
    }
    if (_looksLikeUnifiedDiff(trimmed)) {
      final List<ToolEditLine> lines = unifiedDiffLines(trimmed);
      if (lines.any((ToolEditLine line) => line.isChange)) {
        return ToolEditDiff(path: path, lines: lines, absorbsRawOutput: true);
      }
    }
    return null;
  }
  if (value is Map<Object?, Object?>) {
    final String? mapPath =
        _firstString(value, const ['path', 'file_path', 'filePath']) ?? path;
    if (value['diff'] is String) {
      final ToolEditDiff? nested = _structuredPatchValue(value['diff'], mapPath);
      if (nested != null) return nested;
    }
    return _patchHunks(
      value['hunks'] ?? value['changes'] ?? value['chunks'],
      mapPath,
    );
  }
  if (value is List<Object?>) {
    final List<ToolEditLine> lines = <ToolEditLine>[];
    String? outPath = path;
    for (final Object? entry in value.take(_maxPatchEntries)) {
      if (entry is Map<Object?, Object?>) {
        outPath ??= _firstString(entry, const ['path', 'file_path', 'filePath']);
        final ToolEditDiff? hunkDiff = _patchHunks(
          entry['hunks'] is List ? entry['hunks'] : <Object?>[entry],
          outPath,
        );
        if (hunkDiff != null) lines.addAll(hunkDiff.lines);
      } else if (entry is String) {
        final String sign = _inferSign(entry);
        if (sign != '@') lines.add(ToolEditLine(sign, _stripSign(entry)));
      }
    }
    if (lines.any((ToolEditLine line) => line.isChange)) {
      return ToolEditDiff(
        path: outPath,
        lines: _capLines(lines),
        absorbsRawOutput: true,
      );
    }
    return null;
  }
  return null;
}

ToolEditDiff? _patchHunks(Object? hunks, String? path) {
  if (hunks is! List<Object?> || hunks.isEmpty) return null;
  final List<ToolEditLine> parsed = <ToolEditLine>[];
  for (final Object? entry in hunks.take(_maxPatchEntries)) {
    parsed.addAll(_parseHunkEntry(entry));
  }
  final List<ToolEditLine> lines = _capLines(parsed);
  if (lines.any((ToolEditLine line) => line.isChange)) {
    return ToolEditDiff(path: path, lines: lines, absorbsRawOutput: true);
  }
  return null;
}

List<ToolEditLine> _parseHunkEntry(Object? entry) {
  if (entry is! Map<Object?, Object?>) return const <ToolEditLine>[];
  final Object? rawLines = entry['lines'] ?? entry['rows'] ?? entry['items'];
  if (rawLines is! List || rawLines.isEmpty) return const <ToolEditLine>[];

  int? oldCounter = _lineNumber(
    entry['old_start'] ?? entry['oldStart'] ?? entry['orig_start'] ?? entry['start'],
  );
  int? newCounter = _lineNumber(
    entry['new_start'] ?? entry['newStart'] ?? entry['new_line_start'],
  );
  if (oldCounter != null) oldCounter--;
  if (newCounter != null) newCounter--;

  final List<ToolEditLine> lines = <ToolEditLine>[];
  for (final Object? row in rawLines.take(_maxBlockLines)) {
    String sign;
    String text;
    if (row is String) {
      sign = _inferSign(row);
      text = switch (sign) {
        '+' || '-' => row.substring(1),
        _ => row.startsWith(' ') ? row.substring(1) : row,
      };
    } else if (row is Map<Object?, Object?>) {
      final String? rowText = _firstString(row, const ['text', 'line', 'content']);
      if (rowText == null) continue;
      text = rowText;
      sign = _classifySign(
        _firstString(row, const ['sign', 'prefix', 'type', 'change', 'kind']),
      ) ??
          _inferSign(rowText);
    } else {
      continue;
    }
    final int? oldNum =
        (sign == '-' || sign == ' ') && oldCounter != null
            ? ++oldCounter
            : null;
    final int? newNum =
        (sign == '+' || sign == ' ') && newCounter != null
            ? ++newCounter
            : null;
    lines.add(ToolEditLine(sign, text, oldNum: oldNum, newNum: newNum));
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Ante numbered hunk blocks ("N|", "-N|", "+N|" lines, blanks = gaps)
// ---------------------------------------------------------------------------

bool _looksLikeNumberedHunks(String text) {
  bool sawLine = false;
  for (final String line in _splitFileLines(text).take(20)) {
    if (line.trim().isEmpty) continue;
    sawLine = true;
    if (!_numberedLinePattern.hasMatch(line)) return false;
  }
  return sawLine;
}

List<ToolEditLine> _numberedHunks(String text) {
  final List<ToolEditLine> out = <ToolEditLine>[];
  // Context lines carry the post-edit line number; the pre-edit number is
  // tracked via the cumulative add/delta of the block so far, which survives
  // blank separators between hunk blocks.
  int delta = 0;
  int? lastOld;
  int? lastNew;
  for (final String raw in _splitFileLines(text)) {
    if (raw.trim().isEmpty) {
      // A blank context line: counts as one line in both files, but is
      // skipped when its number is far from the surrounding lines (the
      // provider separates non-contiguous blocks with blank lines).
      if (lastNew != null && lastOld != null) {
        final int nextNew = lastNew + 1;
        if (nextNew <= lastOld + delta) {
          out.add(ToolEditLine(
            ' ',
            '',
            oldNum: lastOld + 1,
            newNum: nextNew,
          ));
          lastOld = lastOld + 1;
          lastNew = nextNew;
        }
      }
      continue;
    }
    final RegExpMatch? match = _numberedLinePattern.firstMatch(raw);
    if (match == null) {
      out.add(ToolEditLine(' ', raw));
      continue;
    }
    final int n = int.parse(match.group(2)!);
    final String lineText = match.group(3) ?? '';
    final String sign = switch (match.group(1)) {
      '+' => '+',
      '-' => '-',
      _ => ' ',
    };
    final int? oldNum;
    final int? newNum;
    if (sign == '-') {
      oldNum = n;
      newNum = null;
      delta--;
    } else if (sign == '+') {
      newNum = n;
      oldNum = null;
      delta++;
    } else {
      newNum = n;
      oldNum = (n - delta) > 0 ? n - delta : null;
    }
    if (out.isNotEmpty) {
      final int omitted = _gapSize(lastOld, lastNew, oldNum, newNum);
      if (omitted > 0) {
        out.add(ToolEditLine(' ', '… $omitted lines omitted'));
      }
    }
    lastOld = oldNum ?? lastOld;
    lastNew = newNum ?? lastNew;
    out.add(ToolEditLine(sign, lineText, oldNum: oldNum, newNum: newNum));
  }
  return _capLines(out);
}

int _gapSize(int? aOld, int? aNew, int? bOld, int? bNew) {
  int omitted = 0;
  if (aOld != null && bOld != null && bOld > aOld) {
    omitted = bOld - aOld - 1;
  }
  if (aNew != null && bNew != null && bNew > aNew) {
    omitted = _maxInt(omitted, bNew - aNew - 1);
  }
  return omitted;
}

// ---------------------------------------------------------------------------
// Input-side (old/new snippets, unified strings)
// ---------------------------------------------------------------------------

ToolEditDiff? _oldNewDiff(Map<Object?, Object?> input, String? path) {
  final String? oldText = _firstString(
    input,
    const [
      'old_string',
      'oldString',
      'old_text',
      'oldText',
      'before',
      'original',
      'original_content',
      'original_text',
      'old_file',
      'oldFileContent',
    ],
  );
  final String? newText = _firstString(
    input,
    const [
      'new_string',
      'newString',
      'new_text',
      'newText',
      'after',
      'replacement',
      'content',
      'file_content',
      'new_file',
      'newFileContent',
    ],
  );
  if (oldText == null && newText == null) return null;
  final List<ToolEditLine> lines = diffFileLines(oldText ?? '', newText ?? '');
  if (lines.every((ToolEditLine line) => !line.isChange)) return null;
  return ToolEditDiff(path: path, lines: lines);
}

ToolEditDiff? _unifiedInInput(Map<Object?, Object?> input, String? path) {
  final String? value = _firstString(
    input,
    const ['diff', 'unified_diff', 'unifiedDiff', 'patch', 'patch_text'],
  );
  if (value == null || !_looksLikeUnifiedDiff(value)) return null;
  final List<ToolEditLine> lines = unifiedDiffLines(value);
  if (lines.every((ToolEditLine line) => !line.isChange)) return null;
  return ToolEditDiff(path: path, lines: lines);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String? _inputPath(Map<Object?, Object?>? input) => input == null
    ? null
    : _firstString(
        input,
        const ['file_path', 'path', 'filePath', 'file', 'file_name', 'fileName'],
      );

/// Path of a structured provider patch (`patch: {path}` / `patch: [{path}]`),
/// looking inside a `details` wrapper as well.
String? _outputPatchPath(Object? rawOutput) {
  if (rawOutput is! Map<Object?, Object?>) return null;
  final Object? details = rawOutput['details'];
  if (details is Map<Object?, Object?>) {
    final String? inner = _patchValuePath(details);
    if (inner != null) return inner;
  }
  return _patchValuePath(_rawPatchValue(rawOutput));
}

String? _patchValuePath(Object? value) {
  if (value is Map<Object?, Object?>) {
    return _firstString(value, const ['path', 'file_path', 'filePath']);
  }
  if (value is List<Object?> && value.isNotEmpty && value.first is Map) {
    return _firstString(
      (value.first as Map<Object?, Object?>),
      const ['path', 'file_path', 'filePath'],
    );
  }
  return null;
}

String? _firstString(Map<Object?, Object?> map, List<String> keys) {
  for (final String key in keys) {
    final Object? value = map[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

List<Object?> _stringListAt(Object? rawOutput, List<String> keys) {
  if (rawOutput is! Map<Object?, Object?>) return const <Object?>[];
  for (final String key in keys) {
    final Object? value = rawOutput[key];
    if (value is List &&
        value.every((Object? item) => item is String || item == null)) {
      return value.whereType<String>().toList();
    }
  }
  return const <Object?>[];
}

int? _lineNumber(Object? value) {
  if (value is! num) return null;
  final int line = value.toInt();
  return line < 1 ? null : line;
}

/// '+' / '-' for signed lines, ' ' for everything else; `---` file headers
/// count as context, not as deleted lines.
String _inferSign(String line) {
  if (line.startsWith('+')) return '+';
  if (line.startsWith('-') && !line.startsWith('---')) return '-';
  return ' ';
}

String? _classifySign(String? value) {
  switch (value?.toLowerCase()) {
    case '+':
    case 'add':
    case 'added':
    case 'insert':
    case 'insertion':
      return '+';
    case '-':
    case 'del':
    case 'delete':
    case 'deleted':
    case 'remove':
    case 'removed':
      return '-';
    case ' ':
    case 'context':
    case 'ctx':
    case 'unchanged':
    case 'keep':
      return ' ';
    default:
      return null;
  }
}

String _stripSign(String line) {
  if (line.isEmpty) return line;
  final String first = line[0];
  return (first == '+' || first == '-') ? line.substring(1) : line;
}

bool _looksLikeUnifiedDiff(String value) {
  var hasHeader = false;
  var hasBody = false;
  for (final String line in value.split('\n').take(60)) {
    if (line.startsWith('--- ') ||
        line.startsWith('+++ ') ||
        line.startsWith('@@') ||
        line.startsWith('diff ')) {
      hasHeader = true;
    } else if (line.startsWith('+') || line.startsWith('-')) {
      hasBody = true;
    }
    if (hasHeader && hasBody) return true;
  }
  return hasHeader || hasBody;
}

List<String> _splitFileLines(String text) {
  final String normalized =
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.isEmpty) return <String>[];
  final List<String> lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

int _maxInt(int a, int b) => a >= b ? a : b;