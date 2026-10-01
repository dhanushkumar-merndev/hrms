import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/config.dart';
import 'core/api/api_exception.dart';
import 'core/auth/secure_session_storage.dart';
import 'core/auth/session_controller.dart';
import 'core/push/push_service.dart';
import 'core/time/org_time.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!AppConfig.isConfigured) {
    runApp(const _MisconfiguredApp());
    return;
  }
  OrgTime.init('Asia/Kolkata');
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseKey,
    authOptions: FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(),
      detectSessionInUri: false,
    ),
  );
  await SessionController.clearSensitiveTemp();
  await PushService.init();
  runApp(ProviderScope(
    // Only transient network failures are retried automatically; server
    // decisions (denied, validation, conflicts) are shown immediately.
    retry: (count, error) =>
        error is ApiException && error.isNetwork && count < 2 ? Duration(seconds: 1 << count) : null,
    child: const HrmsApp(),
  ));
}

class _MisconfiguredApp extends StatelessWidget {
  const _MisconfiguredApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This build is missing its server configuration.\n'
              'Build with: --dart-define-from-file=build/app_config.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
