import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/location/location_service.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import '../people/people_screen.dart';

final officesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_offices')).list;
});

/// S31 — office geofences. Each configuration change is versioned and every
/// punch records the version it was checked against. Values are drafts until
/// a physical on-site pilot confirms them.
class OfficesScreen extends ConsumerWidget {
  const OfficesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(officesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Offices')),
      floatingActionButton: (ref.watch(sessionContextProvider)?.isAdmin ?? false)
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(context, ref, null),
              icon: const AppIcon(Icons.add_location_alt_outlined),
              label: const Text('Add office'),
            )
          : null,
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(officesProvider),
          isEmpty: (rows) => rows.isEmpty,
          empty: const EmptyState(
            icon: Icons.location_city_outlined,
            title: 'No offices yet',
            message: 'Add an office before anyone can punch. Stand at the office to capture its location.',
          ),
          builder: (rows) => ListView(padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 96), children: [
            for (final o in rows)
              Card(
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                  onTap: () => _openEditor(context, ref, o),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(o['name'] as String, style: Theme.of(context).textTheme.titleSmall)),
                        StatusChip(o['active'] == true ? 'Active' : 'Inactive',
                            tone: o['active'] == true ? ChipTone.success : ChipTone.neutral),
                      ]),
                      const SizedBox(height: AppSpacing.sm),
                      KeyValueRow('Location', '${(o['latitude'] as num).toStringAsFixed(6)}, '
                          '${(o['longitude'] as num).toStringAsFixed(6)}'),
                      KeyValueRow('Geofence', '${o['radius_m']} m radius · accuracy ≤ ${o['max_accuracy_m']} m · '
                          'reading ≤ ${o['max_sample_age_s']} s old${o['strict_mode'] == true ? ' · strict' : ''}'),
                      KeyValueRow('Site test', switch (o['calibration_status']) {
                        'verified' => 'Verified on site',
                        'piloting' => 'Pilot in progress',
                        _ => 'Not tested on site yet',
                      }),
                      KeyValueRow('Assigned', '${o['assigned_count']} people · config v${o['config_version']}'),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  static Future<void> _openEditor(BuildContext context, WidgetRef ref, Map<String, dynamic>? office) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => OfficeEditor(office: office)));
    if (saved == true) {
      ref.invalidate(officesProvider);
      ref.invalidate(orgStructureProvider);
    }
  }
}

class OfficeEditor extends ConsumerStatefulWidget {
  const OfficeEditor({super.key, this.office});
  final Map<String, dynamic>? office;

  @override
  ConsumerState<OfficeEditor> createState() => _OfficeEditorState();
}

