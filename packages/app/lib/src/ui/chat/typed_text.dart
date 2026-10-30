import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The typing behind [TypedText], for surfaces that aren't a Flutter
/// widget (the native title bar). When [retarget]ed it backspaces to what
/// the old and new text share, then types the rest; [advance] moves it on.
class TextTyper {
  TextTyper(String text, {bool typeIn = false})
    : _from = text,
      _to = text,
      _shown = typeIn ? 0 : text.length.toDouble();

  /// The text being backspaced, while [_erasing].
  String _from;

  /// The text being typed.
  String _to;

  /// What [_from] and [_to] share; backspacing stops there.
  int _keep = 0;
  bool _erasing = false;

  /// Characters showing: of [_from] while erasing, of [_to] after.
  double _shown;

  String get target => _to;
  bool get busy => _erasing || _shown < _to.length;

  String get visible => _erasing
      ? _from.substring(0, _shown.ceil().clamp(0, _from.length))
      : _to.substring(0, _shown.floor().clamp(0, _to.length));

  /// Starts heading for [text] from whatever shows now.
  void retarget(String text) {
    if (text == _to) return;
    final String showing = visible;
    _from = showing;
    _to = text;
    _keep = _sharedPrefix(showing, _to);
    _erasing = showing.length > _keep;
    _shown = showing.length.toDouble();
  }

  /// Jumps straight to the target.
  void finish() {
    _erasing = false;
    _shown = _to.length.toDouble();
  }

  /// Moves on by [seconds]; returns whether [visible] changed.
  bool advance(double seconds, {double typeRate = 70, double eraseRate = 160}) {
    final String before = visible;
    if (_erasing) {
      _shown -= eraseRate * seconds;
      if (_shown <= _keep) {
        _erasing = false;
        _shown = _keep.toDouble();
      }
    } else {
      _shown += typeRate * seconds;
      if (_shown >= _to.length) _shown = _to.length.toDouble();
    }
    return visible != before;
  }

  static int _sharedPrefix(String a, String b) {
    final int length = a.length < b.length ? a.length : b.length;
    int i = 0;
    while (i < length && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }
}

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
    this.typeRate = defaultTypeRate,
    this.eraseRate = defaultEraseRate,
  });

  final String text;
  final TextStyle? style;
  final bool typeIn;
  final Color? caretColor;

  /// Typing pace, in characters a second; backspacing goes faster.
  final double typeRate;
  final double eraseRate;

  static const double defaultTypeRate = 70;
  static const double defaultEraseRate = 160;

  @override
  State<TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<TypedText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final TextTyper _typer = TextTyper(widget.text, typeIn: widget.typeIn);
  Duration? _last;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(TypedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == _typer.target) return;
    _typer.retarget(widget.text);
    _sync();
  }

  void _sync() {
    if (_still) {
      _ticker.stop();
      _typer.finish();
      return;
    }
    if (_typer.busy && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final Duration? last = _last;
    _last = elapsed;
    if (last == null) return;
    final double step =
        (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    final bool changed = _typer.advance(
      step,
      typeRate: widget.typeRate,
      eraseRate: widget.eraseRate,
    );
    final bool busy = _typer.busy;
    if (!busy) _ticker.stop();
    if (changed || !busy) setState(() {});
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
      _typer.visible,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
    if (!_typer.busy || caretColor == null) return text;
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
