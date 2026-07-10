/// Normalizes a host that will be dialed as a remote endpoint.
///
/// Wildcard addresses are valid for server binds, but can never identify a
/// remote peer. Returning an empty string lets callers fall back to discovery.
String normalizeRemoteHost(String value) {
  final host = value.trim();
  if (host == '0.0.0.0' || host == '::' || host == '[::]') return '';
  return host;
}