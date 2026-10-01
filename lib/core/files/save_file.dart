import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Saves bytes through the system "save as" dialog. Returns false when the
/// user cancelled. The saved copy becomes the user's own local file.
Future<bool> saveBytesAs(Uint8List bytes, String filename, String mime) async {
  final uri = await FilePicker.saveFile(fileName: filename, bytes: bytes, mimeType: mime);
  return uri != null;
}

/// Hands a file on disk to the system share sheet (streamed by the OS, so
/// it works for archives too large to hold in memory). The share sheet does
/// not report reliably whether a copy was stored, so callers still ask the
/// user to confirm a saved copy.
Future<void> shareFile(String path, String mime, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(path, mimeType: mime)], subject: subject));
}

/// Largest file offered through the in-memory save dialog.
const maxInMemorySaveBytes = 150 * 1000 * 1000;

Future<bool> canSaveInMemory(String path) async => await File(path).length() <= maxInMemorySaveBytes;
