import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../state/session_timeline.dart';
import '../../theme.dart';
import 'active_pulse.dart';
import 'history_expansion.dart';
import 'message_view.dart';
import 'plan_panel.dart';
import 'tool_call_card.dart';

/// A derived, display-ready row of the session timeline.
sealed class TimelineItem {
  const TimelineItem({this.id});

  /// Stable within a session, including across chunk and snapshot updates.
  /// Optional for standalone/test rows without persisted events.
  final Object? id;
}

/// A user message (already complete; not streamed).
class UserMessageItem extends TimelineItem {
  const UserMessageItem({
    super.id,
    required this.text,
    this.attachments = const <Attachment>[],
    this.forkSeq,
  });

  final String text;

  /// Files attached to the message (metadata; payloads are fetched lazily
  /// through the timeline's `attachmentLoader`).
  final List<Attachment> attachments;

  /// Sequence of this message event; null for unpersisted/test-only items.
  final int? forkSeq;
}

/// An image the agent explicitly displayed for the user.
class DisplayedImageItem extends TimelineItem {
  const DisplayedImageItem({super.id, required this.attachment});
  final Attachment attachment;
}

/// One logical agent message assembled from its identified chunks.
class AgentMessageItem extends TimelineItem {
  const AgentMessageItem({
    super.id,
    required this.text,
    this.forkSeq,
    this.streaming = false,
  });
  final bool streaming;
  final String text;

  /// Last chunk sequence in this rendered agent message.
  final int? forkSeq;
}

/// One logical agent thought assembled from its identified chunks.
class AgentThoughtItem extends TimelineItem {
  const AgentThoughtItem({super.id, required this.text, this.active = false});
  final String text;

  /// True while this run is the session's live tail: the agent is still
  /// producing reasoning deltas (drives the pulsing "Thinking…" indicator).
  final bool active;
}

/// The latest snapshot of one tool call (later events update in place).
class ToolCallTimelineItem extends TimelineItem {
  const ToolCallTimelineItem({super.id, required this.toolCall});
  final ToolCall toolCall;
}

/// Latest snapshot of one provider-reported background activity.
class AgentActivityItem extends TimelineItem {
  const AgentActivityItem({super.id, required this.activity});
  final AgentActivity activity;
}

class _LegacySubagentState {
  _LegacySubagentState({
    required this.activityId,
    required this.identity,
    required this.headerIndex,
    required this.title,
    required this.type,
    required this.startedWithoutMetadata,
  });

  final String activityId;
  final Object identity;
  final int headerIndex;
  final String title;
  final String type;
  final bool startedWithoutMetadata;
  String progressText = '';
  int step = 0;
  bool terminal = false;
}

class _SubagentPresentation {
  const _SubagentPresentation({
    required this.title,
    this.details = const <String>[],
  });

  final String title;
  final List<String> details;
}

/// A full-replacement plan view.
class PlanTimelineItem extends TimelineItem {
  const PlanTimelineItem({super.id, required this.entries});
  final List<PlanEntry> entries;
}

/// Compact inline record of a pending permission request; the actionable
/// banner is rendered separately by the chat pane's PermissionBanner.
class PermissionRequestItem extends TimelineItem {
  const PermissionRequestItem({super.id, required this.request});
  final PermissionRequest request;
}

/// A permission request was resolved with the given option.
class PermissionResolvedItem extends TimelineItem {
  const PermissionResolvedItem({
    super.id,
    required this.requestId,
    required this.optionId,
  });
  final String requestId;
  final String optionId;
}

/// The agent finished its turn.
class TurnCompleteItem extends TimelineItem {
  const TurnCompleteItem({super.id, required this.stopReason});
  final String stopReason;
}

/// The session hit an error.
class SessionErrorItem extends TimelineItem {
  const SessionErrorItem({super.id, required this.message});
  final String message;
}

