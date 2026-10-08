import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import '../flame.dart';
import 'history_expansion.dart';
import 'timeline.dart';

/// "3 subagents".
String subagentCount(int count) => '$count subagent${count == 1 ? '' : 's'}';

/// A little flame per subagent, flaring each time it reports; past [shown]
/// the rest are counted. [cold] flames are grey and still: the crew is done.
class CrewFlames extends StatelessWidget {
  const CrewFlames({super.key, required this.subagents, this.cold = false});

  final List<Subagent> subagents;
  final bool cold;

  static const int shown = 4;

  @override
  Widget build(BuildContext context) {
    final int extra = subagents.length - shown;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < subagents.length && i < shown; i++)
          _MiniFlame(
            key: ValueKey<int>(i),
            reports: subagents[i].updates.length,
            working: !subagents[i].finished,
            cold: cold,
            phase: i * 0.31,
          ),
        if (extra > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '+$extra',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _MiniFlame extends StatefulWidget {
  const _MiniFlame({
    super.key,
    required this.reports,
    required this.working,
    required this.cold,
    required this.phase,
  });

  /// How many updates its subagent has sent; each new one flares it.
  final int reports;

  /// Not yet reported finished: burns rather than idling as a pilot light.
  final bool working;
  final bool cold;
  final double phase;

  @override
  State<_MiniFlame> createState() => _MiniFlameState();
}

class _MiniFlameState extends State<_MiniFlame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flare = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _scale = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1,
          end: 1.5,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.5,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 70,
      ),
    ],
  ).animate(_flare);

  @override
  void didUpdateWidget(_MiniFlame oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.reports > oldWidget.reports && !widget.cold && !still) {
      _flare.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flare.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: ScaleTransition(
        scale: _scale,
        alignment: Alignment.bottomCenter,
        child: Flame(
          size: 13,
          phase: widget.phase,
          intensity: widget.working
              ? FlameIntensity.blaze
              : FlameIntensity.pilot,
          dormant: widget.cold,
        ),
      ),
    );
  }
}

/// The turn's subagents as a little spot at the end of its flame row: a
/// flame for each, flaring as it reports, and how many there are. Tapping
/// it opens the list (shown by the row).
class CrewSpot extends StatelessWidget {
  const CrewSpot({
    super.key,
    required this.subagents,
    required this.open,
    required this.onTap,
  });

  final List<Subagent> subagents;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      key: const Key('crew-spot'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CrewFlames(subagents: subagents),
            const SizedBox(width: 6),
            Text(
              subagentCount(subagents.length),
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                fontWeight: FontWeight.w500,
              ),
            ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.expand_more, size: 16, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A finished turn's subagents on one line at its end — their flames gone
/// cold, how many there were and how much they reported — opening to the
/// list.
class SubagentCrewRow extends StatefulWidget {
  const SubagentCrewRow({super.key, required this.crew});

  final SubagentCrewItem crew;

  @override
  State<SubagentCrewRow> createState() => _SubagentCrewRowState();
}

class _SubagentCrewRowState extends State<SubagentCrewRow> {
  bool _open = false;

  // Explicit page-storage identifiers are shared by the whole bucket, so
  // this one carries the row's own key.
  Object get _openId => ('crew-open', widget.key);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _openId);
    if (saved is bool) _open = saved;
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      PageStorage.maybeOf(context)
          ?.writeState(context, _open, identifier: _openId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final SubagentCrewItem crew = widget.crew;
    final int updates = crew.updates;
    final Widget list = _open
        ? SubagentList(subagents: crew.subagents)
        : const SizedBox(width: double.infinity);
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: const Key('crew-row'),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
              child: Row(
                children: <Widget>[
                  CrewFlames(subagents: crew.subagents, cold: true),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${subagentCount(crew.subagents.length)}'
                      '${updates > 0 ? ' · $updates update${updates == 1 ? '' : 's'}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more, size: 18, color: muted),
                  ),
                ],
              ),
            ),
          ),
          // AnimatedSize cannot take no time (it would relayout itself in
          // the middle of its own layout), so a still list just appears.
          if (still)
            list
          else
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: list,
            ),
        ],
      ),
    );
  }
}

/// Each subagent with what it reported, one line apiece until opened.
class SubagentList extends StatelessWidget {
  const SubagentList({super.key, required this.subagents, this.live = false});

  final List<Subagent> subagents;

  /// The turn is still running: flames burn rather than lie cold.
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < subagents.length; i++)
            _SubagentTile(
              key: ValueKey<int>(i),
              subagent: subagents[i],
              live: live,
              phase: i * 0.31,
            ),
        ],
      ),
    );
  }
}

class _SubagentTile extends StatefulWidget {
  const _SubagentTile({
    super.key,
    required this.subagent,
    required this.live,
    required this.phase,
  });

  final Subagent subagent;
  final bool live;
  final double phase;

  @override
  State<_SubagentTile> createState() => _SubagentTileState();
}

class _SubagentTileState extends State<_SubagentTile> {
  bool _open = false;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// What an update says beyond its title: not the subagent's own path or
  /// an opaque id, which every update of it repeats.
  Iterable<String> _said(AgentActivity update) => update.details.where(
    (String detail) =>
        !_uuid.hasMatch(detail.trim()) &&
        !detail.endsWith('/${widget.subagent.name}'),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final Subagent subagent = widget.subagent;
    final int count = subagent.updates.length;
    final String status = switch (subagent.status) {
      AgentActivityStatus.running => 'Working',
      AgentActivityStatus.failed => 'Failed',
      AgentActivityStatus.completed => count == 0 ? 'Done' : '',
    };
    final String summary = <String>[
      if (status.isNotEmpty) status,
      if (count > 0) '$count update${count == 1 ? '' : 's'}',
      ?subagent.updates.lastOrNull?.title,
    ].join(' · ');
    final bool hasMore = count > 0 || (subagent.report?.isNotEmpty ?? false);
    final TextStyle? detailStyle = theme.textTheme.bodySmall?.copyWith(
      color: muted,
    );
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final String report = subagent.report ?? '';
    final Widget details = _open && hasMore
        ? Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final AgentActivity update in subagent.updates)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: update.title,
                            style: TextStyle(
                              color: update.status == AgentActivityStatus.failed
                                  ? colors.error
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          for (final String detail in _said(update))
                            TextSpan(text: '\n$detail'),
                        ],
                      ),
                      style: detailStyle,
                    ),
                  ),
                if (report.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(report, style: detailStyle),
                  ),
              ],
            ),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: hasMore ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            child: Row(
              children: <Widget>[
                Flame(
                  size: 13,
                  phase: widget.phase,
                  intensity: subagent.finished
                      ? FlameIntensity.pilot
                      : FlameIntensity.blaze,
                  dormant: !widget.live,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text.rich(
                        TextSpan(
                          text: subagent.name,
                          children: <InlineSpan>[
                            if (subagent.kind.isNotEmpty)
                              TextSpan(
                                text: '  ${subagent.kind}',
                                style: TextStyle(
                                  color: muted,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (summary.isNotEmpty)
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: subagent.status == AgentActivityStatus.failed
                                ? colors.error
                                : muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasMore)
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more, size: 16, color: muted),
                  ),
              ],
            ),
          ),
        ),
        if (still || !animateHistoryDetails(<String>[report]))
          details
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: details,
          ),
      ],
    );
  }
}
