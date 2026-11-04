import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

enum CopyFormat {
  markdown('Copy Markdown'),
  html('Copy HTML'),
  slack('Copy for Slack'),
  csv('Copy as CSV');

  const CopyFormat(this.label);
  final String label;
}

String formatCopy(String source, CopyFormat format) {
  if (format == CopyFormat.markdown) return source;
  if (format == CopyFormat.html) {
    return md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
  }
  final List<md.Node> nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  if (format == CopyFormat.csv) {
    final md.Element table = nodes.whereType<md.Element>().firstWhere(
      (element) => element.tag == 'table',
    );
    return tableRows(table)
        .map(
          (row) => row
              .map((cell) {
                final String text = _plain(cell);
                return RegExp('[,"\\r\\n]').hasMatch(text)
                    ? '"${text.replaceAll('"', '""')}"'
                    : text;
              })
              .join(','),
        )
        .join('\r\n');
  }
  return nodes.map(_readableText).join().trimRight();
}

List<List<md.Node>> tableRows(md.Element table) => <List<md.Node>>[
  for (final md.Element section in table.children!.whereType<md.Element>())
    for (final md.Element row in section.children!.whereType<md.Element>())
      row.children ?? <md.Node>[],
];

String _plain(md.Node node) {
  if (node is! md.Element) return node.textContent;
  if (node.tag == 'br') return '\n';
  if (node.tag == 'img') return node.attributes['alt'] ?? '';
  return (node.children ?? <md.Node>[]).map(_plain).join();
}

/// Rich content for Slack's normal editor, plus a readable plain-text fallback.
/// Backtick fences are typing syntax, not a reliable clipboard interchange.
class SlackCopy {
  const SlackCopy({required this.text, required this.html});
  final String text;
  final String html;
}

SlackCopy formatSlackCopy(String source) {
  final List<md.Node> nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  return SlackCopy(
    text: nodes.map(_readableText).join().trimRight(),
    html: nodes.map(_richHtml).join(),
  );
}

String _tableText(md.Element table) {
  final List<List<String>> rows = tableRows(table)
      .map(
        (row) => row
            .map((cell) => _plain(cell).replaceAll(RegExp(r'[\r\n\t]+'), ' '))
            .toList(),
      )
      .toList();
  final List<int> widths = List<int>.filled(rows.first.length, 0);
  for (final List<String> row in rows) {
    for (int i = 0; i < row.length; i++) {
      if (row[i].runes.length > widths[i]) widths[i] = row[i].runes.length;
    }
  }
  String line(List<String> row) => <String>[
    for (int i = 0; i < row.length; i++)
      row[i] + ' ' * (widths[i] - row[i].runes.length),
  ].join(' | ').trimRight();
  return <String>[
    line(rows.first),
    widths.map((w) => '-' * w).join('-+-'),
    ...rows.skip(1).map(line),
  ].join('\n');
}

String _readableText(md.Node node) {
  if (node is! md.Element) return node.textContent;
  if (node.tag == 'table') return '${_tableText(node)}\n\n';
  if (node.tag == 'pre') return '${_plain(node).trimRight()}\n\n';
  final String text = (node.children ?? <md.Node>[]).map(_readableText).join();
  switch (node.tag) {
    case 'a':
      final String href = node.attributes['href'] ?? '';
      return text == href ? text : '$text ($href)';
    case 'img':
      return node.attributes['alt'] ?? '';
    case 'br':
      return '\n';
    case 'p':
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return '$text\n\n';
    case 'blockquote':
      return '${text.trimRight().split('\n').map((line) => '> $line').join('\n')}\n\n';
    case 'ul':
    case 'ol':
      int index = int.tryParse(node.attributes['start'] ?? '') ?? 1;
      return '${node.children!.map((item) {
        final String marker = node.tag == 'ol' ? '${index++}.' : '•';
        return '$marker ${_readableText(item).trimRight()}';
      }).join('\n')}\n\n';
    case 'hr':
      return '────────\n\n';
    default:
      return text;
  }
}

const HtmlEscape _escape = HtmlEscape(
  HtmlEscapeMode(escapeLtGt: true, escapeQuot: true, escapeApos: true),
);

String _richHtml(md.Node node) {
  if (node is! md.Element) return _escape.convert(node.textContent);
  // Slack supports preformatted blocks on paste. HTML tables can be flattened
  // by editors, so table columns belong in a real pre block, not literal fences.
  if (node.tag == 'table') {
    return '<pre>${_escape.convert(_tableText(node))}</pre>';
  }
  if (node.tag == 'pre') return '<pre>${_escape.convert(_plain(node))}</pre>';
  if (node.tag == 'img') return _escape.convert(node.attributes['alt'] ?? '');
  final String content = (node.children ?? <md.Node>[]).map(_richHtml).join();
  switch (node.tag) {
    case 'a':
      final String href = node.attributes['href'] ?? '';
      final Uri? uri = Uri.tryParse(href);
      if (uri == null ||
          !const <String>[
            'http',
            'https',
            'mailto',
          ].contains(uri.scheme.toLowerCase())) {
        return content;
      }
      return '<a href="${_escape.convert(href)}">$content</a>';
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return '<p><strong>$content</strong></p>';
    case 'p':
    case 'strong':
    case 'em':
    case 'code':
    case 'blockquote':
    case 'ul':
    case 'li':
      return '<${node.tag}>$content</${node.tag}>';
    case 'ol':
      final int start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
      return '<ol start="$start">$content</ol>';
    case 'del':
      return '<s>$content</s>';
    case 'br':
      return '<br>';
    case 'hr':
      return '<p>────────</p>';
    default:
      return content;
  }
}
