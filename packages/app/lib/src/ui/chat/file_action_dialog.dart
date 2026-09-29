import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../scope.dart';
import '../../state/file_transfer_store.dart';

Future<FileAction?> chooseFileAction(BuildContext context, String path) {
  final AppData data = AppScope.of(context);
  return showDialog<FileAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(path.split(RegExp(r'[/\\]')).last),
      content: SizedBox(
        width: 360,
        child: ListenableBuilder(
          listenable: data.shares,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download'),
                subtitle: Text(
                  kIsWeb
                      ? 'Save using your browser.'
                      : 'Choose where to save this file on your device.',
                ),
                onTap: () => Navigator.pop(context, FileAction.download),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.picture_in_picture_alt_outlined),
                title: const Text('Float'),
                subtitle: Text(
                  data.shares.canFloat
                      ? 'Keep in the top right to attach to another session. Up to 8 MiB.'
                      : 'Attach or dismiss the current shared file first.',
                ),
                enabled: data.shares.canFloat,
                onTap: () => Navigator.pop(context, FileAction.float),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
