import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../files/file_service.dart';
import '../home/home_providers.dart';
import '../requests/my_requests_screen.dart';

class BankDetailsRequestScreen extends ConsumerStatefulWidget {
  const BankDetailsRequestScreen({super.key, this.editRequestId});
  final String? editRequestId;

  @override
  ConsumerState<BankDetailsRequestScreen> createState() =>
      _BankDetailsRequestScreenState();
}

class _BankDetailsRequestScreenState
    extends ConsumerState<BankDetailsRequestScreen> {
  final _bank = TextEditingController();
  final _holder = TextEditingController();
  final _account = TextEditingController();
  final _ifsc = TextEditingController();
  final _reason = TextEditingController();
  final _operationKey = ApiClient.newOperationKey();
  String? _attachmentId;
  String? _attachmentName;
  int? _expectedVersion;
  bool _loading = false;
  bool _uploading = false;
  bool _saving = false;
  String? _error;
  Map<String, String> _errors = const {};

  @override
  void initState() {
    super.initState();
    if (widget.editRequestId != null) _load();
  }

  @override
  void dispose() {
    for (final controller in [_bank, _holder, _account, _ifsc, _reason]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ref.read(apiProvider).rpc('get_my_request', {
        'p_request_id': widget.editRequestId,
      });
      final revisions = (res.map['revisions'] as List?) ?? const [];
      final payload = revisions.isEmpty
          ? <String, dynamic>{}
          : ((revisions.last as Map)['payload'] as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _bank.text = payload['bank_name'] as String? ?? '';
        _holder.text = payload['account_holder'] as String? ?? '';
        _account.text = payload['account_last4'] as String? ?? '';
        _ifsc.text = payload['ifsc'] as String? ?? '';
        _reason.text = payload['reason'] as String? ?? '';
        _attachmentId = payload['attachment_file_version_id'] as String?;
        _attachmentName = _attachmentId == null
            ? null
            : 'Previously attached proof';
        _expectedVersion = res.version;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _attach() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (picked.isEmpty) return;
    final file = picked.single;
    setState(() => _uploading = true);
    try {
      // Bank proof uses the existing private request-attachment pipeline:
      // immutable bytes, owner/reviewer-only access and audited opens.
      final id = await ref
          .read(fileServiceProvider)
          .upload(
            fileClass: 'correction_attachment',
            bytes: await file.readAsBytes(),
            filename: file.name,
          );
      if (!mounted) return;
      setState(() {
        _attachmentId = id;
        _attachmentName = file.name;
        _errors = {..._errors}..remove('attachment');
      });
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    final ok = await confirm(
      context,
      title: widget.editRequestId == null
          ? 'Submit bank details?'
          : 'Resubmit bank details?',
      message:
          'Your proof and these details are locked into this request. '
          'First-time setup may be approved by HR or Admin; changes to approved details require Admin approval.',
      confirmLabel: 'Submit',
    );
    if (!ok) return;
    setState(() {
      _saving = true;
      _error = null;
      _errors = const {};
    });
    try {
      final res = await ref.read(apiProvider).rpc('save_bank_details_request', {
        'p_request_id': widget.editRequestId,
        'p_bank_name': _bank.text.trim(),
        'p_account_holder': _holder.text.trim(),
        'p_account_number': _account.text.trim(),
        'p_ifsc': _ifsc.text.trim(),
        'p_reason': _reason.text.trim(),
        'p_attachment_file_version_id': _attachmentId,
        'p_expected_version': _expectedVersion,
        'p_operation_key': _operationKey,
      });
      ref.invalidate(myRequestsProvider);
      ref.invalidate(homeSummaryProvider);
      if (!mounted) return;
      showMessage(context, 'Bank details submitted for approval.');
      if (widget.editRequestId != null) {
        context.pop(true);
      } else {
        context.pushReplacement('/requests/${res.map['id']}');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _errors = e.fieldErrors;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String label, String key, {String? helper}) =>
      InputDecoration(
        labelText: label,
        helperText: helper,
        errorText: _errors[key],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.editRequestId == null
              ? 'Add bank details'
              : 'Update bank request',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.page,
                AppSpacing.page,
                AppSpacing.xxl,
              ),
              children: [
                const SectionCard(
                  color: AppColors.attendanceCard,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppIcon(
                        Icons.verified_user_outlined,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          'Your bank proof is private. Approved details are locked; every later change '
                          'creates a new request that only an Admin can approve.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _bank,
                  maxLength: 120,
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec(
                    'Bank name',
                    'bank_name',
                    helper: 'e.g. HDFC Bank',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _holder,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.words,
                  decoration: _dec('Account holder name', 'account_holder'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _account,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 18,
                  decoration: _dec(
                    'Account number',
                    'account_number',
                    helper: 'Only the last 4 digits are kept in the app; the approver verifies your proof.',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _ifsc,
                  maxLength: 11,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  ],
                  decoration: _dec('IFSC', 'ifsc', helper: 'e.g. HDFC0001234'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _reason,
                  maxLength: 500,
                  minLines: 2,
                  maxLines: 3,
                  decoration: _dec(
                    'Reason for change',
                    'reason',
                    helper: 'Required when replacing approved details',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SectionCard(
                  child: Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: AppColors.documentsCard,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const AppIcon(
                          Icons.account_balance_outlined,
                          color: AppColors.documentsAction,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _attachmentName ?? 'Bank proof',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              _errors['attachment'] ?? 'Cancelled cheque, passbook or bank letter · PDF/JPG/PNG · up to 5 MB',
                              style: TextStyle(
                                color: _errors['attachment'] == null
                                    ? null
                                    : AppColors.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _uploading ? null : _attach,
                        child: _uploading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _attachmentId == null ? 'Attach' : 'Replace',
                              ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(_error!, style: const TextStyle(color: AppColors.error)),
                ],
                const SizedBox(height: AppSpacing.xl),
                FilledButton.icon(
                  onPressed: _saving || _uploading ? null : _submit,
                  icon: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const AppIcon(Icons.send_rounded),
                  label: Text(
                    widget.editRequestId == null
                        ? 'Submit for approval'
                        : 'Resubmit for approval',
                  ),
                ),
              ],
            ),
    );
  }
}
