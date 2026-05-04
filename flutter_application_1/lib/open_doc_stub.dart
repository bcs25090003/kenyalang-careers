import 'package:flutter/material.dart';

/// Opens a base64 file as a download (web) or shows a hint on other platforms.
void openDownloadableBase64({required String filename, required String dataBase64, BuildContext? context}) {
  if (context != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("File download is supported in the browser build. ($filename)")),
    );
  }
}
