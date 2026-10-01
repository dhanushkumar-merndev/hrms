import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import '../files/file_service.dart';
import '../files/file_viewer_screen.dart';

/// Server limits for employee documents (mirrored for instant feedback; the
/// server enforces them either way).
const documentLimit = 10;
const documentNameMax = 50;

final myDocumentsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('list_my_documents')).map;
});

/// Name (and optionally date) for a document. Returns null when cancelled.
Future<({String name, DateTime? date})?> askDocumentDetails(
  BuildContext context, {
  required String title,
  required String initialName,
  required int maxLength,
  String confirmLabel = 'Save',
  String? note,
  bool askDate = false,
  DateTime? initialDate,
}) {
  return showDialog<({String name, DateTime? date})>(
    context: context,
    builder: (_) => _DocumentDetailsDialog(
      title: title,
      initialName: initialName.length > maxLength ? initialName.substring(0, maxLength).trim() : initialName,
      maxLength: maxLength,
      confirmLabel: confirmLabel,
      note: note,
      askDate: askDate,
      initialDate: initialDate,
    ),
  );
}

class _DocumentDetailsDialog extends StatefulWidget {
  const _DocumentDetailsDialog({
    required this.title,
    required this.initialName,
    required this.maxLength,
    required this.confirmLabel,
    required this.note,
    required this.askDate,
    required this.initialDate,
  });
  final String title;
  final String initialName;
  final int maxLength;
  final String confirmLabel;
  final String? note;
  final bool askDate;
  final DateTime? initialDate;

  @override
  State<_DocumentDetailsDialog> createState() => _DocumentDetailsDialogState();
}

class _DocumentDetailsDialogState extends State<_DocumentDetailsDialog> {
  late final _controller = TextEditingController(text: widget.initialName);
  late DateTime? _date = widget.initialDate;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the document a name');
      return;
    }
    Navigator.pop(context, (name: name, date: _date));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: widget.maxLength,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(labelText: 'Document name', hintText: 'e.g. Aadhaar card', errorText: _error),
          ),
          if (widget.askDate)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Document date'),
              subtitle: Text(_date == null ? 'None (not part of annual archives)' : OrgTime.date(OrgTime.ymd(_date!))),
              trailing: const Icon(Icons.event_outlined),
              onTap: () async {
                final d = await showDatePicker(
                    context: context, firstDate: DateTime(2000), lastDate: OrgTime.today(), initialDate: _date ?? OrgTime.today());
                if (d != null) setState(() => _date = d);
              },
            ),
          if (widget.note != null) Text(widget.note!, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// Uploads a validated file and publishes it (company policy or employee
/// document). Employee documents are PDF only with a short required name.
/// Returns true when published.
Future<bool> uploadAndPublishDocument(
  BuildContext context,
  WidgetRef ref, {
  required String fileClass,
  String? ownerEmployeeId,
  bool askDate = false,
}) async {
  final employeeDoc = fileClass == 'employee_document';
  final picked = await FilePicker.pickFiles(
      type: FileType.custom, allowedExtensions: employeeDoc ? const ['pdf'] : const ['pdf', 'jpg', 'jpeg', 'png']);
  if (picked.isEmpty || !context.mounted) return false;
  final file = picked.single;
  if (employeeDoc && FileService.mimeFor(file.name) != 'application/pdf') {
    showMessage(context, 'Only PDF files can be added here.', error: true);
    return false;
  }
  final details = await askDocumentDetails(
    context,
    title: 'Name this document',
    initialName: file.name.replaceAll(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '').replaceAll(RegExp(r'[_-]+'), ' ').trim(),
    maxLength: employeeDoc ? documentNameMax : 200,
    confirmLabel: 'Upload',
    note: '${file.name} · ${employeeDoc ? 'PDF' : 'PDF, JPG or PNG'} up to 5 MB',
    askDate: askDate,
    initialDate: askDate ? OrgTime.today() : null,
  );
  if (details == null || !context.mounted) return false;
  // Self-added documents are dated today so they join the annual archive.
  final date = askDate ? details.date : (employeeDoc ? OrgTime.today() : null);

  final progress = _showProgress(context, 'Uploading…');
  try {
    final id = await ref.read(fileServiceProvider).upload(
          fileClass: fileClass,
          bytes: await file.readAsBytes(),
          filename: file.name,
          ownerEmployeeId: ownerEmployeeId,
          title: details.name,
          documentDate: date == null ? null : OrgTime.ymd(date),
        );
    await ref.read(apiProvider).rpc('publish_document', {'p_file_version_id': id});
    progress.close();
    if (context.mounted) showMessage(context, 'Document uploaded.');
    return true;
  } on ApiException catch (e) {
    progress.close();
    if (context.mounted) showMessage(context, e.message, error: true);
    return false;
  } catch (_) {
    progress.close();
    if (context.mounted) showMessage(context, 'Upload failed. Check your connection and try again.', error: true);
    return false;
  }
}

/// Rename an employee document. Returns true when changed.
Future<bool> renameDocument(BuildContext context, WidgetRef ref, Map<String, dynamic> doc) async {
  final details = await askDocumentDetails(
    context,
    title: 'Rename document',
    initialName: doc['title'] as String? ?? '',
    maxLength: documentNameMax,
  );
  if (details == null || details.name == doc['title'] || !context.mounted) return false;
  try {
    await ref.read(apiProvider).rpc('rename_employee_document', {'p_record_id': doc['record_id'], 'p_title': details.name});
    if (context.mounted) showMessage(context, 'Document renamed.');
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, e.message, error: true);
    return false;
  }
}