/// Maps the shared, presentation-neutral session fold to full-client rows.
List<TimelineItem> deriveTimelineItems(
  List<SessionEvent> events, {
  bool running = false,
}) {
  final List<TimelineItem> items = <TimelineItem>[];
  final Map<String, _LegacySubagentState> legacySubagents =
      <String, _LegacySubagentState>{};
  final Map<String, int> legacySubagentGenerations = <String, int>{};

  void foldLegacySubagent(ToolCall toolCall, int? firstSeq) {
    _LegacySubagentState? state = legacySubagents[toolCall.id];
    if (state == null ||
        (state.terminal && _isActiveToolStatus(toolCall.status))) {
      final int generation = (legacySubagentGenerations[toolCall.id] ?? -1) + 1;
      legacySubagentGenerations[toolCall.id] = generation;
      final Map<Object?, Object?>? input = toolCall.rawInput is Map
          ? toolCall.rawInput! as Map<Object?, Object?>
          : null;
      final String type = input?['subagent_type'] as String? ?? '';
      final String description = input?['description'] as String? ?? '';
      final String title = description.isNotEmpty
          ? description
          : type.isNotEmpty
          ? '${_humanizeActivity(type)} subagent'
          : 'Subagent';
      final String activityId = 'legacy-subagent-${toolCall.id}-$generation';
      state = _LegacySubagentState(
        activityId: activityId,
        identity: (firstSeq, activityId),
        headerIndex: items.length,
        title: title,
        type: type,
        startedWithoutMetadata: input == null,
      );
      legacySubagents[toolCall.id] = state;
      items.add(
        AgentActivityItem(
          id: state.identity,
          activity: AgentActivity(
            id: activityId,
            kind: 'subagent',
            title: title,
            status: _activityStatusFor(toolCall.status),
            details: <String>[if (type.isNotEmpty) type],
          ),
        ),
      );
    }

    if (_isActiveToolStatus(toolCall.status)) {
      final String progressText = _toolCallText(toolCall);
      if (progressText == state.progressText) return;
      String appended;
      if (progressText.length >= state.progressText.length) {
        appended = progressText.substring(state.progressText.length);
        if (appended.startsWith('\n')) appended = appended.substring(1);
      } else {
        appended = progressText;
      }
      final List<String> updates =
          state.progressText.isEmpty &&
              state.startedWithoutMetadata &&
              appended.contains('\n')
          ? appended.split('\n')
          : <String>[appended];
      state.progressText = progressText;
      for (final String update in updates) {
        if (update.trim().isEmpty) continue;
        final _SubagentPresentation presentation = _subagentPresentation(
          update,
        );
        items.add(
          AgentActivityItem(
            id: (state.identity, state.step),
            activity: AgentActivity(
              id: '${state.activityId}-step-${state.step++}',
              kind: 'subagent',
              title: presentation.title,
              status: AgentActivityStatus.completed,
              details: presentation.details,
            ),
          ),
        );
      }
      return;
    }

    final String? report = _legacySubagentReport(toolCall);
    items[state.headerIndex] = AgentActivityItem(
      id: state.identity,
      activity: AgentActivity(
        id: state.activityId,
        kind: 'subagent',
        title: state.title,
        status: _activityStatusFor(toolCall.status),
        details: <String>[
          if (state.type.isNotEmpty) state.type,
          if (report != null && report.isNotEmpty) report,
        ],
      ),
    );
    state.terminal = true;
  }

  int? turnSeq;
  int turnIndex = 0;
  final List<FoldedSessionEntry> folded = foldSessionEvents(events);
  for (int index = 0; index < folded.length; index++) {
    final FoldedSessionEntry entry = folded[index];
    if (entry case FoldedSessionEvent(event: UserMessageEvent(:final seq))) {
      turnSeq = seq;
      turnIndex = 0;
    }
    final int rowInTurn = turnIndex++;
    switch (entry) {
      case FoldedAgentMessage e:
        items.add(
          AgentMessageItem(
            id: (turnSeq, 'message', e.messageId ?? rowInTurn),
            text: e.text,
            forkSeq: e.seq,
            streaming: running,
          ),
        );
      case FoldedAgentThought e:
        items.add(
          AgentThoughtItem(
            id: (turnSeq, 'thought', e.messageId ?? rowInTurn),
            text: e.text,
            active: running && index == folded.length - 1,
          ),
        );
      case FoldedToolCall e:
        if (_isLegacySubagentTool(e.latest)) {
          for (final ToolCall snapshot in e.snapshots) {
            foldLegacySubagent(snapshot, e.firstSeq);
          }
        } else {
          items.add(ToolCallTimelineItem(id: e.firstSeq, toolCall: e.latest));
        }
      case FoldedAgentActivity e:
        items.add(AgentActivityItem(id: e.activity.id, activity: e.activity));
      case FoldedSessionEvent(:final event):
        switch (event) {
          case UserMessageEvent e:
            items.add(
              UserMessageItem(
                id: e.seq,
                text: e.text,
                attachments: e.attachments,
                forkSeq: e.seq,
              ),
            );
          case ImageEvent e:
            items.add(DisplayedImageItem(id: e.seq, attachment: e.attachment));
          case PlanEvent e:
            items.add(PlanTimelineItem(id: e.seq, entries: e.entries));
          case PermissionRequestEvent e:
            items.add(PermissionRequestItem(id: e.seq, request: e.request));
          case PermissionResolvedEvent e:
            items.add(
              PermissionResolvedItem(
                id: e.seq,
                requestId: e.requestId,
                optionId: e.optionId,
              ),
            );
          case TurnCompleteEvent e:
            items.add(TurnCompleteItem(id: e.seq, stopReason: e.stopReason));
          case SessionErrorEvent e:
            items.add(SessionErrorItem(id: e.seq, message: e.message));
          case UsageEvent _:
            break;
          case AgentMessageChunkEvent _ ||
              AgentThoughtChunkEvent _ ||
              ToolCallEvent _ ||
              AgentActivityEvent _:
            throw StateError('Logical event was not folded: $event');
        }
    }
  }
  return items;
}

