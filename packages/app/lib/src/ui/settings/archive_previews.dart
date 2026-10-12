import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'archive_page.dart';

@Preview(
  name: 'Archive storage',
  group: 'Daemon settings',
  size: Size(390, 330),
)
Widget archiveStoragePreview() => const MaterialApp(
  home: Scaffold(
    body: ArchiveUsageCard(
      preview: ArchivePreview(
        sessionIds: <String>['one', 'two', 'three'],
        worktreeCount: 2,
        worktreeBytes: 268435456,
        transcriptBytes: 1048576,
        attachmentBytes: 2097152,
        retainedWorktreeCount: 1,
      ),
    ),
  ),
);
