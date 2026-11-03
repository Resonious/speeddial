import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/chat_store.dart';

/// The last frame of the session being left, held over the pane until the
/// session being opened has something to show, then faded straight into it.
/// A switch therefore never passes through an empty pane, and the new
/// session appears once, whole.
class SessionHandoff extends StatefulWidget {
  const SessionHandoff({
    super.key,
    required this.image,
    required this.chat,
    required this.sessionId,
    required this.onDone,
  });

  final ui.Image image;
  final ChatStore chat;
  final String sessionId;

  /// The fade finished; the owner can drop the frame and dispose [image].
  final VoidCallback onDone;

  /// Longest the old frame stays up; past this the pane shows its own
  /// loading state, which by then is worth seeing.
  static const Duration maxHold = Duration(milliseconds: 400);

  @override
  State<SessionHandoff> createState() => _SessionHandoffState();
}

class _SessionHandoffState extends State<SessionHandoff>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    value: 1,
  )..addStatusListener(_onStatus);
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _shown,
    curve: Curves.easeOut,
  );
  Timer? _limit;

  @override
  void initState() {
    super.initState();
    _limit = Timer(SessionHandoff.maxHold, _release);
    widget.chat.addListener(_check);
    _check();
  }

  void _check() {
    final bool ready =
        widget.chat.historyStatusFor(widget.sessionId) !=
            HistoryStatus.loading ||
        widget.chat.eventViewFor(widget.sessionId).isNotEmpty;
    if (ready) _release();
  }

  void _release() {
    _limit?.cancel();
    widget.chat.removeListener(_check);
    if (mounted && _shown.isCompleted) _shown.reverse();
  }

  void _onStatus(AnimationStatus status) {
    if (status.isDismissed) widget.onDone();
  }

  @override
  void dispose() {
    _limit?.cancel();
    widget.chat.removeListener(_check);
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: FadeTransition(
      key: const Key('session-handoff'),
      opacity: _opacity,
      child: RawImage(image: widget.image, fit: BoxFit.fill),
    ),
  );
}
