/// Web/mobile builds never host the embedded daemon or its MCP subprocess.
Future<bool> runMcpIfRequested(List<String> args) async => false;
