import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';

import '../../app/theme.dart';
import '../../core/api/api_exception.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/states.dart';
import 'file_service.dart';

Future<void> openProtectedFile(BuildContext context, String fileVersionId, String title) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => FileViewerScreen(fileVersionId: fileVersionId, title: title),
  ));
}

/// S15-style secure viewer: bytes are fetched through the audited <=60 s
/// link and held in memory only. The viewer closes when the app goes to the
/// background. Saving creates the user's own local copy on request.
class FileViewerScreen extends ConsumerStatefulWidget {
  const FileViewerScreen({super.key, required this.fileVersionId, required this.title});
  final String fileVersionId;
  final String title;

  @override
  ConsumerState<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends ConsumerState<FileViewerScreen> {
  DownloadedFile? _file;
  PdfControllerPinch? _pdf;
  Object? _error;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: () {
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final f = await ref.read(fileServiceProvider).fetch(widget.fileVersionId);
      if (!mounted) return;
      setState(() {
        _file = f;
        if (f.mime == 'application/pdf') {
          _pdf = PdfControllerPinch(document: PdfDocument.openData(f.bytes));
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _pdf?.dispose();
    _file = null;
    super.dispose();
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    try {
      final path = await FilePicker.saveFile(fileName: f.filename, bytes: f.bytes, mimeType: f.mime);
      if (!mounted) return;
      if (path != null) showMessage(context, 'Saved a copy. It is now your own file on this phone.');
    } catch (_) {
      if (mounted) showMessage(context, 'Could not save the file.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (f != null) IconButton(tooltip: 'Save a copy', onPressed: _save, icon: const Icon(Icons.download_rounded)),
      ]),
      body: _error != null
          ? (_error is ApiException && (_error as ApiException).code == 'ARCHIVED'
              ? EmptyState(icon: Icons.inventory_2_outlined, title: 'Archived', message: (_error as ApiException).message)
              : ErrorState(error: _error!, onRetry: _load))
          : f == null
              ? const Center(child: CircularProgressIndicator())
              : _pdf != null
                  ? ColoredBox(
                      color: const Color(0xFFE9ECF1),
                      child: PdfViewPinch(
                        controller: _pdf!,
                        onDocumentError: (_) => setState(() => _error = const ApiException(
                            'RENDER', 'This PDF cannot be displayed here. Use "Save a copy" to open it in another app.')),
                      ),
                    )
                  : InteractiveViewer(
                      child: Center(child: Image.memory(f.bytes, fit: BoxFit.contain, gaplessPlayback: true)),
                    ),
      bottomNavigationBar: f == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text('Shown securely. Nothing is stored on this phone unless you save a copy.',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
    );
  }
}
