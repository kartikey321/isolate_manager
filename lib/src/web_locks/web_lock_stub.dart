// VM stub — the Web Locks API is browser-only.

/// Always `false` on the VM.
bool get isWebLockSupported => false;

/// VM stub — [WebLock] is web-only. [WebLock.isSupported] is always `false`
/// here, and every acquire method resolves to `null` without touching any
/// platform API.
class WebLock {
  WebLock._();

  /// Always `false` on the VM.
  static bool get isSupported => false;

  /// Always resolves to `null` on the VM.
  static Future<WebLockHandle?> tryAcquire(String name) async => null;

  /// Always resolves to `null` on the VM.
  static Future<WebLockHandle?> acquire(
    String name, {
    bool steal = false,
    WebLockCancelToken? cancelToken,
  }) async => null;
}

/// VM stub — cancellation has nothing to cancel.
class WebLockCancelToken {
  /// No-op on the VM.
  void cancel() {}
}

/// VM stub — never constructed since [WebLock] never grants on the VM.
class WebLockHandle {
  /// No-op on the VM.
  Future<void> release() async {}

  /// Always `false` on the VM.
  bool get isReleased => false;
}