/// Remove an employee document for good. Returns true when removed.
Future<bool> removeDocument(BuildContext context, WidgetRef ref, Map<String, dynamic> doc) async {
  final ok = await confirm(
    context,
    title: 'Remove document?',
    message: '"${doc['title'] ?? 'Document'}" will be deleted for everyone. This cannot be undone.',
    confirmLabel: 'Remove',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  try {
    await ref.read(apiProvider).rpc('remove_employee_document', {'p_record_id': doc['record_id']});
    if (context.mounted) showMessage(context, 'Document removed.');
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, e.message, error: true);
    return false;
  }
}

({void Function() close}) _showProgress(BuildContext context, String label) {
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.6)),
          const SizedBox(width: AppSpacing.lg),
          Text(label),
        ]),
      ),
    ),
  ).whenComplete(() => open = false);
  return (
    close: () {
      if (open) nav.pop();
      open = false;
    }
  );
}

/// S18 — company policies and the employee's own documents. Files open only
/// through the audited viewer; nothing is cached on the phone.
class DocumentsScreen extends ConsumerWidget {
  const DocumentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myDocumentsProvider);
    final session = ref.watch(sessionContextProvider);
    final canPublishPolicy = session?.canDraftPolicy ?? false;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        actions: [
          if (canPublishPolicy)
            IconButton(
              tooltip: 'Add company policy',
              icon: const Icon(Icons.policy_outlined),
              onPressed: () async {
                if (await uploadAndPublishDocument(context, ref, fileClass: 'company_policy')) {
                  ref.invalidate(myDocumentsProvider);
                }
              },
            ),
        ],
      ),
      body: Column(children: [
        const OfflineBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(myDocumentsProvider.future),
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(myDocumentsProvider),
              builder: (d) {
                final company = ((d['company'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
                final mine = ((d['mine'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
                final count = (d['count'] as num?)?.toInt() ?? mine.length;
                final limit = (d['limit'] as num?)?.toInt() ?? documentLimit;
                final canUpload = d['can_upload'] == true;
                return ListView(padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 96), children: [
                  DocumentQuotaHeader(title: 'My documents', count: count, limit: limit),
                  const SizedBox(height: 2),
                  Text('Private to you and HR. PDF only, up to 5 MB each.', style: t.bodySmall),
                  const SizedBox(height: AppSpacing.md),
                  if (mine.isEmpty)
                    const _EmptyDocs(message: 'Add your ID proof, certificates and other papers here.')
                  else
                    for (final doc in mine)
                      _DocTile(
                        doc: doc,
                        menu: doc['can_edit'] == true
                            ? DocumentMenu(
                                onRename: () async {
                                  if (await renameDocument(context, ref, doc)) ref.invalidate(myDocumentsProvider);
                                },
                                onRemove: () async {
                                  if (await removeDocument(context, ref, doc)) ref.invalidate(myDocumentsProvider);
                                },
                              )
                            : null,
                        note: doc['added_by_me'] == true ? null : 'Added by HR',
                      ),
                  if (canUpload) ...[
                    const SizedBox(height: AppSpacing.sm),
                    AddDocumentButton(
                      count: count,
                      limit: limit,
                      onPressed: () async {
                        if (await uploadAndPublishDocument(context, ref, fileClass: 'employee_document')) {
                          ref.invalidate(myDocumentsProvider);
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  Text('Company policies', style: t.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  if (company.isEmpty)
                    Text('No company policies published yet.', style: t.bodyMedium)
                  else
                    for (final doc in company) _DocTile(doc: doc),
                ]);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// "My documents · 3 of 10" with a thin fill bar.
class DocumentQuotaHeader extends StatelessWidget {
  const DocumentQuotaHeader({super.key, required this.title, required this.count, required this.limit, this.style});
  final String title;
  final int count;
  final int limit;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final full = count >= limit;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(title, style: style ?? Theme.of(context).textTheme.titleMedium)),
        Text('$count of $limit',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: full ? AppColors.error : AppColors.textSecondary,
            )),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: limit == 0 ? 0 : (count / limit).clamp(0, 1).toDouble(),
          minHeight: 5,
          backgroundColor: const Color(0xFFECEEF3),
          color: full ? AppColors.error : AppColors.primary,
        ),
      ),
    ]);
  }
}

class AddDocumentButton extends StatelessWidget {
  const AddDocumentButton({super.key, required this.count, required this.limit, required this.onPressed});
  final int count;
  final int limit;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final full = count >= limit;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        onPressed: full ? null : onPressed,
        icon: const Icon(Icons.upload_file_rounded),
        label: const Text('Add PDF document'),
      ),
      if (full)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('All $limit slots are used. Remove a document to add another.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ),
    ]);
  }
}

class DocumentMenu extends StatelessWidget {
  const DocumentMenu({super.key, required this.onRename, required this.onRemove});
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Document options',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (v) => v == 'rename' ? onRename() : onRemove(),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'), contentPadding: EdgeInsets.zero),
        ),
        PopupMenuItem(
          value: 'remove',
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: AppColors.error),
            title: Text('Remove', style: TextStyle(color: AppColors.error)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

class _EmptyDocs extends StatelessWidget {
  const _EmptyDocs({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xl),
      decoration: BoxDecoration(color: AppColors.documentsCard, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        const Icon(Icons.folder_open_rounded, size: 40, color: AppColors.documentsAction),
        const SizedBox(height: AppSpacing.sm),
        Text('No documents yet', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({required this.doc, this.menu, this.note});
  final Map<String, dynamic> doc;
  final Widget? menu;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final state = doc['state'] as String?;
    final archived = state == 'deleted' || state == 'archived' || state == 'deletion_pending';
    final id = doc['file_version_id'] as String?;
    final isPdf = (doc['mime'] as String?) == 'application/pdf';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: AppSpacing.lg, right: 4),
        leading: CircleAvatar(
          backgroundColor: AppColors.documentsCard,
          child: Icon(isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined, color: AppColors.documentsAction),
        ),
        title: Text(doc['title'] as String? ?? 'Document', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          if (doc['document_date'] != null) OrgTime.date(doc['document_date'] as String?, pattern: 'd MMM yyyy'),
          if ((doc['version_no'] as num? ?? 1) > 1) 'Version ${doc['version_no']}',
          if (doc['size_bytes'] != null) formatBytes(doc['size_bytes'] as num),
          ?note,
          if (archived) 'Archived locally — contact HR',
        ].join(' · ')),
        trailing: menu ?? (archived ? null : const Icon(Icons.chevron_right_rounded)),
        onTap: archived || id == null ? null : () => openProtectedFile(context, id, doc['title'] as String? ?? 'Document'),
      ),
    );
  }
}
