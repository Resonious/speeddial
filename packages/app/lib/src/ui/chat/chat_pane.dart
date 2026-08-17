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
        final String? daemonId = data.selection.selectedDaemonId;
        final String? sessionId = data.selection.selectedSessionId;
        if (daemonId == null || sessionId == null) {
          return const _EmptyState();
        }
        return _SessionSurface(data: data, daemonId: daemonId, sessionId: sessionId);
      },
    );
  }
}

class _SessionSurface extends StatelessWidget {
  const _SessionSurface({
    required this.data,
    required this.daemonId,
    required this.sessionId,
  });

  final AppData data;
  final String daemonId;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final ChatStore chat = data.chat;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[chat, data.sessions]),
      builder: (BuildContext context, Widget? _) {
        final List<SessionEvent> events = chat.eventsFor(sessionId);
        final SessionStatus status = chat.statusOf(sessionId);
        final SessionMode mode = chat.modeOf(sessionId);
        final UsageInfo? usage = chat.usageOf(sessionId);
        final PermissionRequest? pending = _resolveLatest(events);
        final Session? session = data.sessions.byId(sessionId);

        return Column(
          children: <Widget>[
            Expanded(child: Timeline(events: events)),
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
            Composer(
              status: status,
              mode: mode,
              usage: usage,
              model: session?.model,
              onSend: (String text) {
                if (status == SessionStatus.running) return;
                unawaited(chat.send(daemonId, sessionId, text));
              },
              onStop: () => unawaited(chat.cancel(daemonId, sessionId)),
              onModeChanged: (SessionMode next) {
                unawaited(data.sessions.setMode(daemonId, sessionId, next));
              },
            ),
          ],
        );
      },
    );
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
