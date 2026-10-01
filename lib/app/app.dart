import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/auth/session_controller.dart';
import '../core/push/push_service.dart';
import '../features/home/home_providers.dart';
import 'router.dart';
import 'theme.dart';

class HrmsApp extends ConsumerStatefulWidget {
  const HrmsApp({super.key});

  @override
  ConsumerState<HrmsApp> createState() => _HrmsAppState();
}

class _HrmsAppState extends ConsumerState<HrmsApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Returning from background re-validates the session/permissions and
    // refreshes live data (architecture §10).
    _lifecycle = AppLifecycleListener(onResume: () {
      final phase = ref.read(sessionProvider).phase;
      if (phase == SessionPhase.ready || phase == SessionPhase.unreachable) {
        ref.read(sessionProvider.notifier).refreshContext();
        ref.invalidate(homeSummaryProvider);
      }
    });
    // Push (optional): re-bind after sign-in, refresh counts on arrival, and
    // open the in-app route when a notification is tapped.
    ref.listenManual(sessionProvider, (prev, next) {
      if (next.phase == SessionPhase.ready && prev?.phase != SessionPhase.ready) {
        PushService.restore(ref.read(apiProvider));
      }
    });
    PushService.onForeground(() => ref.invalidate(homeSummaryProvider));
    PushService.onOpen((route) {
      if (ref.read(sessionProvider).phase == SessionPhase.ready) ref.read(routerProvider).push(route);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'HRMS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
