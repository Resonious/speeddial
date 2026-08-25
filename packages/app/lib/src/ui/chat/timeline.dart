import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'active_pulse.dart';
import 'message_view.dart';
import 'plan_panel.dart';
import 'tool_call_card.dart';

/// A derived, display-ready row of the session timeline.
sealed class TimelineItem {
  const TimelineItem();
}

/// A user message (already complete; not streamed).
class UserMessageItem extends TimelineItem {
  const UserMessageItem({
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
  const DisplayedImageItem({required this.attachment});
  final Attachment attachment;
}

/// A merged run of consecutive agent message chunks.
class AgentMessageItem extends TimelineItem {
  const AgentMessageItem({required this.text, this.forkSeq});
  final String text;

  /// Last chunk sequence in this rendered agent message.
  final int? forkSeq;
}

/// A merged run of consecutive agent thought chunks.
class AgentThoughtItem extends TimelineItem {
  const AgentThoughtItem({required this.text, this.active = false});
  final String text;

  /// True while this run is the session's live tail: the agent is still
  /// producing reasoning deltas (drives the pulsing "Thinking…" indicator).
  final bool active;
}

/// The latest snapshot of one tool call (later events update in place).
class ToolCallTimelineItem extends TimelineItem {
  const ToolCallTimelineItem({required this.toolCall});
  final ToolCall toolCall;
}

/// Latest snapshot of one provider-reported background activity.
class AgentActivityItem extends TimelineItem {
  const AgentActivityItem({required this.activity});
  final AgentActivity activity;
}

/// A full-replacement plan view.
class PlanTimelineItem extends TimelineItem {
  const PlanTimelineItem({required this.entries});
  final List<PlanEntry> entries;
}

/// Compact inline record of a pending permission request; the actionable
/// banner is rendered separately by the chat pane's PermissionBanner.
class PermissionRequestItem extends TimelineItem {
  const PermissionRequestItem({required this.request});
  final PermissionRequest request;
}

/// A permission request was resolved with the given option.
class PermissionResolvedItem extends TimelineItem {
  const PermissionResolvedItem({
    required this.requestId,
    required this.optionId,
  });
  final String requestId;
  final String optionId;
}

/// The agent finished its turn.
class TurnCompleteItem extends TimelineItem {
  const TurnCompleteItem({required this.stopReason});
  final String stopReason;
}

/// The session hit an error.
class SessionErrorItem extends TimelineItem {
  const SessionErrorItem({required this.message});
  final String message;
}

/// Maps a session's raw event list to display items.
///
/// Consecutive same-type chunk events merge into one item (their final merged
/// text). Tool-call events replace the previous snapshot with the same id
/// while that call is active. Some providers reuse an id for a later call;
/// an active snapshot after a terminal one starts a new timeline item.
/// Usage events are skipped here — usage is surfaced in the composer footer.
///
/// When [running] is true (session mid-turn) and the last event is a thought
/// chunk, the trailing thought item is marked active; any later event kind
/// (message chunk, tool call, turn complete, …) closes the thought run.
List<TimelineItem> deriveTimelineItems(
  List<SessionEvent> events, {
  bool running = false,
}) {
  final List<TimelineItem> items = <TimelineItem>[];
  final Map<String, int> toolIndexes = <String, int>{};
  final Map<String, int> activityIndexes = <String, int>{};
  final StringBuffer message = StringBuffer();
  final StringBuffer thought = StringBuffer();
  int? messageForkSeq;

  void flushMessage() {
    if (message.isEmpty) return;
    items.add(
      AgentMessageItem(text: message.toString(), forkSeq: messageForkSeq),
    );
    message.clear();
    messageForkSeq = null;
  }

  void flushThought({bool active = false}) {
    if (thought.isEmpty) return;
    items.add(AgentThoughtItem(text: thought.toString(), active: active));
    thought.clear();
  }

  for (final SessionEvent event in events) {
    switch (event) {
      case UserMessageEvent e:
        flushMessage();
        flushThought();
        items.add(
          UserMessageItem(
            text: e.text,
            attachments: e.attachments,
            forkSeq: e.seq,
          ),
        );
      case ImageEvent e:
        flushMessage();
        flushThought();
        items.add(DisplayedImageItem(attachment: e.attachment));
      case AgentMessageChunkEvent e:
        message.write(e.text);
        messageForkSeq = e.seq;
      case AgentThoughtChunkEvent e:
        thought.write(e.text);
      case ToolCallEvent e:
        flushMessage();
        flushThought();
        final int? existing = toolIndexes[e.toolCall.id];
        final bool reused =
            existing != null &&
            _isTerminalToolStatus(
              (items[existing] as ToolCallTimelineItem).toolCall.status,
            ) &&
            _isActiveToolStatus(e.toolCall.status);
        if (existing != null && !reused) {
          items[existing] = ToolCallTimelineItem(toolCall: e.toolCall);
        } else {
          toolIndexes[e.toolCall.id] = items.length;
          items.add(ToolCallTimelineItem(toolCall: e.toolCall));
        }
      case AgentActivityEvent e:
        flushMessage();
        flushThought();
        final int? existing = activityIndexes[e.activity.id];
        if (existing != null) {
          items[existing] = AgentActivityItem(activity: e.activity);
        } else {
          activityIndexes[e.activity.id] = items.length;
          items.add(AgentActivityItem(activity: e.activity));
        }
      case PlanEvent e:
        flushMessage();
        flushThought();
        items.add(PlanTimelineItem(entries: e.entries));
      case PermissionRequestEvent e:
        flushMessage();
        flushThought();
        items.add(PermissionRequestItem(request: e.request));
      case PermissionResolvedEvent e:
        flushMessage();
        flushThought();
        items.add(
          PermissionResolvedItem(requestId: e.requestId, optionId: e.optionId),
        );
      case UsageEvent _:
        // Surfaced in the composer footer, not the timeline.
        break;
      case TurnCompleteEvent e:
        flushMessage();
        flushThought();
        items.add(TurnCompleteItem(stopReason: e.stopReason));
      case SessionErrorEvent e:
        flushMessage();
        flushThought();
        items.add(SessionErrorItem(message: e.message));
    }
  }
  flushMessage();
  flushThought(
    active:
        running && events.isNotEmpty && events.last is AgentThoughtChunkEvent,
  );
  return items;
}

bool _isActiveToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => true,
  ToolCallStatus.completed || ToolCallStatus.failed => false,
};

bool _isTerminalToolStatus(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending || ToolCallStatus.running => false,
  ToolCallStatus.completed || ToolCallStatus.failed => true,
};

/// Virtualized, bottom-anchored timeline of a session's derived items.
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
  });

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
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void didUpdateWidget(Timeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.hasOlder && widget.hasOlder) ||
        (oldWidget.loadingOlder && !widget.loadingOlder)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  void _onScroll() {
    if (!mounted ||
        !_controller.hasClients ||
        !widget.hasOlder ||
        widget.loadingOlder ||
        widget.onLoadOlder == null) {
      return;
    }
    final ScrollPosition position = _controller.position;
    if (position.maxScrollExtent - position.pixels <= _loadThreshold) {
      widget.onLoadOlder!();
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int historyRows = widget.loadingOlder || widget.olderError != null
        ? 1
        : 0;
    return SelectionArea(
      child: ListView.builder(
        key: const Key('chat-timeline'),
        controller: _controller,
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: widget.items.length + historyRows,
        itemBuilder: (BuildContext context, int index) {
          if (index == widget.items.length && historyRows == 1) {
            return _OlderHistoryStatus(
              loading: widget.loadingOlder,
              error: widget.olderError,
              onRetry: widget.onLoadOlder,
            );
          }
          return _TimelineRow(
            item: widget.items[widget.items.length - 1 - index],
            attachmentLoader: widget.attachmentLoader,
            onFork: widget.onFork,
            openLocalFile: widget.openLocalFile,
          );
        },
      ),
    );
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
        child: AgentMessageView(text: i.text, openLocalFile: openLocalFile),
      ),
      AgentThoughtItem i => AgentThoughtView(text: i.text, active: i.active),
      ToolCallTimelineItem i => ToolCallCard(
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
    final Widget actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: buttons,
    );
    return Row(
      mainAxisAlignment: isUser
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: isUser
          ? <Widget>[actions, Flexible(child: child)]
          : <Widget>[Flexible(child: child), actions],
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
          key: ValueKey<String>('activity-${activity.id}'),
          leading: ActivePulse(
            active: activity.status == AgentActivityStatus.running,
            pulseKey: ValueKey<String>('activity-pulse-${activity.id}'),
            child: icon,
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(40, 0, 12, 10),
          dense: true,
          initiallyExpanded: activity.status == AgentActivityStatus.failed,
          title: ActivePulse(
            active: activity.status == AgentActivityStatus.running,
            pulseKey: ValueKey<String>('activity-pulse-${activity.id}'),
            child: Text(activity.title, style: theme.textTheme.bodySmall),
          ),
          subtitle: Text(
            activity.kind,
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
