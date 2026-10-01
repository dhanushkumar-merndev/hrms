import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// go_router 18 looks for the `material_ui` package's MaterialApp, not the
/// `flutter/material` one this app uses, so routes declared with `builder:`
/// silently fall back to a zero-duration NoTransitionPage. Building a
/// MaterialPage explicitly keeps the theme's slide transition on push and pop.
Page<void> materialPage(GoRouterState state, Widget child) => MaterialPage<void>(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: {...state.pathParameters, ...state.uri.queryParameters},
      restorationId: state.pageKey.value,
      child: child,
    );

/// A [GoRoute] whose page is always a [MaterialPage] (see [materialPage]).
class AppRoute extends GoRoute {
  AppRoute({required super.path, required GoRouterWidgetBuilder builder, super.routes})
      : super(pageBuilder: (_, state) => materialPage(state, Builder(builder: (context) => builder(context, state))));
}
