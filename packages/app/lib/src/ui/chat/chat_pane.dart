import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/chat_store.dart';
import '../../state/file_transfer_store.dart';
import '../../state/turn_cache.dart';
import '../daemon_error_text.dart';
import 'composer.dart';
import 'file_action_dialog.dart';
import 'file_transfer_banner.dart';
import 'history_skeleton.dart';
import 'permission_banner.dart';
import 'question_banner.dart';
import 'timeline.dart';

/// Center pane: the selected session's timeline, pending permission banner and
/// composer. Tracks `selection.selectedSessionId` via [AppScope]; watching a
/// session subscribes the [ChatStore] to its live event stream.
class ChatPane extends StatefulWidget {
  const ChatPane({super.key, this.composerFocusNode});

  final FocusNode? composerFocusNode;

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
      listenable: Listenable.merge(<Listenable>[data.selection, data.shares]),
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
          return const Column(
            children: <Widget>[
              FileTransferBanner(),
              Expanded(child: _EmptyState()),
            ],
          );
        }
        return _SessionSurface(
          key: ValueKey<String>('$daemonId/$sessionId'),
          data: data,
          daemonId: daemonId,
          sessionId: sessionId,
          composerFocusNode: widget.composerFocusNode,
        );
      },
    );
  }
}

/// Renders the selected session's live surface. Stateful so the timeline
/// completed turns are cached while the live tail updates, and so
/// send/cancel failures can surface a SnackBar.
class _SessionSurface extends StatefulWidget {
  const _SessionSurface({
    super.key,
    required this.data,
    required this.daemonId,
    required this.sessionId,
    this.composerFocusNode,
  });

  final AppData data;
  final String daemonId;
  final String sessionId;
  final FocusNode? composerFocusNode;

  @override
  State<_SessionSurface> createState() => _SessionSurfaceState();
}

class _SessionSurfaceState extends State<_SessionSurface> {
  /// Revision of the buffered events underlying [_items]/[_pending]. Starts
  /// at -1 so the first build always derives.
  int _revision = -1;
  final TurnCache<TimelineItem> _timeline = TurnCache<TimelineItem>(
    (events, running) => deriveTimelineItems(events, running: running),
  );

  /// Session-running flag underlying [_items]; a turn start/stop (or the
  /// daemon dropping out of reach) can change the derived in-progress
  /// markers without adding events.
  bool _running = false;

  List<TimelineItem> _items = const <TimelineItem>[];
  int _turnSeed = 0;
  PermissionRequest? _pending;

  /// Newest buffered event. New events and streamed text replace it, while
  /// older history pages prepend and leave it alone, so a change here is
  /// activity at the live end; [_activity] counts those changes.
  SessionEvent? _tail;
  int _activity = 0;
  bool _forking = false;
  bool _draftErrorShown = false;
  final ValueNotifier<int> _followLatestRequest = ValueNotifier<int>(0);
  List<NativeCommand> _commands = const <NativeCommand>[];
  bool _loadingCommands = false;
  bool _refreshCommandsAfterLoad = false;
  bool _choosingFile = false;

  @override
  void initState() {
    super.initState();
    _commands = switch (widget.data.sessions
        .byId(widget.sessionId)
        ?.providerId) {
      'codex' => const <NativeCommand>[
        NativeCommand(
          name: 'compact',
          description: 'Compact conversation context',
        ),
        NativeCommand(
          name: 'review',
          description: 'Review uncommitted changes',
          argumentHint: 'review instructions',
        ),
      ],
      'ante' => const <NativeCommand>[
        NativeCommand(
          name: 'compact',
          description: 'Compact conversation context',
          argumentHint: 'instructions',
        ),
        NativeCommand(
          name: 'context',
          description: 'Show context usage by category',
        ),
      ],
      _ => const <NativeCommand>[],
    };
    unawaited(_loadCommands());
  }

