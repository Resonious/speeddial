import 'package:flutter/material.dart';

/// A lazy rail list with a still edge marker pointing toward its selection.
/// The builder marks the selected row with [RailSelectionTarget] (possibly nested
/// inside an expanded project). Unmounted rows are located by list order.
class SelectedItemScrollView extends StatefulWidget {
  const SelectedItemScrollView({
    super.key,
    required this.selectedIndex,
    required this.itemLabel,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
  });

  final int selectedIndex;
  final String itemLabel;
  final int itemCount;
  final Widget Function(BuildContext, int, bool selected) itemBuilder;
  final EdgeInsets padding;
  final bool shrinkWrap;

  @override
  State<SelectedItemScrollView> createState() => _SelectedItemScrollViewState();
}

class _SelectedItemScrollViewState extends State<SelectedItemScrollView> {
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  final GlobalKey _viewport = GlobalKey();
  GlobalKey? _selected;
  final Map<int, GlobalKey> _rows = <int, GlobalKey>{};
  final ValueNotifier<int> _direction = ValueNotifier<int>(0);
  bool _scheduled = false;
  bool _seeking = false;
  final ValueNotifier<int> _jumpRevision = ValueNotifier<int>(0);
  int _anchorIndex = 0;

  void _revealSelection() {
    _seeking = true;
    _measure();
  }

  void _cancelSeek() => _seeking = false;