bool _isActiveToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => true,
  ToolCallStatus.completed || ToolCallStatus.failed => false,
};

bool _isLegacySubagentTool(ToolCall toolCall) =>
    toolCall.title.toLowerCase() == 'agent';

AgentActivityStatus _activityStatusFor(ToolCallStatus status) =>
    switch (status) {
      ToolCallStatus.pending ||
      ToolCallStatus.running => AgentActivityStatus.running,
      ToolCallStatus.completed => AgentActivityStatus.completed,
      ToolCallStatus.failed => AgentActivityStatus.failed,
    };

String _toolCallText(ToolCall toolCall) => toolCall.content
    .whereType<ToolCallText>()
    .map((ToolCallText content) => content.text)
    .join('\n');

String? _legacySubagentReport(ToolCall toolCall) {
  final Object? output = toolCall.rawOutput;
  if (output is Map<Object?, Object?> && output['report'] is String) {
    return output['report']! as String;
  }
  final String text = _toolCallText(toolCall);
  return text.isEmpty ? null : text;
}

_SubagentPresentation _subagentPresentation(String message) {
  final String trimmed = message.trim();
  final RegExpMatch? invocation = _subagentInvocation.firstMatch(trimmed);
  if (invocation != null) {
    final String arguments = invocation.group(2)!.trim();
    return _SubagentPresentation(
      title: invocation.group(1)!,
      details: <String>[if (arguments.isNotEmpty) arguments],
    );
  }
  if (trimmed.contains('\n') || trimmed.length > 160) {
    final String firstLine = trimmed.split('\n').first;
    final String title = firstLine.length <= 160
        ? firstLine
        : '${firstLine.substring(0, 159)}…';
    return _SubagentPresentation(title: title, details: <String>[trimmed]);
  }
  return _SubagentPresentation(title: trimmed);
}

String _humanizeActivity(String value) {
  if (value.isEmpty) return value;
  final String spaced = value.replaceAll('_', ' ');
  return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}

final RegExp _subagentInvocation = RegExp(
  r'^([A-Za-z][A-Za-z0-9_]*)\(([\s\S]*)\)$',
);

