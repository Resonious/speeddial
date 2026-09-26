import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../acp/acp_types.dart';

/// Native operations exposed by a session transport. Commands are discovered
/// on the live agent because Ante's skill set can change by project/session.
abstract interface class NativeCommandClient {
  Future<List<NativeCommand>> availableCommands(String sessionId);

  Future<PromptResult> runNativeCommand(
    String sessionId,
    NativeCommand command,
    String arguments,
  );
}
