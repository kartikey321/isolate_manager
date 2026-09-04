// coverage:ignore-file
// Wrapper around the Web Locks API (`navigator.locks`), used for cross-tab
// leader election.
//
// Why this exists: a MessagePort has no "the other side is gone" event, so a
// SharedWorker (or any tab) cannot reliably tell when a peer tab has crashed
// or been killed. A Web Lock solves this for free — the browser releases a
// held lock automatically the instant its holding execution context is
// destroyed, whether that's a clean close, a crash, or an OS-level kill, with
// no JS teardown required on the dying side. Electing a leader by racing for
// a named lock, and treating "the lock became available again" as "the
// previous leader is definitely gone", is the mechanism this wrapper exists
// to expose.
//
// `navigator.locks` is reachable as a bare global in both window and worker
// contexts (workers mix in `WorkerNavigator`), so this file works unchanged
// from a tab, a dedicated worker, or a SharedWorker.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart';

@JS('navigator.locks')
external LockManager? get _navigatorLocks;

/// Whether the Web Locks API is available in the current JS context.
///
/// False on browsers/embedders that don't implement `navigator.locks` (older
/// Safari, some WebViews). Callers should have a non-lock fallback ready.
bool get isWebLockSupported => _navigatorLocks != null;

/// A cooperative cancellation handle for a pending (not-yet-granted)
/// [WebLock.acquire] call.
///
/// Cancelling a request that has already been granted is a no-op — release
/// the returned [WebLockHandle] instead.
class WebLockCancelToken {
  final AbortController _controller = AbortController();

  AbortSignal get _signal => _controller.signal;

  /// Cancels the pending lock request, if it hasn't been granted yet.
  void cancel() => _controller.abort();
}

/// Requests a named exclusive [Lock] via `navigator.locks.request`.
///
/// The Web Locks API only exposes a lock for the lifetime of a callback
/// (which must return a `Promise` — the lock is held until that promise
/// settles). To turn that into an acquire/release pair, the callback we hand
/// the browser returns a `Promise` backed by a [Completer] that we control:
/// it never settles on its own, so the lock stays held until
/// [WebLockHandle.release] completes it.
class WebLock {
  WebLock._();

  /// Whether the Web Locks API is available. Same as [isWebLockSupported].
  static bool get isSupported => isWebLockSupported;

  /// Attempts to acquire [name] immediately, without waiting.
  ///
  /// Returns `null` right away if the lock is currently held by someone else,
  /// if the Web Locks API is unavailable, or if the request fails for any
  /// other reason. Never blocks.
  static Future<WebLockHandle?> tryAcquire(String name) =>
      _request(name, ifAvailable: true);

  /// Queues for [name] and completes once granted.
  ///
  /// Waits indefinitely (until granted or [cancelToken] is cancelled) if the
  /// lock is currently held elsewhere. Pass [steal] to forcibly break an
  /// existing hold (matches `LockOptions.steal` — use only for a lock this
  /// process is meant to own exclusively across its own reloads, such as a
  /// self-held termination marker).
  ///
  /// Returns `null` if [cancelToken] is cancelled before the lock is granted,
  /// or if the Web Locks API is unavailable.
  static Future<WebLockHandle?> acquire(
    String name, {
    bool steal = false,
    WebLockCancelToken? cancelToken,
  }) => _request(name, ifAvailable: false, steal: steal, cancelToken: cancelToken);

  static Future<WebLockHandle?> _request(
    String name, {
    required bool ifAvailable,
    bool steal = false,
    WebLockCancelToken? cancelToken,
  }) {
    final locks = _navigatorLocks;
    if (locks == null) return Future.value();

    final grantedCompleter = Completer<bool>();
    final releaseCompleter = Completer<JSAny?>();

    final callback =
        ((JSAny? lock) {
          if (lock == null) {
            if (!grantedCompleter.isCompleted) grantedCompleter.complete(false);
            return Future<JSAny?>.value().toJS;
          }
          if (!grantedCompleter.isCompleted) grantedCompleter.complete(true);
          return releaseCompleter.future.toJS;
        }).toJS;

    final options = LockOptions(ifAvailable: ifAvailable, steal: steal);
    if (cancelToken != null) options.signal = cancelToken._signal;

    final requestPromise = locks.request(name, options, callback);
    // A rejected request (e.g. the AbortSignal fired while still queued)
    // means the callback above is never invoked — without this, cancelling a
    // still-pending acquire() would hang grantedCompleter forever.
    unawaited(
      requestPromise.toDart.then(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (!grantedCompleter.isCompleted) grantedCompleter.complete(false);
        },
      ),
    );

    return grantedCompleter.future.then((granted) {
      if (!granted) return null;
      return WebLockHandle._(releaseCompleter);
    });
  }
}

/// A held [Lock]. Call [release] to give it up; until then it stays held,
/// even across `await` points, even if this object is dropped (the JS lock
/// only releases when [release] runs or this JS context dies).
class WebLockHandle {
  WebLockHandle._(this._releaseCompleter);

  final Completer<JSAny?> _releaseCompleter;
  bool _released = false;

  /// Whether [release] has already been called on this handle.
  bool get isReleased => _released;

  /// Releases the lock, letting the next queued [WebLock.acquire] proceed.
  ///
  /// Idempotent — calling this more than once is a no-op after the first
  /// call.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    if (!_releaseCompleter.isCompleted) _releaseCompleter.complete(null);
  }
}
