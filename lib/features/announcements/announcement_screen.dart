import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../people/people_screen.dart';

/// S38 — simple announcement delivered as an in-app notification (plus
/// optional push). No feed, comments or reactions.
class AnnouncementScreen extends ConsumerStatefulWidget {
  const AnnouncementScreen({super.key});

  @override
  ConsumerState<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends ConsumerState<AnnouncementScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String? _teamId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _publish(String scope) async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Add a title');
      return;
    }
    final ok = await confirm(context,
        title: 'Send announcement?',
        message: 'It goes to $scope as an in-app notification. Lock-screen previews show the title and text, '
            'so do not include salary, medical or other private details.',
        confirmLabel: 'Send');
    if (!ok) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).rpc('publish_announcement', {
        'p_title': _title.text.trim(),
        'p_body': _body.text.trim().isEmpty ? null : _body.text.trim(),
        'p_team_id': _teamId,
      });
      if (!mounted) return;
      showMessage(context, 'Sent to ${res.map['recipients']} people.');
      context.pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final teams = structureList(ref.watch(orgStructureProvider).value, 'teams').where((t) => t['active'] == true).toList();
    final team = teams.where((t) => t['id'] == _teamId).firstOrNull;
    final scope = team == null ? 'everyone in the organisation' : 'the ${team['name']} team';
    return Scaffold(
      appBar: AppBar(title: const Text('New announcement')),
      body: PermissionGate(
        allowed: (s) => s.canAnnounce,
        child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: _title, maxLength: 120, decoration: const InputDecoration(labelText: 'Title')),
              TextField(
                  controller: _body, maxLength: 500, minLines: 3, maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Message (optional)')),
              DropdownButtonFormField<String?>(
                initialValue: _teamId,
                decoration: const InputDecoration(labelText: 'Send to'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Everyone')),
                  for (final t in teams) DropdownMenuItem(value: t['id'] as String, child: Text(t['name'] as String)),
                ],
                onChanged: (v) => setState(() => _teamId = v),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Recipients: $scope (active employees only).', style: Theme.of(context).textTheme.bodyMedium),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: const TextStyle(color: AppColors.error)),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _busy ? null : () => _publish(scope),
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Review & send'),
          ),
        ]),
      ),
    );
  }
}
