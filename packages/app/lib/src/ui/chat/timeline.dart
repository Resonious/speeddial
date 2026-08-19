import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'message_view.dart';
import 'plan_panel.dart';
import 'tool_call_card.dart';

/// A derived, display-ready row of the session timeline.
sealed class TimelineItem {
  const TimelineItem();
}

/// A user message (already complete; not streamed).
class UserMessageItem extends TimelineItem {
  const UserMessageItem({required this.text});
  final String text;
}

/// A merged run of consecutive agent message chunks.
class AgentMessageItem extends TimelineItem {
  const AgentMessageItem({required this.text});
  final String text;
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
/// text). Tool-call events replace the previous snapshot with the same id.
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
  final StringBuffer message = StringBuffer();
  final StringBuffer thought = StringBuffer();

  void flushMessage() {
    if (message.isEmpty) return;
    items.add(AgentMessageItem(text: message.toString()));
    message.clear();
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
        items.add(UserMessageItem(text: e.text));
      case AgentMessageChunkEvent e:
        message.write(e.text);
      case AgentThoughtChunkEvent e:
        thought.write(e.text);
      case ToolCallEvent e:
        flushMessage();
        flushThought();
        final int? existing = toolIndexes[e.toolCall.id];
        if (existing != null) {
          items[existing] = ToolCallTimelineItem(toolCall: e.toolCall);
        } else {
          toolIndexes[e.toolCall.id] = items.length;
          items.add(ToolCallTimelineItem(toolCall: e.toolCall));
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
    active: running &&
        events.isNotEmpty &&
        events.last is AgentThoughtChunkEvent,
  );
  return items;
}

/// Virtualized, bottom-anchored timeline of a session's derived items.
///
/// [items] is the [deriveTimelineItems] output for the session; callers
/// cache it per session revision so every chunk notification does not
/// re-scan the full raw event list.
class Timeline extends StatelessWidget {
  const Timeline({super.key, required this.items});

  final List<TimelineItem> items;

  @override
  Widget build(BuildContext context) {
    // SelectionArea makes every Text/RichText descendant (message bubbles,
    // markdown bodies, tool output, diffs, plan rows) selectable and
    // copyable; interactive widgets (expansion tiles, buttons) keep working.
    return SelectionArea(
      child: ListView.builder(
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        // reverse: true renders index 0 (the newest) at the bottom.
        itemBuilder: (BuildContext context, int index) =>
            _TimelineRow(item: items[items.length - 1 - index]),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.item});

  final TimelineItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserMessageItem i => UserMessageBubble(text: i.text),
      AgentMessageItem i => AgentMessageView(text: i.text),
      AgentThoughtItem i => AgentThoughtView(text: i.text, active: i.active),
      ToolCallTimelineItem i => ToolCallCard(toolCall: i.toolCall),
      PlanTimelineItem i => PlanPanel(entries: i.entries),
      PermissionRequestItem i => _InlinePermissionRecord(request: i.request),
      PermissionResolvedItem i => _ResolvedRecord(optionId: i.optionId),
      TurnCompleteItem _ => _TurnDivider(),
      SessionErrorItem i => _ErrorBanner(message: i.message),
    };
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
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}
