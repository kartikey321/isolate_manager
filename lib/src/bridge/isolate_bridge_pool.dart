// Doc comments reference constructor parameters and nearby public names that
// are not resolvable as dartdoc links in their local scope.
// ignore_for_file: comment_references

import 'dart:async';

import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/bridge/isolate_bridge.dart';
import 'package:isolate_manager/src/utils/normalize_path.dart';

// ---------------------------------------------------------------------------
// Public support types
// ---------------------------------------------------------------------------

/// Read-only snapshot of a pool slot passed to a custom [IsolateBridgePool.router].
class BridgeSlotView {
  /// Creates a slot view.
  const BridgeSlotView({
    required this.index,
    required this.inFlight,
    required this.healthy,
  });

  /// Zero-based position in the pool.
  final int index;

  /// Number of [IsolateBridgePool.submit] requests currently outstanding on
  /// this slot.
  final int inFlight;

  /// Whether this slot's worker is alive and accepting messages.
  final bool healthy;
}

/// Built-in routing strategy for [IsolateBridgePool].
enum BridgePoolRoutingStrategy {
  /// Distribute [submit] / [IsolateBridgePool.send] calls round-robin across
  /// healthy slots.
  roundRobin,

  /// Route each message to the healthy slot with the fewest in-flight
  /// [IsolateBridgePool.submit] requests.
  leastInFlight,

  /// Route repeated values of [IsolateBridgePool.send]'s / [IsolateBridgePool.submit]'s
  /// `stickyKey` to the same slot.
  ///
  /// Falls back to [leastInFlight] for new keys or when the sticky slot is
  /// at capacity.
  stickyKey,
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

class _PoolSlot<R, P> {
  _PoolSlot({required this.index, required this.bridge});

  final int index;
  IsolateBridge<R, P> bridge;
  int inFlight = 0;
  bool healthy = true;
}

class _InFlightRequest<R> {
  _InFlightRequest({required this.slotIndex, required this.completer, this.onEvent});

  final int slotIndex;
  final Completer<R> completer;
  final void Function(R)? onEvent;
  Timer? timeoutTimer;
}

class _PendingRequest<R, P> {
  _PendingRequest({
    required this.message,
    required this.requestId,
    required this.completer,
    this.stickyKey,
    this.transferables,
    this.onEvent,
    this.timeout,
    this.forcedSlotIndex,
  });

  final P message;
  final Object requestId;
  final Completer<R> completer;
  final Object? stickyKey;
  final List<Object>? transferables;
  final void Function(R)? onEvent;
  final Duration? timeout;
  /// Non-null when the custom [router] pinned this request to a specific slot.
  final int? forcedSlotIndex;
}

// ---------------------------------------------------------------------------
// IsolateBridgePool
// ---------------------------------------------------------------------------

/// A pool of [concurrent] persistent bridge workers.
///
/// Messages are distributed across workers using a [BridgePoolRoutingStrategy]
/// or a custom [router]. All worker output is merged onto the single [stream].
///
/// Use [submit] to send a message and await its terminal response, [send] for
/// fire-and-forget delivery, and [broadcast] to fan out to all healthy workers.
///
/// ### Request tracking
///
/// [submit] tracks in-flight requests in one of two modes:
///
/// - **Correlation mode** (preferred): supply [outputRequestId] and
///   [isTerminalEvent] at construction. Each event is inspected for a
///   correlation ID; non-terminal events call the per-request `onEvent`
///   callback and the terminal event completes the [submit] future.
/// - **Slot-FIFO mode** (default when [outputRequestId] is omitted): requests
///   are completed in arrival order per slot. Safe when [maxInFlightPerWorker]
///   is 1 and the worker responds to each message exactly once.
///
/// ### Backpressure
///
/// When every slot is at [maxInFlightPerWorker] capacity, [submit] calls are
/// queued. The queue is drained whenever a slot finishes a request or a new
/// slot becomes available after [autoRespawn].
class IsolateBridgePool<R, P> {
  IsolateBridgePool._({
    required List<_PoolSlot<R, P>> slots,
    required BridgePoolRoutingStrategy routing,
    required int maxInFlightPerWorker,
    required Object? Function(R)? outputRequestId,
    required bool Function(R)? isTerminalEvent,
    required int? Function(P, List<BridgeSlotView>)? router,
    required bool autoRespawn,
    required IsolateBridgeFunction function,
    required String workerName,
    required Object? initialParams,
    required IsolateConverter<R>? converter,
    required IsolateConverter<R>? workerConverter,
    required bool enableWasmConverter,
    required bool enableWasmTransferables,
    required bool isDebug,
  }) : _slots = slots,
       _routing = routing,
       _maxInFlightPerWorker = maxInFlightPerWorker,
       _outputRequestId = outputRequestId,
       _isTerminalEvent = isTerminalEvent,
       _router = router,
       _autoRespawn = autoRespawn,
       _function = function,
       _workerName = workerName,
       _initialParams = initialParams,
       _converter = converter,
       _workerConverter = workerConverter,
       _enableWasmConverter = enableWasmConverter,
       _enableWasmTransferables = enableWasmTransferables,
       _isDebug = isDebug,
       _slotQueues = List<List<_InFlightRequest<R>>>.generate(
         slots.length,
         (_) => <_InFlightRequest<R>>[],
       );

