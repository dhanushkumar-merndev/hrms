import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/pickers.dart';
import '../../core/widgets/states.dart';
import '../files/file_service.dart';
import '../home/home_providers.dart';

final myProfileProvider = FutureProvider.autoDispose<ApiResult>((ref) async {
  return ref.read(apiProvider).rpc('get_my_profile');
});

/// Avatar bytes, kept in memory for the session (dropped on sign-out), so
/// Home, Profile and lists don't re-download the same photo.
final avatarBytesProvider = FutureProvider.autoDispose
    .family<DownloadedFile, String>((ref, id) async {
      cacheFor(ref, const Duration(minutes: 30));
      return ref.read(fileServiceProvider).fetch(id);
    });

/// Loads a published avatar through the audited file flow (memory only).
class AvatarImage extends ConsumerStatefulWidget {
  const AvatarImage({
    super.key,
    required this.fileVersionId,
    required this.name,
    this.radius = 36,
  });
  final String? fileVersionId;
  final String name;
  final double radius;

  @override
  ConsumerState<AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends ConsumerState<AvatarImage> {
  @override
  Widget build(BuildContext context) {
    final id = widget.fileVersionId;
    // A photo is optional: initials show while loading or if it fails.
    final f = id == null ? null : ref.watch(avatarBytesProvider(id)).value;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: AppColors.peopleCard,
      foregroundImage: f == null ? null : MemoryImage(f.bytes),
      child: Text(
        initialsOf(widget.name),
        style: TextStyle(
          color: AppColors.peopleAction,
          fontWeight: FontWeight.w700,
          fontSize: widget.radius * 0.6,
        ),
      ),
    );
  }
}

