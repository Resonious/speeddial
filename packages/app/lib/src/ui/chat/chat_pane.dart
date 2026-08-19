import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/chat_store.dart';
import 'composer.dart';
import 'permission_banner.dart';
import 'timeline.dart';

/// Center pane: the selected session's timeline, pending permission banner and
/// composer. Tracks `selection.selectedSessionId` via [AppScope]; watching a
/// session subscribes the [ChatStore] to its live event stream.
class ChatPane extends StatefulWidget {
  const ChatPane({super.key});

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  AppData? _data;
  String? _watchedDaemonId;
  String? _watchedSessionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppData data = AppScope.of(context);
    if (!identical(_data, data)) {
      _data?.selection.removeListener(_onSelectionChanged);
      _data = data;
      // Selection changes are plain store notifications (not inherited-widget
      // changes), so didChangeDependencies alone would miss re-watching a
      // newly selected session; listen directly for those transitions.
      data.selection.addListener(_onSelectionChanged);
    }
    _syncWatch(
      data.chat,
      data.selection.selectedDaemonId,
      data.selection.selectedSessionId,
    );
  }

  void _onSelectionChanged() {
    final AppData? data = _data;
    if (data == null || !mounted) return;
    _syncWatch(
      data.chat,
      data.selection.selectedDaemonId,
      data.selection.selectedSessionId,
    );
  }

  @override
  void dispose() {
    _data?.selection.removeListener(_onSelectionChanged);
    final String? watched = _watchedSessionId;
    if (watched != null) {
      _data?.chat.unwatch(watched);
    }
    super.dispose();
  }

  /// Keeps exactly one session watched, unwatching any previous one.
  void _syncWatch(ChatStore chat, String? daemonId, String? sessionId) {
    if (sessionId == null || daemonId == null) {
      if (_watchedSessionId != null) {
        chat.unwatch(_watchedSessionId!);
        _watchedSessionId = null;
        _watchedDaemonId = null;
      }
      return;
    }
    if (sessionId == _watchedSessionId && daemonId == _watchedDaemonId) {
      return;
    }
    if (_watchedSessionId != null) {
      chat.unwatch(_watchedSessionId!);
    }
    chat.watchSession(daemonId, sessionId);
    _watchedSessionId = sessionId;
    _watchedDaemonId = daemonId;
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    return ListenableBuilder(
      listenable: data.selection,
      builder: (BuildContext context, Widget? _) {
        // Re-sync on every rebuild, not just on selection changes. When a
        // pane is recreated while a session is already selected (layout
        // switches, future navigation), its first watch can be unwound by a
        // sibling pane's `dispose` running later in the same frame (that
        // unwatch removes the buffer this pane just recreated), which would
        // otherwise leave the timeline permanently empty. Idempotent, so
        // this is a no-op once the watch is stable.
        _syncWatch(
          data.chat,
          data.selection.selectedDaemonId,
          data.selection.selectedSessionId,
        );
        final String? daemonId = data.selection.selectedDaemonId;
        final String? sessionId = data.selection.selectedSessionId;
        if (daemonId == null || sessionId == null) {
          return const _EmptyState();
        }
        return _SessionSurface(
          key: ValueKey<String>('$daemonId/$sessionId'),
          data: data,
          daemonId: daemonId,
          sessionId: sessionId,
        );
      },
    );
  }
}

/// Renders the selected session's live surface. Stateful so the timeline
/// derivation and the latest-permission scan are cached per (session,
/// revision) instead of re-running over the whole event list on every chunk
/// notification, and so send/cancel/setMode failures can surface a SnackBar.
class _SessionSurface extends StatefulWidget {
  const _SessionSurface({
    super.key,
    required this.data,
    required this.daemonId,
    required this.sessionId,
  });

  final AppData data;
  final String daemonId;
  final String sessionId;

  @override
  State<_SessionSurface> createState() => _SessionSurfaceState();
}

class _SessionSurfaceState extends State<_SessionSurface> {
  /// Revision of the buffered events underlying [_items]/[_pending]. Starts
  /// at -1 so the first build always derives.
  int _revision = -1;

  /// Session-running flag underlying [_items]; a turn start/stop can change
  /// the derived active-thought marker without adding events.
  bool _running = false;

  List<TimelineItem> _items = const <TimelineItem>[];
  PermissionRequest? _pending;