  final List<_PoolSlot<R, P>> _slots;
  final BridgePoolRoutingStrategy _routing;
  final int _maxInFlightPerWorker;
  final Object? Function(R)? _outputRequestId;
  final bool Function(R)? _isTerminalEvent;
  final int? Function(P, List<BridgeSlotView>)? _router;
  final bool _autoRespawn;

  // Spawn args kept for auto-respawn.
  final IsolateBridgeFunction _function;
  final String _workerName;
  final Object? _initialParams;
  final IsolateConverter<R>? _converter;
  final IsolateConverter<R>? _workerConverter;
  final bool _enableWasmConverter;
  final bool _enableWasmTransferables;
  final bool _isDebug;

  final StreamController<R> _streamController = StreamController<R>.broadcast();
  /// Correlation-mode tracking: requestId → in-flight request.
  final Map<Object, _InFlightRequest<R>> _inFlightRequests = {};
  /// Slot-FIFO tracking: one ordered list per slot.
  final List<List<_InFlightRequest<R>>> _slotQueues;
  /// Pending requests waiting for a slot to become eligible.
  final List<_PendingRequest<R, P>> _pendingQueue = [];
  final Map<Object, int> _stickyMap = {};
  int _roundRobinIndex = 0;
  bool _closed = false;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Merged stream of events emitted by all worker slots.
  Stream<R> get stream => _streamController.stream;

  /// Spawns [concurrent] bridge workers and returns the pool.
  ///
  /// Workers are spawned sequentially; if one fails the already-spawned
  /// workers are closed before the error propagates.
  ///
  /// `workerConverter` is only applied on web when a real JS Worker is used.
  /// `transferables` passed to [send] / [submit] are likewise only honoured in
  /// Worker mode; in the same-thread web fallback they are silently ignored.
  static Future<IsolateBridgePool<R, P>> spawn<R, P>(
    IsolateBridgeFunction function, {
    int concurrent = 1,
    String? workerName,
    Object? initialParams,
    BridgePoolRoutingStrategy routing = BridgePoolRoutingStrategy.roundRobin,
    int maxInFlightPerWorker = 1,
    Object? Function(R event)? outputRequestId,
    bool Function(R event)? isTerminalEvent,
    int? Function(P message, List<BridgeSlotView> slots)? router,
    IsolateConverter<R>? converter,
    IsolateConverter<R>? workerConverter,
    bool enableWasmConverter = true,
    bool enableWasmTransferables = false,
    bool isDebug = false,
    bool autoRespawn = false,
  }) async {
    assert(concurrent >= 1, 'concurrent must be at least 1');

    final bridges = <IsolateBridge<R, P>>[];
    try {
      for (var i = 0; i < concurrent; i++) {
        bridges.add(
          await IsolateBridge.spawn<R, P>(
            function,
            workerName: workerName,
            initialParams: initialParams,
            debugName: 'bridge-pool-$i',
            converter: converter,
            workerConverter: workerConverter,
            enableWasmConverter: enableWasmConverter,
            enableWasmTransferables: enableWasmTransferables,
            isDebug: isDebug,
          ),
        );
      }
    } catch (_) {
      await Future.wait(bridges.map((b) => b.close()));
      rethrow;
    }

    final slots = <_PoolSlot<R, P>>[
      for (var i = 0; i < concurrent; i++) _PoolSlot<R, P>(index: i, bridge: bridges[i]),
    ];

    final pool = IsolateBridgePool<R, P>._(
      slots: slots,
      routing: routing,
      maxInFlightPerWorker: maxInFlightPerWorker,
      outputRequestId: outputRequestId,
      isTerminalEvent: isTerminalEvent,
      router: router,
      autoRespawn: autoRespawn,
      function: function,
      workerName: normalizePath(workerName) ?? '',
      initialParams: initialParams,
      converter: converter,
      workerConverter: workerConverter,
      enableWasmConverter: enableWasmConverter,
      enableWasmTransferables: enableWasmTransferables,
      isDebug: isDebug,
    );

    slots.forEach(pool._setupSlotListener);

    return pool;
  }

