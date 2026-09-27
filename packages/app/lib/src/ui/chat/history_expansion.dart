// Keep the usual animation for short details. Long text collapses at once so
// its fading body cannot leave a large empty gap in the timeline.
const int _maxAnimatedCharacters = 800;
const int _maxAnimatedLines = 12;

bool animateHistoryText(String text) {
  if (text.length > _maxAnimatedCharacters) return false;
  int lineBreaks = 0;
  for (int i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10 && ++lineBreaks >= _maxAnimatedLines) {
      return false;
    }
  }
  return true;
}

bool animateHistoryDetails(Iterable<String> details) {
  int characters = 0;
  int lineBreaks = 0;
  for (final String detail in details) {
    characters += detail.length;
    if (characters > _maxAnimatedCharacters) return false;
    if (++lineBreaks > _maxAnimatedLines) return false;
    for (int i = 0; i < detail.length; i++) {
      if (detail.codeUnitAt(i) == 10 && ++lineBreaks > _maxAnimatedLines) {
        return false;
      }
    }
  }
  return true;
}
