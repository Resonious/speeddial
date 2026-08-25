import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/chat_store.dart';
import 'wear_scaffold.dart';

/// Compact live conversation for one session.
class WearChatPage extends StatefulWidget {
  const WearChatPage({
    super.key,
    required this.data,
    required this.daemonId,
    required this.sessionId,
  });

  final AppData data;
  final String daemonId;
  final String sessionId;

  @override
  State<WearChatPage> createState() => _WearChatPageState();
}

class _WearChatPageState extends State<WearChatPage> {
  late final TextEditingController _composer;
  final FocusNode _composerFocus = FocusNode();
  int _revision = -1;
  List<_WearTimelineItem> _items = const <_WearTimelineItem>[];
  PermissionRequest? _permission;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _composer = TextEditingController(
      text: widget.data.drafts.textFor(widget.daemonId, widget.sessionId),
    )..addListener(_saveDraft);
    widget.data.chat.watchSession(widget.daemonId, widget.sessionId);
  }

  @override
  void dispose() {
    widget.data.chat.unwatch(widget.sessionId);
    _composer
      ..removeListener(_saveDraft)
      ..dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.data.chat.send(widget.daemonId, widget.sessionId, text);
      _composer.clear();
      _composerFocus.requestFocus();
    } on Object catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _saveDraft() {
    unawaited(_persistDraft(_composer.text));
  }

  Future<void> _persistDraft(String text) async {
    try {
      await widget.data.drafts.setText(widget.daemonId, widget.sessionId, text);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _stop() async {
    try {
      await widget.data.chat.cancel(widget.daemonId, widget.sessionId);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _respond(PermissionOption option) async {
    final PermissionRequest? permission = _permission;
    if (permission == null) return;
    try {
      await widget.data.chat.respondPermission(
        widget.daemonId,
        widget.sessionId,
        permission.requestId,
        option.optionId,
      );
    } on Object catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(wearErrorText(error), maxLines: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ChatStore chat = widget.data.chat;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[chat, widget.data.sessions]),
      builder: (BuildContext context, Widget? _) {
        final Session? session = widget.data.sessions.byId(widget.sessionId);
        final SessionStatus status = chat.statusOf(widget.sessionId);
        final List<SessionEvent> events = chat.eventsFor(widget.sessionId);
        final int revision = chat.revisionFor(widget.sessionId);
        if (_revision != revision) {
          _revision = revision;
          _items = _deriveWearTimeline(events);
          _permission = _latestPermission(events);
        }
        return WearScaffold(
          title: session?.title ?? 'Session',
          showBack: true,
          child: Column(
            children: <Widget>[
              Expanded(
                child: _WearTimeline(
                  items: _items,
                  historyStatus: chat.historyStatusFor(widget.sessionId),
                  hasOlder: chat.hasOlderHistory(widget.sessionId),
                  loadingOlder: chat.isLoadingOlderHistory(widget.sessionId),
                  onLoadOlder: () {
                    unawaited(
                      chat.loadOlderHistory(widget.daemonId, widget.sessionId),
                    );
                  },
                  onRetry: () =>
                      chat.retryHistory(widget.daemonId, widget.sessionId),
                ),
              ),
              if (_permission != null)
                _WearPermissionBar(request: _permission!, onSelected: _respond),
              _WearComposer(
                controller: _composer,
                focusNode: _composerFocus,
                status: status,
                sending: _sending,
                onSend: _send,
                onStop: _stop,
              ),
            ],
          ),
        );
      },
    );
  }
}

sealed class _WearTimelineItem {
  const _WearTimelineItem();
}

class _WearMessageItem extends _WearTimelineItem {
  const _WearMessageItem({required this.text, required this.user});

  final String text;
  final bool user;
}

class _WearActivityItem extends _WearTimelineItem {
  const _WearActivityItem({required this.text, required this.icon});

  final String text;
  final IconData icon;
}

class _WearErrorItem extends _WearTimelineItem {
  const _WearErrorItem(this.text);

  final String text;
}

List<_WearTimelineItem> _deriveWearTimeline(List<SessionEvent> events) {
  final List<_WearTimelineItem> result = <_WearTimelineItem>[];
  for (final SessionEvent event in events) {
    switch (event) {
      case UserMessageEvent(:final text, :final attachments):
        final String display = text.isNotEmpty
            ? text
            : attachments.length == 1
            ? 'Sent an attachment'
            : 'Sent ${attachments.length} attachments';
        result.add(_WearMessageItem(text: display, user: true));
      case AgentMessageChunkEvent(:final text):
        if (text.isNotEmpty) {
          result.add(_WearMessageItem(text: text, user: false));
        }
      case AgentThoughtChunkEvent():
        if (result.isEmpty ||
            result.last is! _WearActivityItem ||
            (result.last as _WearActivityItem).text != 'Thinking…') {
          result.add(
            const _WearActivityItem(
              text: 'Thinking…',
              icon: Icons.psychology_outlined,
            ),
          );
        }
      case ToolCallEvent(:final toolCall):
        result.add(
          _WearActivityItem(
            text: '${toolCall.title} · ${toolCall.status.wire}',
            icon: Icons.build_outlined,
          ),
        );
      case PlanEvent(:final entries):
        result.add(
          _WearActivityItem(
            text: 'Plan updated · ${entries.length} steps',
            icon: Icons.checklist,
          ),
        );
      case ImageEvent():
        result.add(
          const _WearActivityItem(
            text: 'Image available in the full app',
            icon: Icons.image_outlined,
          ),
        );
      case SessionErrorEvent(:final message):
        result.add(_WearErrorItem(message));
      case AgentActivityEvent(:final activity):
        result.add(_WearActivityItem(text: activity.title, icon: Icons.sync));
      case PermissionRequestEvent() ||
          PermissionResolvedEvent() ||
          UsageEvent() ||
          TurnCompleteEvent():
        break;
    }
  }
  return result;
}

PermissionRequest? _latestPermission(List<SessionEvent> events) {
  final Set<String> resolved = <String>{};
  for (int index = events.length - 1; index >= 0; index--) {
    switch (events[index]) {
      case PermissionRequestEvent(:final request):
        if (!resolved.contains(request.requestId)) return request;
      case PermissionResolvedEvent(:final requestId):
        resolved.add(requestId);
      default:
        break;
    }
  }
  return null;
}

class _WearTimeline extends StatefulWidget {
  const _WearTimeline({
    required this.items,
    required this.historyStatus,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.onRetry,
  });

  final List<_WearTimelineItem> items;
  final HistoryStatus historyStatus;
  final bool hasOlder;
  final bool loadingOlder;
  final VoidCallback onLoadOlder;
  final VoidCallback onRetry;

  @override
  State<_WearTimeline> createState() => _WearTimelineState();
}

class _WearTimelineState extends State<_WearTimeline> {
  ScrollController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollController controller = PrimaryScrollController.of(context);
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onScroll);
    _controller = controller..addListener(_onScroll);
  }

  @override
  void didUpdateWidget(_WearTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.hasOlder && widget.hasOlder) ||
        (oldWidget.loadingOlder && !widget.loadingOlder)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  void _onScroll() {
    final ScrollController? controller = _controller;
    if (controller == null ||
        !controller.hasClients ||
        !widget.hasOlder ||
        widget.loadingOlder) {
      return;
    }
    if (controller.position.maxScrollExtent - controller.position.pixels <=
        160) {
      widget.onLoadOlder();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty && widget.historyStatus == HistoryStatus.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.items.isEmpty && widget.historyStatus == HistoryStatus.failed) {
      return WearEmptyState(
        message: 'Could not load history',
        icon: Icons.cloud_off,
        action: FilledButton(
          onPressed: widget.onRetry,
          child: const Text('Retry'),
        ),
      );
    }
    if (widget.items.isEmpty) {
      return const WearEmptyState(
        message: 'Start the conversation',
        icon: Icons.chat_bubble_outline,
      );
    }
    return ListView.builder(
      key: const Key('wear-chat-timeline'),
      controller: _controller,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      itemCount: widget.items.length + (widget.loadingOlder ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index == widget.items.length) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final _WearTimelineItem item =
            widget.items[widget.items.length - 1 - index];
        return switch (item) {
          _WearMessageItem() => _WearMessageBubble(item: item),
          _WearActivityItem() => _WearActivityRow(item: item),
          _WearErrorItem() => _WearErrorRow(item: item),
        };
      },
    );
  }
}

