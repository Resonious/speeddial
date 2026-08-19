import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../scope.dart';
import '../theme.dart';
import 'chat/chat_pane.dart';
import 'left/left_rail.dart';
import 'right/right_panel.dart';

/// Width at which the three-column desktop layout kicks in.
const double kDesktopBreakpoint = 1000;

/// SpeedDial shell: three-column responsive control surface. Wide layouts get
/// left rail + chat + right panel in a row; narrow layouts get chat
/// full-screen with the rail in a drawer and the right panel in a bottom
/// sheet.
///
/// Android 15+ enforces edge-to-edge, so system bars overlay the app: pane
/// backgrounds deliberately extend under them (the drawer sliding under the
/// status bar is part of the look) while interactive content is padded off
/// the top/bottom insets — here for the bars/top bar, and inside the panes
/// ([LeftRail]'s bottom action, [ChatPane]'s composer, [RightPanel]'s root)
/// for everything that touches the bottom edge.
class SpeedDialShell extends StatelessWidget {
  const SpeedDialShell({super.key});

  @override
  Widget build(BuildContext context) {
    // Dark app on transparent system bars: light status/nav icons. The
    // narrow AppBar sets this for itself, but the wide layout has no AppBar.
    return const AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: _Shell(),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool _leftOpen = true;
  bool _rightOpen = true;
  final GlobalKey<ScaffoldState> _narrowScaffoldKey = GlobalKey<ScaffoldState>();

  /// Keeps the chat pane's element (and therefore its session watch, cache
  /// and composer draft) alive across wide↔narrow layout switches. Without
  /// it the pane remounts on every resize and a freshly recreated watch can
  /// be unwound by the old pane's `dispose` running later in the same
  /// frame, leaving the timeline empty.
  final GlobalKey _chatPaneKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= kDesktopBreakpoint;
        if (wide) {
          return Scaffold(
            body: Column(
              children: <Widget>[
                _DesktopTopBar(
                  leftOpen: _leftOpen,
                  rightOpen: _rightOpen,
                  onToggleLeft: () => setState(() => _leftOpen = !_leftOpen),
                  onToggleRight: () => setState(() => _rightOpen = !_rightOpen),
                ),
                Expanded(
                  // Side insets only (landscape cutouts); the top bar handles
                  // the top inset itself and the panes pad their own bottoms.
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_leftOpen) const SizedBox(width: 280, child: LeftRail()),
                        if (_leftOpen) const VerticalDivider(width: 1, thickness: 1),
                        Expanded(child: ChatPane(key: _chatPaneKey)),
                        if (_rightOpen) const VerticalDivider(width: 1, thickness: 1),
                        if (_rightOpen) const SizedBox(width: 360, child: RightPanel()),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          key: _narrowScaffoldKey,
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Open navigation menu',
              icon: const Icon(Icons.menu),
              onPressed: () => _narrowScaffoldKey.currentState?.openDrawer(),
            ),
            title: const Text('SpeedDial'),
            actions: <Widget>[
              const _DaemonStatusChip(),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Open right panel',
                icon: const Icon(Icons.tune),
                onPressed: () => _openRightSheet(context),
              ),
            ],
          ),
          // The drawer surface extends under the status bar; only its
          // content is padded down.
          drawer: const Drawer(
            child: SafeArea(
              bottom: false,
              left: false,
              right: false,
              child: LeftRail(),
            ),
          ),
          body: ChatPane(key: _chatPaneKey),
        );
      },
    );
  }

  void _openRightSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: const RightPanel(),
      ),
    );
  }
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({
    required this.leftOpen,
    required this.rightOpen,
    required this.onToggleLeft,
    required this.onToggleRight,
  });

  final bool leftOpen;
  final bool rightOpen;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: context.speedDialColors.border),
        ),
      ),
      // The bar's surface extends under the status bar (edge-to-edge); the
      // content sits below it.
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: 'Toggle left rail',
                icon: Icon(leftOpen ? Icons.menu_open : Icons.menu),
                onPressed: onToggleLeft,
              ),
              Text(
                'SpeedDial',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              const _DaemonStatusChip(),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Toggle right panel',
                icon: Icon(rightOpen ? Icons.chevron_right : Icons.tune),
                onPressed: onToggleRight,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status dot + label for the selected daemon; grey with "Not connected" when
/// nothing is selected.
class _DaemonStatusChip extends StatelessWidget {
  const _DaemonStatusChip();

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[data.connections, data.selection]),
      builder: (BuildContext context, Widget? _) {
        final String? id = data.selection.selectedDaemonId;
        final ConnectionStatus status = id == null
            ? ConnectionStatus.disconnected
            : data.connections.statusOf(id);
        return Tooltip(
          message: id == null ? 'No daemon selected' : status.name,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connectionStatusColor(context, status),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  id == null ? 'Not connected' : status.name,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