class _OfficeEditorState extends ConsumerState<OfficeEditor> {
  late final Map<String, dynamic> o = widget.office ?? const {};
  late final _name = TextEditingController(text: o['name'] as String?);
  late final _tz = TextEditingController(text: (o['timezone'] as String?) ?? 'Asia/Kolkata');
  late final _lat = TextEditingController(text: (o['latitude'] as num?)?.toStringAsFixed(7));
  late final _lng = TextEditingController(text: (o['longitude'] as num?)?.toStringAsFixed(7));
  late final _radius = TextEditingController(text: '${o['radius_m'] ?? 20}');
  late final _accuracy = TextEditingController(text: '${o['max_accuracy_m'] ?? 15}');
  late final _age = TextEditingController(text: '${o['max_sample_age_s'] ?? 10}');
  late final _notes = TextEditingController(text: o['calibration_notes'] as String?);
  late bool _strict = o['strict_mode'] == true;
  late bool _active = o['active'] as bool? ?? true;
  late String _calibration = (o['calibration_status'] as String?) ?? 'untested';
  Map<String, String> _errors = const {};
  String? _error;
  String? _fix;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _tz, _lat, _lng, _radius, _accuracy, _age, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    const location = LocationService();
    final access = await location.request();
    if (access != LocationAccess.granted) {
      if (mounted) showMessage(context, 'Allow precise location for this app to capture the office position.', error: true);
      return;
    }
    setState(() => _fix = 'Getting a precise location…');
    try {
      final p = await location.freshSample(timeout: const Duration(seconds: 20));
      setState(() {
        _lat.text = p.latitude.toStringAsFixed(7);
        _lng.text = p.longitude.toStringAsFixed(7);
        _fix = 'Captured with ±${p.accuracy.toStringAsFixed(1)} m accuracy. Repeat outdoors or near the entrance if this is '
            'more than the allowed accuracy.';
      });
    } catch (_) {
      setState(() => _fix = 'Could not get a precise fix. Move near a window or outdoors and try again.');
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _errors = const {};
    });
    try {
      await ref.read(apiProvider).rpc('save_office', {
        'p_id': o['id'],
        'p_name': _name.text.trim(),
        'p_timezone': _tz.text.trim().isEmpty ? null : _tz.text.trim(),
        'p_latitude': double.tryParse(_lat.text.trim()),
        'p_longitude': double.tryParse(_lng.text.trim()),
        'p_radius_m': num.tryParse(_radius.text.trim()),
        'p_max_accuracy_m': num.tryParse(_accuracy.text.trim()),
        'p_max_sample_age_s': int.tryParse(_age.text.trim()),
        'p_strict_mode': _strict,
        'p_active': _active,
        'p_calibration_status': _calibration,
        'p_calibration_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        'p_expected_version': o['version'],
      });
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _errors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    TextField num(TextEditingController c, String label, String key, {String? helper}) => TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: label, errorText: _errors[key], helperText: helper),
        );
    return Scaffold(
      appBar: AppBar(title: Text(o.isEmpty ? 'Add office' : 'Edit office')),
      body: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, maxLength: 120,
                decoration: InputDecoration(labelText: 'Office name', errorText: _errors['name'])),
            TextField(controller: _tz, decoration: InputDecoration(labelText: 'Time zone', errorText: _errors['timezone'],
                helperText: 'IANA name, e.g. Asia/Kolkata')),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Location', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            Row(children: [
              Expanded(child: num(_lat, 'Latitude', 'latitude')),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: num(_lng, 'Longitude', 'longitude')),
            ]),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: _busy ? null : _useCurrentLocation,
              icon: const AppIcon(Icons.my_location_rounded),
              label: const Text('Use my current location'),
            ),
            if (_fix != null) Text(_fix!, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Geofence', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.md),
            num(_radius, 'Radius (m)', 'radius_m', helper: '5–2000 m. Start with 20 m.'),
            const SizedBox(height: AppSpacing.md),
            num(_accuracy, 'Required accuracy (m)', 'max_accuracy_m', helper: '1–500 m. Start with 15 m.'),
            const SizedBox(height: AppSpacing.md),
            num(_age, 'Maximum reading age (s)', 'max_sample_age_s', helper: '1–120 s. Start with 10 s.'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _strict,
              title: const Text('Strict mode'),
              subtitle: const Text('Distance plus reported accuracy must fit inside the radius. Enable only after site tests.'),
              onChanged: (v) => setState(() => _strict = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              title: const Text('Active'),
              onChanged: (v) => setState(() => _active = v),
            ),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          color: AppColors.warningSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('On-site calibration', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            const Text('1. Capture the location standing inside the office.\n'
                '2. Ask two or three people to check in from different desks, near windows and deep inside.\n'
                '3. If precise readings fail indoors, raise the accuracy limit slightly — never beyond what you need.\n'
                '4. Mark the office verified once check-ins succeed reliably. GPS can drift; no setting makes it perfect.'),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              icon: const AppIcon(Icons.keyboard_arrow_down_rounded),
              initialValue: _calibration,
              decoration: const InputDecoration(labelText: 'Site test status'),
              items: const [
                DropdownMenuItem(value: 'untested', child: Text('Not tested yet')),
                DropdownMenuItem(value: 'piloting', child: Text('Pilot in progress')),
                DropdownMenuItem(value: 'verified', child: Text('Verified on site')),
              ],
              onChanged: (v) => setState(() => _calibration = v ?? 'untested'),
            ),
            TextField(controller: _notes, maxLength: 1000, minLines: 2, maxLines: 4,
                decoration: const InputDecoration(labelText: 'Test notes')),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(_error!, style: const TextStyle(color: AppColors.error)),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Text('Save office'),
        ),
      ]),
    );
  }
}
