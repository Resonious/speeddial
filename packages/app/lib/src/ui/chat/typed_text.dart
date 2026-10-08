import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// One line of text that types itself out. When [text] changes it
/// backspaces to what the old and new text share, then types the rest.
///
/// [typeIn] types the first text out as well; otherwise that shows at once.
/// A caret in [caretColor] rides the end while it types. Under reduced
/// motion the text just changes.
class TypedText extends StatefulWidget {
  const TypedText(
    this.text, {
    super.key,
    this.style,
    this.typeIn = false,
    this.caretColor,
  });

  final String text;
  final TextStyle? style;
  final bool typeIn;
  final Color? caretColor;

  /// Typing pace, in characters a second; backspacing goes faster.
  static const double typeRate = 70;
  static const double eraseRate = 160;

  @override
  State<TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<TypedText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  /// The text being backspaced, while [_erasing].
  late String _from = widget.text;

  /// The text being typed.
  late String _to = widget.text;

  /// What [_from] and [_to] share; backspacing stops there.
  int _keep = 0;
  bool _erasing = false;

  /// Characters showing: of [_from] while erasing, of [_to] after.
  late double _shown = widget.typeIn ? 0 : widget.text.length.toDouble();
  Duration? _last;
  bool _still = false;

  bool get _busy => _erasing || _shown < _to.length;

  String get _visible => _erasing
      ? _from.substring(0, _shown.ceil().clamp(0, _from.length))
      : _to.substring(0, _shown.floor().clamp(0, _to.length));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(TypedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == _to) return;
    final String showing = _visible;
    _from = showing;
    _to = widget.text;
    _keep = _sharedPrefix(showing, _to);
    _erasing = showing.length > _keep;
    _shown = showing.length.toDouble();
    _sync();
  }

  void _sync() {
    if (_still) {
      _ticker.stop();
      _erasing = false;
      _shown = _to.length.toDouble();
      return;
    }
    if (_busy && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  static int _sharedPrefix(String a, String b) {
    final int length = a.length < b.length ? a.length : b.length;
    int i = 0;
    while (i < length && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  void _tick(Duration elapsed) {
    final Duration? last = _last;
    _last = elapsed;
    if (last == null) return;
    final double step =
        (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    final String before = _visible;
    if (_erasing) {
      _shown -= TypedText.eraseRate * step;
      if (_shown <= _keep) {
        _erasing = false;
        _shown = _keep.toDouble();
      }
    } else {
      _shown += TypedText.typeRate * step;
      if (_shown >= _to.length) _shown = _to.length.toDouble();
    }
    if (!_busy) _ticker.stop();
    if (_visible != before || !_busy) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color? caretColor = widget.caretColor;
    final Widget text = Text(
      _visible,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
    if (!_busy || caretColor == null) return text;
    final double height =
        (widget.style?.fontSize ?? 14) * (widget.style?.height ?? 1.2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(child: text),
        Container(
          width: 2,
          height: height,
          margin: const EdgeInsets.only(left: 1),
          decoration: BoxDecoration(
            color: caretColor,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    );
  }
}