/// Virtualized, bottom-following timeline of a session's derived items.
///
/// [items] is the [deriveTimelineItems] output for the session; callers
/// cache it per session revision so every chunk notification does not
/// re-scan the full raw event list.
class Timeline extends StatefulWidget {
  const Timeline({
    super.key,
    required this.items,
    this.attachmentLoader,
    this.onFork,
    this.openLocalFile,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.olderError,
    this.onLoadOlder,
    this.followLatestRequest = 0,
  });

  /// Increment after a successful local send to resume following the timeline.
  final int followLatestRequest;

  final List<TimelineItem> items;
  final bool hasOlder;
  final bool loadingOlder;
  final Object? olderError;
  final VoidCallback? onLoadOlder;

  /// Resolves an attachment's payload by id (through the chat store); when
  /// null, attachment chips render without loading their bytes (defensive
  /// default for standalone timelines).
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  /// Forks the selected session through the message event at [seq].
  final void Function(int seq)? onFork;

  /// Downloads and opens a path linked from an agent markdown message.
  final Future<void> Function(String path)? openLocalFile;

  @override
  State<Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<Timeline> {
  static const double _loadThreshold = 320;
  static const Key _historyKey = ValueKey<String>('timeline-history');
  final _TimelineScrollController _controller = _TimelineScrollController();
  final ValueNotifier<bool> _showLatest = ValueNotifier<bool>(false);
  Object? _liveStart;
  bool _requestedOlder = false;
  final PageStorageBucket _storage = PageStorageBucket();

  Object _identity(TimelineItem item, int index) =>
      item.id ??
      switch (item) {
        ToolCallTimelineItem i => ('tool', i.toolCall.id, index),
        AgentActivityItem i => ('activity', i.activity.id),
        UserMessageItem i when i.forkSeq != null => ('user', i.forkSeq),
        _ => ('row', index),
      };

  @override
  void initState() {
    super.initState();
    // History grows upward from this fixed boundary, live events downward.
    // Keeping that origin fixed prevents either end moving the reader.
    _initializeOrigin();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _initializeOrigin() {
    if (_liveStart != null || widget.items.isEmpty) return;
    int index = widget.items.lastIndexWhere(
      (TimelineItem item) => item is UserMessageItem,
    );
    if (index < 0) index = widget.items.length - 1;
    _liveStart = _identity(widget.items[index], index);
  }

  @override
  void didUpdateWidget(Timeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initializeOrigin();
    if (widget.followLatestRequest != oldWidget.followLatestRequest) {
      _controller.followLatest = true;
    }
    if (oldWidget.loadingOlder != widget.loadingOlder ||
        oldWidget.hasOlder != widget.hasOlder) {
      _requestedOlder = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _onScroll() {
    if (!mounted || !_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    _showLatest.value = position.pixels - position.minScrollExtent > 24;
    if (!_requestedOlder &&
        widget.hasOlder &&
        !widget.loadingOlder &&
        widget.onLoadOlder != null &&
        position.maxScrollExtent - position.pixels <= _loadThreshold) {
      _requestedOlder = true;
      widget.onLoadOlder!();
    }
  }

  void _jumpToLatest() {
    _controller.followLatest = true;
    _controller.jumpTo(_controller.position.minScrollExtent);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    _showLatest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Object> identities = <Object>[
      for (int i = 0; i < widget.items.length; i++)
        _identity(widget.items[i], i),
    ];
    final int originIndex = _liveStart == null
        ? -1
        : identities.indexOf(_liveStart!);
    final int split = originIndex < 0 ? 0 : originIndex;
    final bool historyStatus = widget.loadingOlder || widget.olderError != null;

    SliverChildBuilderDelegate rows(
      int start,
      int end, {
      bool reverse = false,
    }) {
      final Map<Key, int> indices = <Key, int>{
        for (int i = start; i < end; i++)
          PageStorageKey<Object>(identities[i]): reverse
              ? end - 1 - i
              : i - start,
      };
      return SliverChildBuilderDelegate(
        (BuildContext context, int index) {
          if (index == end - start) {
            return _OlderHistoryStatus(
              loading: widget.loadingOlder,
              error: widget.olderError,
              onRetry: widget.onLoadOlder,
            );
          }
          final int itemIndex = reverse ? end - 1 - index : start + index;
          return _TimelineRow(
            key: PageStorageKey<Object>(identities[itemIndex]),
            item: widget.items[itemIndex],
            attachmentLoader: widget.attachmentLoader,
            onFork: widget.onFork,
            openLocalFile: widget.openLocalFile,
          );
        },
        childCount: end - start + (reverse && historyStatus ? 1 : 0),
        findChildIndexCallback: (Key key) => indices[key],
      );
    }

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            onPointerDown: (_) => _controller.followLatest = false,
            onPointerSignal: (_) => _controller.followLatest = false,
            child: NotificationListener<ScrollNotification>(
              onNotification: (ScrollNotification notification) {
                if (notification.depth != 0) return false;
                if (notification is ScrollEndNotification) {
                  _controller.followLatest =
                      notification.metrics.pixels -
                          notification.metrics.minScrollExtent <=
                      1;
                }
                return false;
              },
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (ScrollMetricsNotification notification) {
                  if (notification.depth == 0) _onScroll();
                  return false;
                },
                child: PageStorage(
                  bucket: _storage,
                  child: SelectionArea(
                    child: CustomScrollView(
                      key: const Key('chat-timeline'),
                      controller: _controller,
                      reverse: true,
                      center: _historyKey,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: <Widget>[
                        SliverPadding(
                          padding: const EdgeInsets.only(bottom: 8),
                          sliver: SliverList(
                            delegate: rows(split, widget.items.length),
                          ),
                        ),
                        SliverPadding(
                          key: _historyKey,
                          padding: const EdgeInsets.only(top: 8),
                          sliver: SliverList(
                            delegate: rows(0, split, reverse: true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 12,
          child: ValueListenableBuilder<bool>(
            valueListenable: _showLatest,
            builder: (BuildContext context, bool visible, Widget? child) =>
                visible ? child! : const SizedBox.shrink(),
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Jump to latest event',
              onPressed: _jumpToLatest,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
        ),
      ],
    );
  }
}

/// Correct during layout so following streamed content never flashes an old
/// offset. When reading, the two slivers keep the content origin stationary.
class _TimelineScrollController extends ScrollController {
  bool followLatest = true;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TimelineScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    controller: this,
  );
}

class _TimelineScrollPosition extends ScrollPositionWithSingleContext {
  _TimelineScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.controller,
  });

  final _TimelineScrollController controller;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (controller.followLatest && pixels != minScrollExtent) {
      correctPixels(minScrollExtent);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _OlderHistoryStatus extends StatelessWidget {
  const _OlderHistoryStatus({
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Retry older history'),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    super.key,
    required this.item,
    this.attachmentLoader,
    this.onFork,
    this.openLocalFile,
  });

  final TimelineItem item;

  /// See [Timeline.attachmentLoader].
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;
  final void Function(int seq)? onFork;
  final Future<void> Function(String path)? openLocalFile;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserMessageItem i => _MessageWithActions(
        isUser: true,
        text: i.text,
        seq: i.forkSeq,
        onFork: onFork,
        child: UserMessageBubble(
          text: i.text,
          attachments: i.attachments,
          attachmentLoader: attachmentLoader,
        ),
      ),
      DisplayedImageItem i => _DisplayedImage(
        attachment: i.attachment,
        attachmentLoader: attachmentLoader,
      ),
      AgentMessageItem i => _MessageWithActions(
        isUser: false,
        text: i.text,
        seq: i.forkSeq,
        onFork: onFork,
        child: AgentMessageView(
          text: i.text,
          streaming: i.streaming,
          openLocalFile: openLocalFile,
        ),
      ),
      AgentThoughtItem i => AgentThoughtView(text: i.text, active: i.active),
      ToolCallTimelineItem i => ToolCallCard(
        key: ValueKey<Object>(i.id ?? i.toolCall.id),
        toolCall: i.toolCall,
        attachmentLoader: attachmentLoader,
      ),
      AgentActivityItem i => _ActivityCard(activity: i.activity),
      PlanTimelineItem i => PlanPanel(entries: i.entries),
      PermissionRequestItem i => _InlinePermissionRecord(request: i.request),
      PermissionResolvedItem i => _ResolvedRecord(optionId: i.optionId),
      TurnCompleteItem _ => _TurnDivider(),
      SessionErrorItem i => _ErrorBanner(message: i.message),
    };
  }
}

class _DisplayedImage extends StatelessWidget {
  const _DisplayedImage({
    required this.attachment,
    required this.attachmentLoader,
  });

  final Attachment attachment;
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AttachmentView(attachment: attachment, loader: attachmentLoader),
          const SizedBox(height: 4),
          Text(attachment.name, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    ),
  );
}

/// Adds compact copy and fork actions to user and agent messages without
/// making non-message timeline rows actionable.
class _MessageWithActions extends StatelessWidget {
  const _MessageWithActions({
    required this.child,
    required this.isUser,
    required this.text,
    required this.seq,
    required this.onFork,
  });

  final Widget child;
  final bool isUser;
  final String text;
  final int? seq;
  final void Function(int seq)? onFork;

  @override
  Widget build(BuildContext context) {
    final List<Widget> buttons = <Widget>[];
    if (text.isNotEmpty) {
      buttons.add(
        IconButton(
          key: seq == null ? null : ValueKey<String>('copy-message-${seq!}'),
          tooltip: 'Copy message',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () => _copyMessage(context),
          icon: const Icon(Icons.content_copy),
        ),
      );
    }
    final int? messageSeq = seq;
    final void Function(int seq)? callback = onFork;
    if (messageSeq != null && callback != null) {
      buttons.add(
        IconButton(
          key: ValueKey<String>('fork-message-$messageSeq'),
          tooltip: 'Fork from this message',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () => callback(messageSeq),
          icon: const Icon(Icons.fork_right),
        ),
      );
    }
    if (buttons.isEmpty) return child;
    return _MessageActionsLayout(
      isUser: isUser,
      children: <Widget>[child, ...buttons],
    );
  }

  Future<void> _copyMessage(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}

/// Measures the actual bubble, including Markdown and attachments, so short
/// messages do not acquire the height of a stacked action column.
class _MessageActionsLayout extends MultiChildRenderObjectWidget {
  const _MessageActionsLayout({required this.isUser, required super.children});

  final bool isUser;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMessageActions(isUser);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMessageActions renderObject,
  ) {
    renderObject.isUser = isUser;
  }
}

class _MessageActionsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderMessageActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MessageActionsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MessageActionsParentData> {
  _RenderMessageActions(this._isUser);

  bool _isUser;
  set isUser(bool value) {
    if (_isUser == value) return;
    _isUser = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MessageActionsParentData) {
      child.parentData = _MessageActionsParentData();
    }
  }

  @override
  void performLayout() {
    final RenderBox bubble = firstChild!;
    double rowWidth = 0;
    double rowHeight = 0;
    double columnWidth = 0;
    double columnHeight = 0;
    for (
      RenderBox? action = childAfter(bubble);
      action != null;
      action = childAfter(action)
    ) {
      action.layout(constraints.loosen(), parentUsesSize: true);
      rowWidth += action.size.width;
      rowHeight = rowHeight > action.size.height
          ? rowHeight
          : action.size.height;
      columnWidth = columnWidth > action.size.width
          ? columnWidth
          : action.size.width;
      columnHeight += action.size.height;
    }
    final BoxConstraints stackedBubbleConstraints = BoxConstraints(
      maxWidth: (constraints.maxWidth - columnWidth).clamp(0, double.infinity),
    );
    bubble.layout(stackedBubbleConstraints, parentUsesSize: true);
    bool horizontal = bubble.size.height < columnHeight;
    if (horizontal) {
      // Reserve space for both buttons, then account for any extra wrapping.
      // Tall messages only need the initial layout above.
      bubble.layout(
        BoxConstraints(
          maxWidth: (constraints.maxWidth - rowWidth).clamp(0, double.infinity),
        ),
        parentUsesSize: true,
      );
      horizontal = bubble.size.height < columnHeight;
      if (!horizontal) {
        bubble.layout(stackedBubbleConstraints, parentUsesSize: true);
      }
    }
    final double actionsWidth = horizontal ? rowWidth : columnWidth;
    final double actionsHeight = horizontal ? rowHeight : columnHeight;
    final double height = bubble.size.height > actionsHeight
        ? bubble.size.height
        : actionsHeight;
    size = constraints.constrain(Size(constraints.maxWidth, height));
    final double left = _isUser
        ? size.width - bubble.size.width - actionsWidth
        : 0;
    (bubble.parentData! as _MessageActionsParentData).offset = Offset(
      left + (_isUser ? actionsWidth : 0),
      size.height - bubble.size.height,
    );
    double x = _isUser ? left : bubble.size.width;
    double y = size.height - actionsHeight;
    for (
      RenderBox? action = childAfter(bubble);
      action != null;
      action = childAfter(action)
    ) {
      (action.parentData! as _MessageActionsParentData).offset = Offset(
        x + (horizontal ? 0 : (actionsWidth - action.size.width) / 2),
        y + (horizontal ? (actionsHeight - action.size.height) / 2 : 0),
      );
      if (horizontal) {
        x += action.size.width;
      } else {
        y += action.size.height;
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _InlinePermissionRecord extends StatelessWidget {
  const _InlinePermissionRecord({required this.request});

  final PermissionRequest request;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        'Permission requested: ${request.title}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ResolvedRecord extends StatelessWidget {
  const _ResolvedRecord({required this.optionId});

  final String optionId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        'Chose $optionId',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TurnDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Divider(height: 1),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});

  final AgentActivity activity;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = context.speedDialColors;
    final bool isSubagent = activity.kind == 'subagent';
    final Color accent = switch (activity.status) {
      AgentActivityStatus.running => colors.running,
      AgentActivityStatus.completed => theme.colorScheme.primary,
      AgentActivityStatus.failed => colors.error,
    };
    final Widget icon = switch (activity.status) {
      AgentActivityStatus.running => SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: accent),
      ),
      AgentActivityStatus.completed => Icon(
        Icons.check_circle_outline,
        size: 17,
        color: accent,
      ),
      AgentActivityStatus.failed => Icon(
        Icons.error_outline,
        size: 17,
        color: accent,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          expansionAnimationStyle: animateHistoryDetails(activity.details)
              ? null
              : AnimationStyle.noAnimation,
          key: ValueKey<String>('activity-${activity.id}'),
          leading: ActivePulse(
            active: activity.status == AgentActivityStatus.running,
            pulseKey: ValueKey<String>('activity-pulse-${activity.id}'),
            child: icon,
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(40, 0, 12, 10),
          dense: true,
          showTrailingIcon: activity.details.isNotEmpty,
          initiallyExpanded: activity.status == AgentActivityStatus.failed,
          title: ActivePulse(
            active: activity.status == AgentActivityStatus.running,
            pulseKey: ValueKey<String>('activity-pulse-${activity.id}'),
            child: isSubagent
                ? Row(
                    children: <Widget>[
                      _ActivityTag(
                        key: ValueKey<String>('activity-tag-${activity.id}'),
                        label: 'SUBAGENT',
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          activity.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  )
                : Text(activity.title, style: theme.textTheme.bodySmall),
          ),
          subtitle: isSubagent && activity.details.isEmpty
              ? null
              : Text(
                  isSubagent ? activity.details.first : activity.kind,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
          children: <Widget>[
            for (final String detail in activity.details)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActivityTag extends StatelessWidget {
  const _ActivityTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final Color accent = context.speedDialColors.purple;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: accent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.error.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}