  Future<void> _loadCommands() async {
    if (_loadingCommands) {
      _refreshCommandsAfterLoad = true;
      return;
    }
    _loadingCommands = true;
    try {
      final List<NativeCommand> commands = await widget.data.chat.listCommands(
        widget.daemonId,
        widget.sessionId,
      );
      if (mounted) setState(() => _commands = commands);
    } on Object catch (error) {
      if (mounted) await _showMessage('Could not load commands: $error');
    } finally {
      _loadingCommands = false;
      if (_refreshCommandsAfterLoad && mounted) {
        _refreshCommandsAfterLoad = false;
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 75), _loadCommands),
        );
      }
    }
  }

  @override
  void dispose() {
    _followLatestRequest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = widget.data;
    final String daemonId = widget.daemonId;
    final String sessionId = widget.sessionId;
    final ChatStore chat = data.chat;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        chat,
        data.sessions,
        data.connections,
        _followLatestRequest,
      ]),
      builder: (BuildContext context, Widget? _) {
        final List<SessionEvent> events = chat.eventViewFor(sessionId);
        final SessionStatus status = chat.statusOf(sessionId);
        // A turn last heard running on a daemon out of reach may be long
        // over, so nothing in it shows as still going.
        final bool running =
            status == SessionStatus.running &&
            !data.connections.statusOf(daemonId).outOfReach;
        // ChatStore bumps a per-session counter on every buffer mutation,
        // so the cached derivation is skipped for rebuilds that carry no
        // new content (unrelated sessions' notifications, status/usage-only
        // updates). Completed turns are reused when new content arrives.
        final int revision = chat.revisionFor(sessionId);
        if (revision != _revision || running != _running) {
          _revision = revision;
          _running = running;
          _items = _timeline.update(events, running: running);
          _turnSeed = latestTurnSeed(_items);
          _pending = chat.pendingPermissionFor(sessionId);
          // Loading or reloading history is not activity.
          final SessionEvent? tail = events.isEmpty ? null : events.last;
          if (_tail != null && tail != null && !identical(tail, _tail)) {
            _activity++;
          }
          _tail = tail;
        }
        // Messages still on their way: shown at once, and the flame lights
        // before the daemon reports the turn running.
        final List<OutgoingMessage> outgoing = chat.outgoingFor(sessionId);
        final bool sending = outgoing.isNotEmpty;
        final UsageInfo? usage = chat.usageOf(sessionId);
        final PermissionRequest? pending = _pending;
        final Session? session = data.sessions.byId(sessionId);
        final HistoryStatus historyStatus = chat.historyStatusFor(sessionId);
        // A just-reconnected daemon refetches what was missed offline; the
        // buffered timeline is stale for that window (but valid — nothing
        // is lost), so say so instead of silently showing old content.
        final bool catchingUp = chat.isCatchingUp(sessionId);

        // While the first fetch runs (or after it failed with nothing live
        // to show), a bare timeline would read as an empty session.
        final bool bare = events.isEmpty && !sending;
        final bool failed = historyStatus == HistoryStatus.failed;
        final Widget surface;
        if (bare && (historyStatus == HistoryStatus.loading || failed)) {
          // One placeholder for both, so a failure dims it in place.
          surface = Stack(
            key: const ValueKey<String>('history-placeholder'),
            fit: StackFit.expand,
            children: <Widget>[
              HistorySkeleton(
                failed: failed,
                caption: failed ? null : 'Loading history…',
              ),
              if (failed)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _HistoryError(
                    error: chat.historyErrorFor(sessionId),
                    onRetry: () => chat.retryHistory(daemonId, sessionId),
                  ),
                ),
            ],
          );
        } else {
          surface = Timeline(
            key: const ValueKey<String>('timeline'),
            items: _items,
            outgoing: outgoing,
            delivered: chat.deliveredSeqsFor(sessionId),
            heat: turnHeatFor(status, _items, sending: sending),
            turnSeed: _turnSeed,
            activity: _activity,
            cwd: session?.cwd,
            // A turn last heard running may be long over: say so instead.
            unreachable: switch (data.connections.statusOf(daemonId)) {
              ConnectionStatus.failed => 'Daemon unreachable',
              final ConnectionStatus link when link.outOfReach =>
                'Reconnecting…',
              _ => null,
            },
            followLatestRequest: _followLatestRequest.value,
            hasOlder: chat.hasOlderHistory(sessionId),
            loadingOlder: chat.isLoadingOlderHistory(sessionId),
            olderError: chat.olderHistoryErrorFor(sessionId),
            onLoadOlder: () {
              unawaited(chat.loadOlderHistory(daemonId, sessionId));
            },
            attachmentLoader: (String attachmentId) =>
                chat.attachmentData(daemonId, sessionId, attachmentId),
            onFork: _forking
                ? null
                : (int seq) {
                    unawaited(_forkFrom(seq));
                  },
            openLocalFile: _openLocalFile,
          );
        }

        return Column(
          children: <Widget>[
            const FileTransferBanner(),
            Expanded(child: _SurfaceSwitcher(child: surface)),
            if (catchingUp) const _CatchingUp(),
            if (pending != null && pending.questions.isNotEmpty)
              QuestionBanner(
                key: ValueKey(pending.requestId),
                request: pending,
                onSubmit: (answers) => chat.respondPermission(
                  daemonId,
                  sessionId,
                  pending.requestId,
                  answers == null ? 'dismiss' : 'answer',
                  answers: answers,
                ),
              ),
            if (pending != null && pending.questions.isEmpty)
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
                bottom: MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Composer(
                focusNode: widget.composerFocusNode,
                status: status,
                sending: sending,
                preparing: session?.preparing ?? false,
                commands: _commands,
                onSlashStarted: () => unawaited(_loadCommands()),
                usage: usage,
                model: session?.model,
                models: session?.models ?? const <String>[],
                onModelChanged: (String model) {
                  unawaited(_setModel(model));
                },
                thinkingLevel: session?.thinkingLevel,
                thinkingLevels: session?.thinkingLevels ?? const <String>[],
                onThinkingChanged: (String level) {
                  unawaited(_setThinkingLevel(level));
                },
                draft: data.drafts.textFor(daemonId, sessionId),
                onDraftChanged: _saveDraft,
                sharedAttachments: data.shares.stagedFor(daemonId, sessionId),
                onRemoveSharedAttachment: (OutgoingAttachment file) =>
                    data.shares.removeStaged(
                      daemonId,
                      sessionId,
                      <OutgoingAttachment>[file],
                    ),
                onSharedAttachmentsSent: (List<OutgoingAttachment> files) =>
                    data.shares.removeStaged(daemonId, sessionId, files),
                onSend:
                    (String text, List<OutgoingAttachment> attachments) async {
                      if (status == SessionStatus.running) {
                        return;
                      }
                      await _sendOrRunCommand(text, attachments);
                      if (mounted) _followLatestRequest.value++;
                    },
                onStop: () => unawaited(_cancelTurn()),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _forkFrom(int seq) async {
    if (_forking) return;
    setState(() => _forking = true);
    try {
      final Session fork = await widget.data.sessions.fork(
        widget.daemonId,
        widget.sessionId,
        seq,
      );
      widget.data.selection
        ..selectedProjectId = fork.projectId
        ..selectedSessionId = fork.id;
    } on DaemonError catch (error) {
      await _showError(error);
    } finally {
      if (mounted) setState(() => _forking = false);
    }
  }

  Future<void> _openLocalFile(String path) async {
    final FileTransferStore transfers = widget.data.fileTransfers;
    if (_choosingFile || transfers.busy) return;
    _choosingFile = true;
    try {
      final FileAction? action = await chooseFileAction(context, path);
      if (action == null || !mounted) return;
      await transfers.start(
        widget.data.clientFor(widget.daemonId),
        widget.sessionId,
        path,
        action,
      );
    } on Object {
      // The transfer store records the failure in its persistent banner.
      if (transfers.lastError == null) rethrow;
    } finally {
      _choosingFile = false;
    }
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

  Future<void> _sendOrRunCommand(
    String text,
    List<OutgoingAttachment> attachments,
  ) async {
    final String? providerId = widget.data.sessions
        .byId(widget.sessionId)
        ?.providerId;
    final int space = text.indexOf(' ');
    final String name = text.startsWith('/')
        ? text.substring(1, space < 0 ? text.length : space)
        : '';
    if ((providerId != 'codex' && providerId != 'ante') || name.isEmpty) {
      await _sendMessage(text, attachments);
      return;
    }
    if (attachments.isNotEmpty) {
      final error = DaemonError(
        -32602,
        'Native commands do not accept attachments',
      );
      await _showError(error);
      throw error;
    }
    final String arguments = space < 0 ? '' : text.substring(space + 1).trim();
    try {
      await widget.data.chat.runCommand(
        widget.daemonId,
        widget.sessionId,
        name,
        arguments: arguments,
      );
    } on DaemonError catch (error) {
      await _showError(error);
      rethrow;
    }
  }

  Future<void> _saveDraft(String text) async {
    try {
      await widget.data.drafts.setText(widget.daemonId, widget.sessionId, text);
      _draftErrorShown = false;
    } on Object {
      if (!mounted || _draftErrorShown) return;
      _draftErrorShown = true;
      await _showMessage('Could not save this draft');
    }
  }

  Future<void> _cancelTurn() async {
    try {
      await widget.data.chat.cancel(widget.daemonId, widget.sessionId);
    } on DaemonError catch (error) {
      await _showError(error);
    }
  }

  Future<void> _setThinkingLevel(String level) async {
    try {
      await widget.data.sessions.setThinkingLevel(
        widget.daemonId,
        widget.sessionId,
        level,
      );
    } on DaemonError catch (error) {
      await _showError(error);
    }
  }

  Future<void> _setModel(String model) async {
    try {
      await widget.data.sessions.setModel(
        widget.daemonId,
        widget.sessionId,
        model,
      );
    } on DaemonError catch (error) {
      await _showError(error);
    }
  }

  Future<void> _showError(DaemonError error) async {
    if (!mounted) return;
    // A connection drop (device sleep, network flap) self-heals via
    // auto-reconnect + resync: show a transient notice, not the raw error.
    final String text = error is DaemonConnectionError
        ? kConnectionLostMessage
        : error.message;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _showMessage(String text) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Hands the session's surface over — loading placeholder to conversation —
/// with a short crossfade, the incoming side settling up into place.
class _SurfaceSwitcher extends StatelessWidget {
  const _SurfaceSwitcher({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedSwitcher(
      duration: still ? Duration.zero : const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.015),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
      child: child,
    );
  }
}

/// Shown along the foot of the cold placeholder when the history fetch
/// failed before any event arrived (typically because the daemon was
/// unreachable); [onRetry] re-runs the fetch.
class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: <Widget>[
              Icon(Icons.cloud_off_outlined, size: 20, color: scheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Could not load history',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '$error',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: const Key('history-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown while the daemon reconnects and the watched session's history is
/// refetched to backfill events missed offline: the rendered timeline is
/// stale for that window. Auto-dismisses once the backfill lands.
class _CatchingUp extends StatelessWidget {
  const _CatchingUp();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Catching up…',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
