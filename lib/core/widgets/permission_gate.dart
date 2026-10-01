import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session_controller.dart';
import 'states.dart';

/// Wraps team, reviewer, payroll and admin screens. Permissions are
/// re-read from the server on entry and every 30 seconds while visible, so a
/// revoked grant removes the screen within that bound (CACHE-004). Offline,
/// protected detail is hidden rather than shown stale. The server still
/// authorises every call; this is presentation only.
class PermissionGate extends ConsumerStatefulWidget {
  const PermissionGate({super.key, required this.allowed, required this.child, this.hideOffline = true});

  final bool Function(SessionContext s) allowed;
  final Widget child;
  final bool hideOffline;

  @override
  ConsumerState<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends ConsumerState<PermissionGate> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  void _refresh() {
    if (mounted) ref.read(sessionProvider.notifier).refreshContext();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionContextProvider);
    if (session == null || !widget.allowed(session)) return const UnauthorizedState();
    final online = ref.watch(onlineProvider).value ?? true;
    if (widget.hideOffline && !online) {
      return const EmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'You are offline',
        message: 'Team, payroll and admin details are hidden until you reconnect.',
      );
    }
    return widget.child;
  }
}
