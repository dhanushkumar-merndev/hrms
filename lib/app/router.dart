import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/session_controller.dart';
import '../features/action/action_screen.dart';
import '../features/attendance/punch_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/password_change_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/explore/explore_screen.dart';
import '../features/home/home_screen.dart';
import 'app_routes.dart';
import 'shell.dart';

/// Route guards are UX only — every query and action is authorised by the
/// server. Guards route by the server-derived session phase.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final phase = ref.read(sessionProvider).phase;
      final loc = state.matchedLocation;
      switch (phase) {
        case SessionPhase.loading:
        case SessionPhase.unreachable:
          return loc == '/splash' ? null : '/splash';
        case SessionPhase.signedOut:
          return loc == '/login' ? null : '/login';
        case SessionPhase.mustChangePassword:
        case SessionPhase.credentialHold:
          return loc == '/password-change' ? null : '/password-change';
        case SessionPhase.ready:
          if (loc == '/splash' || loc == '/login' || loc == '/password-change') return '/home';
          return null;
      }
    },
    errorBuilder: (context, state) => NotAvailableScreen(path: state.uri.path),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/password-change', builder: (_, _) => const PasswordChangeScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/action', builder: (_, _) => const ActionScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/explore', builder: (_, _) => const ExploreScreen())]),
        ],
      ),
      GoRoute(path: '/punch', builder: (_, _) => const PunchScreen()),
      GoRoute(path: '/settings/password', builder: (_, _) => const PasswordChangeScreen(voluntary: true)),
      ...featureRoutes,
    ],
  );
});