  /// Routes [message] to a slot and returns a [Future] that completes with the
  /// terminal response event.
  ///
  /// [requestId] must uniquely identify this request within the pool's lifetime
  /// when [outputRequestId] is configured; it is used as the correlation key.
  ///
  /// If all eligible slots are at [maxInFlightPerWorker] capacity, the request
  /// is queued and dispatched as soon as a slot becomes available.
  ///
  /// If [timeout] elapses before a terminal event arrives, the future completes
  /// with a [TimeoutException].
  Future<R> submit(
    P message, {
    required Object requestId,
    Object? stickyKey,
    List<Object>? transferables,
    void Function(R event)? onEvent,
    Duration? timeout,
  }) {
    if (_closed) {
      return Future.error(const IsolateException('IsolateBridgePool is closed.'));
    }

    final completer = Completer<R>();
    final forcedSlotIndex = _computeForcedIndex(message);
    final req = _PendingRequest<R, P>(
      message: message,
      requestId: requestId,
      completer: completer,
      stickyKey: stickyKey,
      transferables: transferables,
      onEvent: onEvent,
      timeout: timeout,
      forcedSlotIndex: forcedSlotIndex,
    );

    final slotIndex = _findEligibleSlot(stickyKey, forcedSlotIndex);
    if (slotIndex != null) {
      _sendToSlot(slotIndex, req);
    } else {
      _pendingQueue.add(req);
    }

    return completer.future;
  }

  /// Sends [message] to a healthy slot without tracking a response.
  ///
  /// Bypasses the [maxInFlightPerWorker] limit; never queues. Throws an
  /// [IsolateException] if no healthy slot is available.
  void send(P message, {Object? stickyKey, List<Object>? transferables}) {
    if (_closed) throw const IsolateException('IsolateBridgePool is closed.');

    final forcedIndex = _computeForcedIndex(message);
    final slot = _findHealthySlot(stickyKey, forcedIndex);
    if (slot == null) {
      throw const IsolateException('No healthy slot available in IsolateBridgePool.');
    }

    if (stickyKey != null && _routing == BridgePoolRoutingStrategy.stickyKey) {
      _stickyMap[stickyKey] = slot.index;
    }
    slot.bridge.send(message, transferables: transferables);
  }

  /// Sends [message] to every currently healthy slot.
  void broadcast(P message, {List<Object>? transferables}) {
    if (_closed) throw const IsolateException('IsolateBridgePool is closed.');

    for (final slot in _slots) {
      if (slot.healthy) slot.bridge.send(message, transferables: transferables);
    }
  }

  /// Closes all bridge workers and releases resources.
  ///
  /// All pending and in-flight [submit] futures complete with an
  /// [IsolateException].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    const closed = IsolateException('IsolateBridgePool is closed.');

    for (final req in _pendingQueue) {
      if (!req.completer.isCompleted) req.completer.completeError(closed);
    }
    _pendingQueue.clear();

    for (final req in _inFlightRequests.values) {
      req.timeoutTimer?.cancel();
      if (!req.completer.isCompleted) req.completer.completeError(closed);
    }
    _inFlightRequests.clear();

    for (final queue in _slotQueues) {
      for (final req in queue) {
        req.timeoutTimer?.cancel();
        if (!req.completer.isCompleted) req.completer.completeError(closed);
      }
      queue.clear();
    }

    await Future.wait(_slots.map((s) => s.bridge.close()));
    if (!_streamController.isClosed) await _streamController.close();
  }

  // -------------------------------------------------------------------------
  // Internal — lifecycle
  // -------------------------------------------------------------------------

  void _setupSlotListener(_PoolSlot<R, P> slot) {
    slot.bridge.stream.listen(
      (event) => _handleEvent(slot.index, event),
      onError: (Object e, StackTrace st) => _handleSlotError(slot.index, e, st),
      onDone: () => _handleSlotDone(slot.index),
    );
  }

