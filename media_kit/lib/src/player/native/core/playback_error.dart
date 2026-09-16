/// Returns whether a network source reached EOF substantially before its
/// advertised duration. libmpv may report an interrupted remote file as EOF
/// instead of MPV_END_FILE_REASON_ERROR.
bool isPrematureNetworkEof({
  required String uri,
  required Duration position,
  required Duration duration,
  Duration? requestedEnd,
  Duration tolerance = const Duration(seconds: 2),
}) {
  if (requestedEnd != null || duration <= Duration.zero) {
    return false;
  }

  final scheme = Uri.tryParse(uri)?.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return false;
  }

  return duration - position > tolerance;
}
