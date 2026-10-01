import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;

final _identityCaches = <KeepAliveLink>{};

/// Keeps an auto-dispose provider cached for [ttl] after its last listener.
/// Every such cache is identity-scoped: [dropIdentityCaches] releases it.
void cacheFor(Ref ref, Duration ttl) {
  final link = ref.keepAlive();
  _identityCaches.add(link);
  Timer? timer;
  ref.onCancel(() => timer = Timer(ttl, link.close));
  ref.onResume(() => timer?.cancel());
  ref.onDispose(() {
    timer?.cancel();
    _identityCaches.remove(link);
  });
}

/// Releases every identity-scoped cache (logout or account switch), so one
/// employee's data is never shown to the next person on the phone
/// (CACHE-001). Called directly by the session controller: in Riverpod 3 a
/// provider nobody listens to is paused and would not see a session change.
void dropIdentityCaches() {
  final links = [..._identityCaches];
  _identityCaches.clear();
  for (final link in links) {
    link.close();
  }
}
