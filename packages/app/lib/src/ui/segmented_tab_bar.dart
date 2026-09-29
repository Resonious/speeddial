import 'package:flutter/material.dart';

/// Height for [Tab]s placed in a [SegmentedTabBar].
const double kSegmentedTabHeight = 30;

/// A [TabBar] drawn as a segmented control: tabs sit in a recessed track and
/// the selected one is a raised chip (see `tabBarTheme` in theme.dart).
/// Used by the left rail and the right panel headers.
class SegmentedTabBar extends StatelessWidget {
  const SegmentedTabBar({super.key, required this.tabs, this.controller});

  /// Tabs should use [kSegmentedTabHeight] so they fit the track.
  final List<Widget> tabs;

  /// Falls back to the ambient [DefaultTabController] when null.
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: TabBar(controller: controller, tabs: tabs),
        ),
      ),
    );
  }
}