  void _handleEvent(int slotIndex, R event) {
    if (!_streamController.isClosed) _streamController.add(event);

    if (_outputRequestId != null) {
      // Correlation mode: match events by their extracted request ID.
      final requestId = _outputRequestId(event);
      if (requestId != null) {
        final req = _inFlightRequests[requestId];
        if (req != null) {
          req.onEvent?.call(event);
          if (_isTerminalEvent?.call(event) ?? true) {
            req.timeoutTimer?.cancel();
            _inFlightRequests.remove(requestId);
            _slots[slotIndex].inFlight--;
            if (!req.completer.isCompleted) req.completer.complete(event);
            _drain();
          }
        }
      }
    } else {
      // Slot-FIFO mode: deliver to the oldest in-flight request on this slot.
      final queue = _slotQueues[slotIndex];
      if (queue.isNotEmpty) {
        final req = queue.first;
        req.onEvent?.call(event);
        if (_isTerminalEvent?.call(event) ?? true) {
          queue.removeAt(0);
          req.timeoutTimer?.cancel();
          _slots[slotIndex].inFlight--;
          if (!req.completer.isCompleted) req.completer.complete(event);
          _drain();
        }
      }
    }
  }

  void _handleSlotError(int slotIndex, Object error, StackTrace stackTrace) {
    if (_closed) return;
    if (!_streamController.isClosed) _streamController.addError(error, stackTrace);
    _markSlotUnhealthy(slotIndex, error, stackTrace);
    if (_autoRespawn) unawaited(_respawnSlot(slotIndex));
  }

  void _handleSlotDone(int slotIndex) {
    if (_closed) return;
    const e = IsolateException('Bridge worker exited unexpectedly.');
    _markSlotUnhealthy(slotIndex, e, StackTrace.empty);
    if (_autoRespawn) unawaited(_respawnSlot(slotIndex));
  }

  void _markSlotUnhealthy(int slotIndex, Object error, StackTrace stackTrace) {
    final slot = _slots[slotIndex];
    if (!slot.healthy) return;
    slot.healthy = false;

    // Fail correlation-mode requests assigned to this slot.
    _inFlightRequests.removeWhere((_, req) {
      if (req.slotIndex != slotIndex) return false;
      req.timeoutTimer?.cancel();
      if (!req.completer.isCompleted) req.completer.completeError(error, stackTrace);
      return true;
    });

    // Fail slot-queue requests.
    for (final req in _slotQueues[slotIndex]) {
      req.timeoutTimer?.cancel();
      if (!req.completer.isCompleted) req.completer.completeError(error, stackTrace);
    }
    _slotQueues[slotIndex].clear();
    slot.inFlight = 0;

    // If not auto-respawning, immediately fail pending requests that are
    // pinned to the dead slot; they have no other path forward.
    if (!_autoRespawn) {
      _pendingQueue.removeWhere((req) {
        if (req.forcedSlotIndex != slotIndex) return false;
        if (!req.completer.isCompleted) req.completer.completeError(error, stackTrace);
        return true;
      });
    }

    _drain();
  }

  Future<void> _respawnSlot(int slotIndex) async {
    if (_closed) return;
    try {
      final bridge = await IsolateBridge.spawn<R, P>(
        _function,
        workerName: _workerName.isEmpty ? null : _workerName,
        initialParams: _initialParams,
        debugName: 'bridge-pool-$slotIndex',
        converter: _converter,
        workerConverter: _workerConverter,
        enableWasmConverter: _enableWasmConverter,
        enableWasmTransferables: _enableWasmTransferables,
        isDebug: _isDebug,
      );
      if (_closed) {
        await bridge.close();
        return;
      }
      final slot = _PoolSlot<R, P>(index: slotIndex, bridge: bridge);
      _slots[slotIndex] = slot;
      _setupSlotListener(slot);
      _drain();
    } on Object catch (e, st) {
      if (!_streamController.isClosed) _streamController.addError(e, st);
    }
  }

  // -------------------------------------------------------------------------
  // Internal — dispatch
  // -------------------------------------------------------------------------

  void _sendToSlot(int slotIndex, _PendingRequest<R, P> req) {
    final slot = _slots[slotIndex];
    slot.inFlight++;

    if (req.stickyKey != null && _routing == BridgePoolRoutingStrategy.stickyKey) {
      _stickyMap[req.stickyKey!] = slotIndex;
    }

    final inFlight = _InFlightRequest<R>(
      slotIndex: slotIndex,
      completer: req.completer,
      onEvent: req.onEvent,
    );

    if (_outputRequestId != null) {
      _inFlightRequests[req.requestId] = inFlight;
    } else {
      _slotQueues[slotIndex].add(inFlight);
    }

    if (req.timeout != null) {
      inFlight.timeoutTimer = Timer(req.timeout!, () {
        if (req.completer.isCompleted) return;
        if (_outputRequestId != null) {
          _inFlightRequests.remove(req.requestId);
        } else {
          _slotQueues[slotIndex].remove(inFlight);
        }
        slot.inFlight--;
        req.completer.completeError(
          TimeoutException(
            'IsolateBridgePool.submit timed out for requestId: ${req.requestId}',
            req.timeout,
          ),
        );
        _drain();
      });
    }

    slot.bridge.send(req.message, transferables: req.transferables);
  }

