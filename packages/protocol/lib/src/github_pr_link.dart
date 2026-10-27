/// A github.com PR URL, normalized before passing it to the GitHub CLI.
class GithubPrLink {
  const GithubPrLink._(this.url);
  final String url;

  static GithubPrLink? parse(String text) {
    final Uri? uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    final List<String> parts;
    try {
      parts = uri.pathSegments;
    } on FormatException {
      return null;
    }
    if (parts.length < 4 ||
        parts[2] != 'pull' ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(parts[3]) ||
        !parts
            .take(2)
            .every((part) => RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part))) {
      return null;
    }
    return GithubPrLink._('https://github.com/${parts.take(4).join('/')}');
  }
}
