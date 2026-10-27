import 'package:flutter/material.dart';

import 'toast.dart';

/// A success toast's ember check marks restoration, matching the copy
/// confirmation.
void showSessionRestoredNotice(BuildContext context) {
  showToast(context, 'Session restored', tone: ToastTone.success);
}