/// S16 — own profile. Work details are read-only (changed by HR); personal
/// details are editable here. Every change is audited server-side.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, this.editRequestId});

  final String? editRequestId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _uploading = false;
  bool _openedEditRequest = false;

  Future<void> _changePhoto() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    );
    if (picked.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final f = picked.single;
      final id = await ref
          .read(fileServiceProvider)
          .upload(
            fileClass: 'avatar',
            bytes: await f.readAsBytes(),
            filename: f.name,
          );
      await ref.read(apiProvider).rpc('publish_document', {
        'p_file_version_id': id,
      });
      ref.invalidate(myProfileProvider);
      ref.invalidate(homeSummaryProvider);
      if (mounted) showMessage(context, 'Photo updated.');
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(myProfileProvider);
    final me = ref.watch(sessionContextProvider);
    final canEditWork = me?.canMasterData ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My profile'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/settings'),
            icon: const AppIcon(Icons.settings_outlined, size: 20),
            label: const Text('Settings'),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(myProfileProvider),
        loading: const ProfileSkeleton(),
        builder: (res) {
          final p = res.map;
          final roles = ((p['roles'] as List?) ?? const []).cast<String>();
          final private = ((p['private'] as Map?) ?? const {})
              .cast<String, dynamic>();
          final profileRequest = (p['profile_request'] as Map?)
              ?.cast<String, dynamic>();
          final shift = (p['shift'] as Map?)?.cast<String, dynamic>();
          String? nameOf(Object? m) => (m as Map?)?['name'] as String?;
          final hasPrivateDetails = [
            'personal_email',
            'personal_phone',
            'address',
            'emergency_contact_name',
            'emergency_contact_phone',
            'date_of_birth',
          ].any((key) => (private[key] as String?)?.trim().isNotEmpty == true);

          Future<void> editPrivateDetails({String? requestId}) async {
            final saved = await showPrivateDetailsEditor(
              context,
              ref,
              private: private,
              own: true,
              requestId: requestId,
            );
            if (saved) {
              ref.invalidate(myProfileProvider);
              if (widget.editRequestId != null && context.mounted) {
                context.pop(true);
              }
            }
          }

          if (widget.editRequestId != null && !_openedEditRequest) {
            _openedEditRequest = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                editPrivateDetails(requestId: widget.editRequestId);
              }
            });
          }

          return RefreshIndicator(
            onRefresh: () => ref.refresh(myProfileProvider.future),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.page),
              children: [
                SectionCard(
                  child: Row(
                    children: [
                      AvatarImage(
                        fileVersionId: p['avatar_file_version_id'] as String?,
                        name: p['name'] as String? ?? '',
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p['name'] as String? ?? '',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              '${p['code']}${p['designation'] != null ? ' · ${p['designation']}' : ''}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final r in roles)
                                  StatusChip(roleLabel(r), tone: ChipTone.info),
                                if (roles.isEmpty)
                                  const StatusChip(
                                    'Member',
                                    tone: ChipTone.neutral,
                                  ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            TextButton.icon(
                              onPressed: _uploading ? null : _changePhoto,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: _uploading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const AppIcon(
                                      Icons.photo_camera_outlined,
                                      size: 19,
                                    ),
                              label: const Text('Change photo'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Work',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          // Admin / HR edit their own work details directly.
                          if (canEditWork && me != null)
                            TextButton.icon(
                              onPressed: () async {
                                await context.push(
                                  '/employees/${me.employeeId}',
                                );
                                ref.invalidate(myProfileProvider);
                              },
                              icon: const AppIcon(Icons.edit_outlined),
                              label: const Text('Edit'),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (nameOf(p['department']) != null)
                        KeyValueRow('Department', nameOf(p['department'])!),
                      if (nameOf(p['team']) != null)
                        KeyValueRow('Team', nameOf(p['team'])!),
                      if (nameOf(p['manager']) != null)
                        KeyValueRow('Reports to', nameOf(p['manager'])!),
                      KeyValueRow(
                        'Office',
                        nameOf(p['office']) ?? 'Not assigned',
                      ),
                      KeyValueRow(
                        'Shift',
                        shift == null
                            ? 'Not assigned'
                            : '${shift['name']}: ${clockLabel(shift['start_local'])}–${clockLabel(shift['end_local'])}, '
                                  '${weekdaysLabel((shift['weekly_mask'] as num?)?.toInt() ?? 31)}'
                                  '${shift['lunch_paid'] == true ? ' · lunch included' : ''}',
                      ),
                      KeyValueRow(
                        'Joined',
                        OrgTime.date(p['join_date'] as String?),
                      ),
                      if (p['business_email'] != null)
                        KeyValueRow(
                          'Work email',
                          p['business_email'] as String,
                        ),
                      if (p['business_phone'] != null)
                        KeyValueRow(
                          'Work phone',
                          p['business_phone'] as String,
                        ),
                      if (!canEditWork) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Ask HR or Admin to change your work details.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Personal details',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          if (profileRequest == null)
                            TextButton.icon(
                              onPressed: editPrivateDetails,
                              icon: const AppIcon(Icons.edit_outlined),
                              label: Text(hasPrivateDetails ? 'Edit' : 'Add'),
                            )
                          else
                            TextButton.icon(
                              onPressed: () => context.push(
                                '/requests/${profileRequest['id']}',
                              ),
                              icon: const AppIcon(Icons.receipt_long_outlined),
                              label: const Text('View request'),
                            ),
                        ],
                      ),
                      Text(
                        'Visible only to you, HR and Admin.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (profileRequest != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: AppColors.warningSoft,
                            borderRadius: BorderRadius.circular(
                              AppSpacing.rowRadius,
                            ),
                          ),
                          child: Text(
                            profileRequest['state'] == 'returned'
                                ? 'Changes were returned. Open the request to fix and resubmit them.'
                                : 'Your proposed changes are awaiting verification. The approved details below stay active until approval.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      if (hasPrivateDetails)
                        PrivateDetailsView(private: private)
                      else
                        InkWell(
                          onTap: () => editPrivateDetails(),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.rowRadius,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: AppSpacing.lg,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(
                                AppSpacing.rowRadius,
                              ),
                            ),
                            child: const Row(
                              children: [
                                AppIcon(
                                  Icons.person_add_alt_1_outlined,
                                  color: AppColors.primary,
                                ),
                                SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: Text(
                                    'Add your phone, email and emergency contact',
                                  ),
                                ),
                                AppIcon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PrivateDetailsView extends StatelessWidget {
  const PrivateDetailsView({super.key, required this.private});
  final Map<String, dynamic> private;

  @override
  Widget build(BuildContext context) {
    String? v(String k) {
      final value = (private[k] as String?)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final emergencyName = v('emergency_contact_name');
    final emergencyPhone = v('emergency_contact_phone');
    final dob = v('date_of_birth');
    return Column(
      children: [
        if (v('personal_email') case final value?)
          KeyValueRow('Personal email', value),
        if (v('personal_phone') case final value?)
          KeyValueRow('Personal phone', value),
        if (v('address') case final value?) KeyValueRow('Address', value),
        if (emergencyName != null || emergencyPhone != null)
          KeyValueRow(
            'Emergency contact',
            [emergencyName, emergencyPhone].whereType<String>().join(' · '),
          ),
        if (dob != null)
          KeyValueRow(
            'Date of birth',
            OrgTime.date(dob, pattern: 'd MMM yyyy'),
          ),
      ],
    );
  }
}

/// Personal-details form shared by the own profile request flow and
/// HR's employee detail (update_private_details). Returns true when saved.
Future<bool> showPrivateDetailsEditor(
  BuildContext context,
  WidgetRef ref, {
  required Map<String, dynamic> private,
  required bool own,
  String? employeeId,
  String? requestId,
}) async {
  var initial = private;
  int? expectedRequestVersion;
  if (own && requestId != null) {
    try {
      final request = await ref.read(apiProvider).rpc('get_my_request', {
        'p_request_id': requestId,
      });
      final revisions = (request.map['revisions'] as List?) ?? const [];
      final payload = revisions.isEmpty
          ? const <String, dynamic>{}
          : ((revisions.last as Map)['payload'] as Map).cast<String, dynamic>();
      final proposed = (payload['patch'] as Map?)?.cast<String, dynamic>();
      if (proposed != null) initial = {...private, ...proposed};
      expectedRequestVersion = request.version;
    } on ApiException catch (e) {
      if (context.mounted) showMessage(context, e.message, error: true);
      return false;
    }
  }
  if (!context.mounted) return false;
  final fields = {
    'personal_email': TextEditingController(
      text: initial['personal_email'] as String?,
    ),
    'personal_phone': TextEditingController(
      text: initial['personal_phone'] as String?,
    ),
    'address': TextEditingController(text: initial['address'] as String?),
    'emergency_contact_name': TextEditingController(
      text: initial['emergency_contact_name'] as String?,
    ),
    'emergency_contact_phone': TextEditingController(
      text: initial['emergency_contact_phone'] as String?,
    ),
  };
  DateTime? dob = DateTime.tryParse(initial['date_of_birth'] as String? ?? '');
  final isAdmin = ref.read(sessionContextProvider)?.isAdmin ?? false;
  final operationKey = ApiClient.newOperationKey();
  var busy = false;
  String? error;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> save() async {
          setState(() {
            busy = true;
            error = null;
          });
          final patch = {
            for (final e in fields.entries)
              e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
            'date_of_birth': dob == null ? null : OrgTime.ymd(dob!),
          };
          try {
            final api = ref.read(apiProvider);
            final version = (private['version'] as num?)?.toInt() ?? 1;
            if (own) {
              await api.rpc('save_profile_details_request', {
                'p_request_id': requestId,
                'p_patch': patch,
                'p_expected_private_version': version,
                'p_expected_request_version': expectedRequestVersion,
                'p_operation_key': operationKey,
              });
              ref.invalidate(homeSummaryProvider);
            } else {
              await api.rpc('update_private_details', {
                'p_employee_id': employeeId,
                'p_patch': patch,
                'p_expected_version': version,
              });
            }
            if (ctx.mounted) Navigator.pop(ctx, true);
          } on ApiException catch (e) {
            setState(() {
              busy = false;
              error = e.message;
            });
          }
        }

        InputDecoration dec(String label) => InputDecoration(labelText: label);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppSpacing.page),
            children: [
              Text(
                requestId == null ? 'Personal details' : 'Fix personal details',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              if (own) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  isAdmin
                      ? 'As an Admin, your validated changes apply immediately and are audited.'
                      : 'Your current approved details remain active until HR or Admin verifies this request.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: fields['personal_email'],
                keyboardType: TextInputType.emailAddress,
                maxLength: 200,
                decoration: dec('Personal email'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: fields['personal_phone'],
                keyboardType: TextInputType.phone,
                maxLength: 40,
                decoration: dec('Personal phone'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: fields['address'],
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                decoration: dec('Address'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: fields['emergency_contact_name'],
                maxLength: 120,
                decoration: dec('Emergency contact name'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: fields['emergency_contact_phone'],
                keyboardType: TextInputType.phone,
                maxLength: 40,
                decoration: dec('Emergency contact phone'),
              ),
              const SizedBox(height: AppSpacing.md),
              DateField(
                label: 'Date of birth',
                date: dob,
                first: DateTime(1920),
                last: OrgTime.today(),
                onChanged: (d) => setState(() => dob = d),
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(error!, style: const TextStyle(color: AppColors.error)),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: busy ? null : save,
                child: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Text(
                        own
                            ? isAdmin
                                  ? 'Save now'
                                  : requestId == null
                                  ? 'Submit for verification'
                                  : 'Resubmit for verification'
                            : 'Save',
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
  // The modal future completes when pop starts; keep its controllers alive
  // until the exit animation has removed every TextField from the tree.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final c in fields.values) {
    c.dispose();
  }
  return saved ?? false;
}
