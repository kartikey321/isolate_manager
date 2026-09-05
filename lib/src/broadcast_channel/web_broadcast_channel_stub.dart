// VM stub — BroadcastChannel is browser-only.

/// VM stub — [WebBroadcastChannel] is web-only.
class WebBroadcastChannel {
  /// Throws [UnsupportedError] on the VM.
  // ignore: avoid_unused_constructor_parameters
  WebBroadcastChannel(String name) {
    throw UnsupportedError('WebBroadcastChannel is only available on web.');
  }

  /// Unreachable on the VM — the constructor above always throws.
  String get name => throw UnsupportedError('web only');

  /// Unreachable on the VM — the constructor above always throws.
  Stream<Object?> get messages => throw UnsupportedError('web only');

  /// Unreachable on the VM — the constructor above always throws.
  void send(Object? data) => throw UnsupportedError('web only');

  /// Unreachable on the VM — the constructor above always throws.
  Future<void> close() async => throw UnsupportedError('web only');
}
