import '../acp/acp_types.dart';

/// Decides how to resolve a provider's permission request.
typedef AgentPermissionHandler = Future<String> Function(
  String providerSessionId,
  String? toolCallId,
  String title,
  List<PermissionOptionData> options,
);

/// Common session transport used by the engine.
///
/// ACP clients implement this directly. Custom transports translate their
/// native messages into the ACP-shaped update vocabulary consumed by the
/// existing engine mapper.
abstract interface class AgentClient {
  Future<InitializeResult> get initialized;

  Stream<String> get stderrLines;

  Future<void> authenticate(String methodId);

  Future<({String sessionId, List<AcpConfigOption> configOptions})> newSession({
    required String cwd,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
    String? model,
    bool yolo = false,
  });

  Future<List<AcpConfigOption>> loadSession({
    required String sessionId,
    required String cwd,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
  });

  Future<List<AcpConfigOption>> setConfigOption(
    String sessionId,
    String configId,
    String value,
  );

  Stream<AcpSessionUpdate> sessionUpdates(String sessionId);

  Future<PromptResult> prompt(
    String sessionId,
    List<Map<String, Object?>> promptBlocks,
  );

  Future<void> cancel(String sessionId);

  Future<void> setMode(String sessionId, String modeId);

  Future<void> dispose();
}