  @override
  Widget build(BuildContext context) {
    final AppData data = widget.data;
    final String daemonId = widget.daemonId;
    final String sessionId = widget.sessionId;
    final ChatStore chat = data.chat;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[chat, data.sessions]),
      builder: (BuildContext context, Widget? _) {
        final List<SessionEvent> events = chat.eventsFor(sessionId);
        final SessionStatus status = chat.statusOf(sessionId);
        final bool running = status == SessionStatus.running;
        // ChatStore bumps a per-session counter on every buffer mutation,
        // so the cached derivation is skipped for rebuilds that carry no
        // new content (unrelated sessions' notifications, status/usage-only
        // updates) instead of re-scanning the whole event list per chunk.
        final int revision = chat.revisionFor(sessionId);
        if (revision != _revision || running != _running) {
          _revision = revision;
          _running = running;
          _items = deriveTimelineItems(events, running: running);
          _pending = _resolveLatest(events);
        }
        final SessionMode mode = chat.modeOf(sessionId);
        final UsageInfo? usage = chat.usageOf(sessionId);
        final PermissionRequest? pending = _pending;
        final Session? session = data.sessions.byId(sessionId);
        final HistoryStatus historyStatus = chat.historyStatusFor(sessionId);

        // While the first fetch runs (or after it failed with nothing live
        // to show), a bare timeline would read as an empty session.
        final Widget surface;
        if (events.isEmpty && historyStatus == HistoryStatus.loading) {
          surface = const _HistoryLoading();
        } else if (events.isEmpty && historyStatus == HistoryStatus.failed) {
          surface = _HistoryError(
            error: chat.historyErrorFor(sessionId),
            onRetry: () => chat.retryHistory(daemonId, sessionId),
          );
        } else {
          surface = Timeline(
            items: _items,
            attachmentLoader: (String attachmentId) =>
                chat.attachmentData(daemonId, sessionId, attachmentId),
          );
        }

        return Column(
          children: <Widget>[
            Expanded(child: surface),
            if (pending != null)
              PermissionBanner(
                request: pending,
                onOptionSelected: (PermissionOption option) {
                  unawaited(
                    chat.respondPermission(
                      daemonId,
                      sessionId,
                      pending.requestId,
                      option.optionId,
                    ),
                  );
                },
              ),
            Padding(
              // Keep the composer above the system navigation area on
              // edge-to-edge Android; the chat surface extends behind it.
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom),
              child: Composer(
                status: status,
                mode: mode,
                usage: usage,
                model: session?.model,
                onSend: (String text, List<OutgoingAttachment> attachments) {
                  if (status == SessionStatus.running) {
                    return Future<void>.value();
                  }
                  return _sendMessage(text, attachments);
                },
                onStop: () => unawaited(_cancelTurn()),
                onModeChanged: (SessionMode next) {
                  unawaited(_switchMode(next));
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendMessage(
    String text,
    List<OutgoingAttachment> attachments,
  ) async {
    try {
      await widget.data.chat.send(
        widget.daemonId,
        widget.sessionId,
        text,
        attachments: attachments,
      );
    } on DaemonError catch (error) {
      await _showError(error);
      // Delegate the text+attachments restore to the composer, which knows
      // the draft.
      rethrow;
    }
  }

  Future<void> _cancelTurn() async {
    try {
      await widget.data.chat.cancel(widget.daemonId, widget.sessionId);
    } on DaemonError catch (error) {
      await _showError(error);
    }
  }

  Future<void> _switchMode(SessionMode next) async {
    try {
      await widget.data.sessions
          .setMode(widget.daemonId, widget.sessionId, next);
    } on DaemonError catch (error) {
      await _showError(error);
    }
  }

  Future<void> _showError(DaemonError error) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message)));
  }

  static PermissionRequest? _resolveLatest(List<SessionEvent> events) {
    final Set<String> resolved = <String>{};
    for (int i = events.length - 1; i >= 0; i--) {
      switch (events[i]) {
        case PermissionRequestEvent e:
          if (!resolved.contains(e.request.requestId)) return e.request;
        case PermissionResolvedEvent e:
          resolved.add(e.requestId);
        default:
          break;
      }
    }
    return null;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Select or create a session',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Shown while a selected session's persisted history is being fetched, so a
/// slow daemon never reads as an empty conversation.
class _HistoryLoading extends StatelessWidget {
  const _HistoryLoading();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text(
            'Loading history…',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Shown when the history fetch failed before any event arrived (typically
/// because the daemon was unreachable); [onRetry] re-runs the fetch.
class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Could not load history',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('history-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
