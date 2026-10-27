import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../scope.dart';
import '../state/pull_request_link_store.dart';

/// Native text/URL drops anywhere in the shell, including the composer.
class PullRequestDropRegion extends StatefulWidget {
  const PullRequestDropRegion({super.key, required this.child});
  final Widget child;

  @override
  State<PullRequestDropRegion> createState() => _PullRequestDropRegionState();
}

class _PullRequestDropRegionState extends State<PullRequestDropRegion> {
  static const MethodChannel _channel = MethodChannel('sh.speeddial/text-drop');
  bool _hover = false;
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    if (_supported) _channel.setMethodCallHandler(_receive);
  }

  Future<void> _receive(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'hover' && call.arguments is bool) {
      final bool hovering = call.arguments as bool;
      if (hovering != _hover) setState(() => _hover = hovering);
    } else if (call.method == 'text' && call.arguments is String) {
      if (_hover) setState(() => _hover = false);
      unawaited(
        AppScope.of(context).shares.pullRequests.open(call.arguments as String),
      );
    }
  }

  @override
  void dispose() {
    if (_supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      widget.child,
      if (_hover)
        const Positioned.fill(
          child: IgnorePointer(child: PullRequestDropHint()),
        ),
    ],
  );
}

/// A steady ember border marks an accepted drag; no idle animation or ticker.
class PullRequestDropHint extends StatelessWidget {
  const PullRequestDropHint({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.primary, width: 3),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          child: Card(
            color: colors.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                'Drop a GitHub PR link to find its session',
                style: TextStyle(color: colors.onPrimaryContainer),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PullRequestMatches extends StatelessWidget {
  const PullRequestMatches({super.key});

  @override
  Widget build(BuildContext context) {
    final PullRequestLinkStore links = AppScope.of(context).shares.pullRequests;
    return ListenableBuilder(
      listenable: links,
      builder: (context, _) {
        if (links.matches.length < 2) return const SizedBox.shrink();
        return Positioned.fill(
          child: Stack(
            children: <Widget>[
              ModalBarrier(
                dismissible: true,
                onDismiss: links.dismiss,
                color: Theme.of(context).colorScheme.scrim
                    .withValues(alpha: 0.4),
              ),
              Center(
                child: AlertDialog(
                  title: const Text('Sessions for this pull request'),
                  content: SizedBox(
                    width: 420,
                    child: ListView(
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final PullRequestMatch match in links.matches)
                          ListTile(
                            leading: Icon(
                              Icons.fork_right,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(match.session.title),
                            subtitle: Text(
                              '${match.daemon.name}${match.session.archived ? ' · Archived' : ''}',
                            ),
                            onTap: () => links.select(match),
                          ),
                      ],
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: links.dismiss,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
