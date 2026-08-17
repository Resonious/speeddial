/// Human-readable / JSON output helpers for the `speeddial` CLI.
///
/// Every command renders through an [Output]: aligned tables and `key: value`
/// records for humans, and - with the global `--json` flag - the raw RPC
/// result objects. The pure render functions ([renderTable], [renderRecord],
/// [jsonEncodePretty]) are unit-testable without a terminal.
library;

import 'dart:convert';
import 'dart:io';

/// Maximum displayed cell width in human tables; longer cells are truncated.
const int _maxCellWidth = 80;

/// Renders an aligned text table: a header row followed by [rows], each
/// column padded to the widest cell in it.
String renderTable(List<String> headers, List<List<String>> rows) {
  final columns = headers.length;
  final widths = <int>[];
  for (var c = 0; c < columns; c++) {
    var width = headers[c].length;
    for (final row in rows) {
      if (c < row.length) {
        final length = _displayCell(row[c]).length;
        if (length > width) width = length;
      }
    }
    widths.add(width);
  }

  String line(List<String> cells) {
    final buffer = StringBuffer();
    for (var c = 0; c < columns; c++) {
      if (c > 0) buffer.write('  ');
      buffer.write((c < cells.length ? _displayCell(cells[c]) : '').padRight(widths[c]));
    }
    return buffer.toString().trimRight();
  }

  final buffer = StringBuffer();
  buffer.writeln(line(headers));
  for (final row in rows) {
    buffer.writeln(line(row));
  }
  return buffer.toString().trimRight();
}

/// Renders a single record as `key: value` lines with aligned keys.
String renderRecord(Map<String, Object?> record) {
  final entries = record.entries.toList(growable: false);
  var keyWidth = 0;
  for (final entry in entries) {
    if (entry.key.length > keyWidth) keyWidth = entry.key.length;
  }
  return entries
      .map((entry) => '${entry.key.padRight(keyWidth)}  ${entry.value}')
      .join('\n');
}

/// Encodes [value] as indented JSON (the `--json` output form).
String jsonEncodePretty(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

/// Formats command results: aligned tables for humans, raw JSON with `--json`.
class Output {
  Output({required bool json, StringSink? sink, void Function()? onFlush})
      : _json = json, // ignore: prefer_initializing_formals — public param `json` != private field `_json`
        _sink = sink ?? stdout,
        _onFlush = onFlush ?? _noopFlush;

  static void _noopFlush() {}

  final bool _json;
  final StringSink _sink;
  final void Function() _onFlush;

  /// Prints [headers]/[rows] as an aligned table; with `--json` prints a JSON
  /// array of objects keyed by the headers instead.
  void table(List<String> headers, List<List<String>> rows) {
    if (_json) {
      raw([
        for (final row in rows)
          {for (var c = 0; c < headers.length; c++) headers[c]: row[c]},
      ]);
      return;
    }
    _sink.writeln(renderTable(headers, rows));
  }

  /// Prints a single record as aligned `key: value` lines; with `--json`
  /// prints it as a JSON object.
  void record(Map<String, Object?> record) {
    if (_json) {
      raw(record);
      return;
    }
    _sink.writeln(renderRecord(record));
  }

  /// Prints [value] as JSON (the `--json` output form). Kept public for
  /// commands that stream raw results (e.g. `attach`).
  void raw(Object? value) => _sink.writeln(jsonEncodePretty(value));

  /// Prints a plain text line.
  void line(String text) => _sink.writeln(text);

  /// Writes raw text without adding a newline (used for multi-line bodies
  /// such as unified diffs).
  void write(String text) => _sink.write(text);

  /// Flushes the underlying sink; needed for long-running streaming output.
  void flush() => _onFlush();
}

String _displayCell(String value) => value.length <= _maxCellWidth
    ? value
    : '${value.substring(0, _maxCellWidth)}…';