  /// A mounted target can be aligned directly. Otherwise rebuild the lazy
  /// viewport around its index, avoiding a pixel jump that would lay out every
  /// skipped variable-height row. The next layout supplies the exact target.
  void _advanceSeek(RenderBox viewport) {
    if (!_scroll.hasClients) return;
    final RenderObject? target = _selected?.currentContext?.findRenderObject();
    if (target is RenderBox && target.attached && target.hasSize) {
      _seeking = false;
      _scroll.position.ensureVisible(
        target,
        alignment: 0.5,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      return;
    }
    _anchorIndex = widget.selectedIndex;
    _jumpRevision.value++;
  }

  Widget _row(BuildContext context, int index) {
    _scheduleMeasure();
    return SizeChangedLayoutNotifier(
      key: _rows.putIfAbsent(index, GlobalKey.new),
      child: widget.itemBuilder(context, index, index == widget.selectedIndex),
    );
  }

  Widget _list(BuildContext context) {
    // Configured daemon lists are short and shrink to their content. Keeping
    // these rows mounted also makes every selection immediately measurable.
    if (widget.shrinkWrap) {
      return SingleChildScrollView(
        controller: _scroll,
        padding: widget.padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int index = 0; index < widget.itemCount; index++)
              _row(context, index),
          ],
        ),
      );
    }
    final int anchor = _anchorIndex.clamp(0, widget.itemCount);
    const Key center = ValueKey<String>('rail-scroll-center');
    return CustomScrollView(
      key: ValueKey<String>('rail-jump-${_jumpRevision.value}'),
      controller: _scroll,
      center: center,
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.only(
            top: widget.padding.top,
            left: widget.padding.left,
            right: widget.padding.right,
          ),
          sliver: SliverList.builder(
            itemCount: anchor,
            itemBuilder: (BuildContext context, int index) =>
                _row(context, anchor - index - 1),
          ),
        ),
        SliverPadding(
          key: center,
          padding: EdgeInsets.only(
            bottom: widget.padding.bottom,
            left: widget.padding.left,
            right: widget.padding.right,
          ),
          sliver: SliverList.builder(
            itemCount: widget.itemCount - anchor,
            itemBuilder: (BuildContext context, int index) =>
                _row(context, anchor + index),
          ),
        ),
      ],
    );
  }

  @override
  void didUpdateWidget(SelectedItemScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.itemCount != widget.itemCount) {
      _cancelSeek();
      if (_anchorIndex > 0 &&
          (_anchorIndex >= widget.itemCount || widget.selectedIndex < 0)) {
        _anchorIndex = 0;
        _jumpRevision.value++;
      }
    }
  }

  void _scheduleMeasure() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _measure();
    });
  }

  Rect? _bounds(GlobalKey key, RenderBox viewport) {
    final RenderObject? object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object.localToGlobal(Offset.zero, ancestor: viewport) & object.size;
  }

  void _measure() {
    _rows.removeWhere((int _, GlobalKey key) => key.currentContext == null);
    final RenderBox? viewport =
        _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null ||
        widget.selectedIndex < 0 ||
        widget.selectedIndex >= widget.itemCount) {
      _cancelSeek();
      _direction.value = 0;
      return;
    }
    if (_seeking) _advanceSeek(viewport);
    final Rect? selected = _selected == null
        ? null
        : _bounds(_selected!, viewport);
    if (selected != null) {
      // A partly clipped row also merits a pointer. A row larger than the
      // viewport is already in view when it covers the entire viewport.
      _direction.value =
          selected.top < -0.5 && selected.bottom < viewport.size.height
          ? -1
          : selected.bottom > viewport.size.height + 0.5 && selected.top > 0
          ? 1
          : 0;
      return;
    }
    for (final MapEntry<int, GlobalKey> entry in _rows.entries) {
      final Rect? bounds = _bounds(entry.value, viewport);
      if (bounds == null ||
          bounds.bottom <= 0 ||
          bounds.top >= viewport.size.height) {
        continue;
      }
      _direction.value = widget.selectedIndex.compareTo(entry.key);
      return;
    }
    _direction.value = 0;
  }

  @override
  void dispose() {
    _jumpRevision.dispose();
    _scroll.dispose();
    _direction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleMeasure();
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _scheduleMeasure();
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _scheduleMeasure();
            return false;
          },
          child: Stack(
            key: _viewport,
            children: <Widget>[
              Listener(
                onPointerDown: (_) => _cancelSeek(),
                onPointerSignal: (_) => _cancelSeek(),
                child: ValueListenableBuilder<int>(
                  valueListenable: _jumpRevision,
                  builder: (BuildContext context, int _, Widget? child) =>
                      _list(context),
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: _direction,
                builder: (BuildContext context, int direction, Widget? _) {
                  if (direction == 0) return const SizedBox.shrink();
                  final ColorScheme scheme = Theme.of(context).colorScheme;
                  final String label =
                      'Selected ${widget.itemLabel} '
                      '${direction < 0 ? 'above' : 'below'}';
                  return Positioned(
                    top: direction < 0 ? 2 : null,
                    bottom: direction > 0 ? 2 : null,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Semantics(
                        label: label,
                        child: Material(
                          color: scheme.surfaceContainerHighest,
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: IconButton(
                            tooltip: 'Show selected ${widget.itemLabel}',
                            onPressed: _revealSelection,
                            padding: const EdgeInsets.all(5),
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            icon: Icon(
                              direction < 0
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 16,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps its measurement key stable when selection changes, so selecting a row
/// does not remount its title animation, menus or other stateful descendants.
class RailSelectionTarget extends StatefulWidget {
  const RailSelectionTarget({
    super.key,
    required this.selected,
    required this.child,
  });

  final bool selected;
  final Widget child;

  @override
  State<RailSelectionTarget> createState() => _RailSelectionTargetState();
}

class _RailSelectionTargetState extends State<RailSelectionTarget> {
  final GlobalKey _key = GlobalKey();
  _SelectedItemScrollViewState? _list;

  void _sync() {
    final _SelectedItemScrollViewState? list = _list;
    if (list == null) return;
    if (widget.selected) {
      list._selected = _key;
    } else if (identical(list._selected, _key)) {
      list._selected = null;
    }
    list._scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = context.findAncestorStateOfType<_SelectedItemScrollViewState>();
    _sync();
  }

  @override
  void didUpdateWidget(RailSelectionTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    if (identical(_list?._selected, _key)) {
      _list?._selected = null;
      _list?._scheduleMeasure();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}