  /// Dispatches as many pending requests as possible.
  ///
  /// Scans the full queue rather than stopping at the first blocked item, so
  /// requests that are not pinned to an overloaded slot are not unnecessarily
  /// delayed.
  void _drain() {
    if (_closed) return;
    var i = 0;
    while (i < _pendingQueue.length) {
      final req = _pendingQueue[i];
      final slotIndex = _findEligibleSlot(req.stickyKey, req.forcedSlotIndex);
      if (slotIndex != null) {
        _pendingQueue.removeAt(i);
        _sendToSlot(slotIndex, req);
      } else {
        i++;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Internal — routing
  // -------------------------------------------------------------------------

  /// Returns the index of an eligible slot (healthy and below capacity) for a
  /// [submit] call, or null when none is available.
  int? _findEligibleSlot(Object? stickyKey, int? forcedIndex) {
    if (forcedIndex != null) {
      final slot = _slots[forcedIndex];
      return (slot.healthy && slot.inFlight < _maxInFlightPerWorker) ? forcedIndex : null;
    }
    return switch (_routing) {
      BridgePoolRoutingStrategy.roundRobin => _roundRobinRoute(),
      BridgePoolRoutingStrategy.leastInFlight => _leastInFlightRoute(),
      BridgePoolRoutingStrategy.stickyKey => _stickyRoute(stickyKey),
    };
  }

  /// Returns a healthy slot for a fire-and-forget [send] call.
  ///
  /// Unlike [_findEligibleSlot], this ignores the [maxInFlightPerWorker] limit.
  _PoolSlot<R, P>? _findHealthySlot(Object? stickyKey, int? forcedIndex) {
    if (forcedIndex != null) {
      final slot = _slots[forcedIndex];
      return slot.healthy ? slot : null;
    }
    return switch (_routing) {
      BridgePoolRoutingStrategy.stickyKey => _stickySlotForSend(stickyKey),
      _ => _leastLoadedHealthySlot(),
    };
  }

  int? _computeForcedIndex(P message) {
    if (_router == null) return null;
    final views = [
      for (final s in _slots) BridgeSlotView(index: s.index, inFlight: s.inFlight, healthy: s.healthy),
    ];
    return _router(message, views);
  }

  int? _roundRobinRoute() {
    final start = _roundRobinIndex;
    for (var i = 0; i < _slots.length; i++) {
      final idx = (start + i) % _slots.length;
      final slot = _slots[idx];
      if (slot.healthy && slot.inFlight < _maxInFlightPerWorker) {
        _roundRobinIndex = (idx + 1) % _slots.length;
        return idx;
      }
    }
    return null;
  }

  int? _leastInFlightRoute() {
    int? best;
    var bestLoad = _maxInFlightPerWorker;
    for (final slot in _slots) {
      if (!slot.healthy) continue;
      if (slot.inFlight < bestLoad) {
        best = slot.index;
        bestLoad = slot.inFlight;
      }
    }
    return best;
  }

  int? _stickyRoute(Object? stickyKey) {
    if (stickyKey != null) {
      final idx = _stickyMap[stickyKey];
      if (idx != null) {
        final slot = _slots[idx];
        if (slot.healthy && slot.inFlight < _maxInFlightPerWorker) return idx;
      }
    }
    final fallback = _leastInFlightRoute();
    if (fallback != null && stickyKey != null) _stickyMap[stickyKey] = fallback;
    return fallback;
  }

  _PoolSlot<R, P>? _leastLoadedHealthySlot() {
    _PoolSlot<R, P>? best;
    for (final slot in _slots) {
      if (!slot.healthy) continue;
      if (best == null || slot.inFlight < best.inFlight) best = slot;
    }
    return best;
  }

  _PoolSlot<R, P>? _stickySlotForSend(Object? stickyKey) {
    if (stickyKey != null) {
      final idx = _stickyMap[stickyKey];
      if (idx != null && _slots[idx].healthy) return _slots[idx];
    }
    final slot = _leastLoadedHealthySlot();
    if (slot != null && stickyKey != null) _stickyMap[stickyKey] = slot.index;
    return slot;
  }
}
