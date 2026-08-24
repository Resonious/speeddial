/// One temporary loopback HTTP listener used for a single OAuth redirect.
abstract interface class LocalhostOAuthCallback {
  /// URI registered with the authorization server for this flow.
  Uri get redirectUri;

  /// Waits for a callback carrying [flowId] as its OAuth state.
  Future<Uri> waitForCallback(String flowId);

  /// Finishes the pending browser request with a success page.
  Future<void> respondSuccess();

  /// Finishes the pending browser request with an error page.
  Future<void> respondError(String message);

  /// Stops listening and releases the ephemeral port.
  Future<void> close();
}
