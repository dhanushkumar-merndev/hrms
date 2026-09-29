import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';

/// Keeps an auto-dispose provider cached for [ttl] after its last listener.
void cacheFor(Ref ref, Duration ttl) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() => timer = Timer(ttl, link.close));
  ref.onResume(() => timer?.cancel());
  ref.onDispose(() => timer?.cancel());
}

/// One request for the whole Home screen (architecture §10).
final homeSummaryProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final session = ref.watch(sessionContextProvider);
  if (session == null) throw StateError('not signed in');
  cacheFor(ref, const Duration(seconds: 30));
  final res = await ref.read(apiProvider).rpc('get_home_summary');
  final data = res.map;
  OrgTime.init(((data['org'] as Map?)?['timezone'] as String?) ?? session.timezone);
  return data;
});
