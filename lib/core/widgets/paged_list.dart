import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'app_icon.dart';
import 'states.dart';

class PageResult<T> {
  const PageResult(this.rows, {this.next, this.total});
  final List<T> rows;

  /// Cursor/offset for the following page; null when there are no more rows.
  final Object? next;
  final int? total;
}

/// Lazily rendered, server-paginated list (offset or keyset cursor). Replies
/// for an older load are ignored, so a filter change can never be overwritten
/// by a slow earlier response (PAGE-003). Give it a new [key] when filters
/// change to restart from the first page.
class PagedList<T> extends StatefulWidget {
  const PagedList({
    super.key,
    required this.fetch,
    required this.itemBuilder,
    this.empty,
    this.loading,
    this.header,
    this.padding = const EdgeInsets.all(AppSpacing.page),
    this.separator = AppSpacing.sm,
  });

  final Future<PageResult<T>> Function(Object? cursor) fetch;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Widget? empty;
  final Widget? loading;
  final Widget? header;
  final EdgeInsets padding;
  final double separator;

  @override
  State<PagedList<T>> createState() => PagedListState<T>();
}

class PagedListState<T> extends State<PagedList<T>> {
  final _rows = <T>[];
  Object? _next;
  bool _done = false;
  bool _loading = false;
  Object? _error;
  int _seq = 0;
  int? total;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final seq = ++_seq;
    setState(() {
      _rows.clear();
      _next = null;
      _done = false;
      _error = null;
      _loading = true;
    });
    await _load(seq);
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    await _load(_seq);
  }

  Future<void> _load(int seq) async {
    try {
      final page = await widget.fetch(_next);
      if (!mounted || seq != _seq) return;
      setState(() {
        _rows.addAll(page.rows);
        _next = page.next;
        _done = page.next == null || page.rows.isEmpty;
        total = page.total ?? total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) {
      if (_error != null) return ErrorState(error: _error!, onRetry: reload);
      if (_loading) return widget.loading ?? const SkeletonList();
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(padding: widget.padding, children: [
          ?widget.header,
          widget.empty ?? const EmptyState(),
        ]),
      );
    }
    final headerCount = widget.header == null ? 0 : 1;
    return RefreshIndicator(
      onRefresh: reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
          return false;
        },
        child: ListView.builder(
          padding: widget.padding,
          itemCount: headerCount + _rows.length + 1,
          itemBuilder: (context, i) {
            if (i < headerCount) return widget.header!;
            final index = i - headerCount;
            if (index == _rows.length) {
              if (_error != null) {
                return Center(
                  child: TextButton.icon(
                      onPressed: _loadMore, icon: const AppIcon(Icons.refresh), label: const Text('Could not load more. Retry')),
                );
              }
              if (_done) return const SizedBox(height: AppSpacing.xl);
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
              );
            }
            return Padding(
              padding: EdgeInsets.only(bottom: widget.separator),
              child: widget.itemBuilder(context, _rows[index]),
            );
          },
        ),
      ),
    );
  }
}

/// Offset paging helper for `{rows, total, limit, offset}` responses.
PageResult<Map<String, dynamic>> offsetPage(Map<String, dynamic> data, int offset) {
  final rows = ((data['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  final total = (data['total'] as num?)?.toInt() ?? rows.length;
  final next = offset + rows.length;
  return PageResult(rows, next: next < total ? next : null, total: total);
}
