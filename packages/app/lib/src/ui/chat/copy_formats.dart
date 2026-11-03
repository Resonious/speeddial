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
  return nodes.map(_slack).join().trimRight();
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

String _slack(md.Node node) {
  if (node is! md.Element) return node.textContent;
  final String text = (node.children ?? <md.Node>[]).map(_slack).join();
  switch (node.tag) {
    case 'table':
      final List<List<String>> rows = tableRows(node)
          .map(
            (row) => row
                .map(
                  (cell) =>
                      _plain(cell).replaceAll('\n', ' ').replaceAll('`', 'ˋ'),
                )
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
      return '```\n${line(rows.first)}\n${widths.map((w) => '-' * w).join('-+-')}\n${rows.skip(1).map(line).join('\n')}\n```\n\n';
    case 'strong':
      return '*$text*';
    case 'em':
      return '_${text}_';
    case 'del':
      return '~$text~';
    case 'code':
      return '`$text`';
    case 'pre':
      return '```\n${_plain(node).trimRight().replaceAll('```', 'ˋˋˋ')}\n```\n\n';
    case 'a':
      final String href = node.attributes['href'] ?? '';
      return text == href ? text : '$text ($href)';
    case 'img':
      return node.attributes['alt'] ?? '';
    case 'br':
      return '\n';
    case 'p':
      return '$text\n\n';
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return '*$text*\n\n';
    case 'blockquote':
      return '${text.trimRight().split('\n').map((line) => '> $line').join('\n')}\n\n';
    case 'ul':
    case 'ol':
      int index = int.tryParse(node.attributes['start'] ?? '') ?? 1;
      return '${node.children!.map((item) {
        final String marker = node.tag == 'ol' ? '${index++}.' : '•';
        return '$marker ${_slack(item).trimRight()}';
      }).join('\n')}\n\n';
    case 'hr':
      return '────────\n\n';
    default:
      return text;
  }
}