class _WearMessageBubble extends StatelessWidget {
  const _WearMessageBubble({required this.item});

  final _WearMessageItem item;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Align(
      alignment: item.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 190),
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: item.user ? colors.primary : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          item.text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: item.user ? colors.onPrimary : colors.onSurface,
          ),
        ),
      ),
    );
  }
}

class _WearActivityRow extends StatelessWidget {
  const _WearActivityRow({required this.item});

  final _WearActivityItem item;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
      child: Row(
        children: <Widget>[
          Icon(item.icon, size: 14, color: color),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              item.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _WearErrorRow extends StatelessWidget {
  const _WearErrorRow({required this.item});

  final _WearErrorItem item;

  @override
  Widget build(BuildContext context) {
    final Color error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Text(
        item.text,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: error),
      ),
    );
  }
}

class _WearPermissionBar extends StatelessWidget {
  const _WearPermissionBar({required this.request, required this.onSelected});

  final PermissionRequest request;
  final ValueChanged<PermissionOption> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('wear-permission'),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            request.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: request.options.length,
              separatorBuilder: (_, _) => const SizedBox(width: 5),
              itemBuilder: (BuildContext context, int index) {
                final PermissionOption option = request.options[index];
                return TextButton(
                  onPressed: () => onSelected(option),
                  child: Text(option.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WearComposer extends StatelessWidget {
  const _WearComposer({
    required this.controller,
    required this.focusNode,
    required this.status,
    required this.sending,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final SessionStatus status;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final bool running = status == SessionStatus.running;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth <= 260;
        final double sideInset = compact ? constraints.maxWidth * 0.16 : 2;
        return Padding(
          padding: EdgeInsets.only(
            top: 4,
            left: sideInset,
            right: sideInset,
            bottom: compact ? 16 : 6,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('wear-message-field'),
                  controller: controller,
                  focusNode: focusNode,
                  enabled:
                      !running && !sending && status != SessionStatus.closed,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  style: Theme.of(context).textTheme.bodySmall,
                  decoration: InputDecoration(
                    hintText: running ? 'Agent is working…' : 'Message',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox.square(
                dimension: 42,
                child: IconButton.filled(
                  key: Key(running ? 'wear-stop' : 'wear-send'),
                  tooltip: running ? 'Stop' : 'Send',
                  padding: EdgeInsets.zero,
                  onPressed: sending
                      ? null
                      : running
                      ? onStop
                      : onSend,
                  icon: sending
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          running ? Icons.stop : Icons.arrow_upward,
                          size: 20,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
