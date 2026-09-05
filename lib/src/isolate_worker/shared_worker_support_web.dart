// coverage:ignore-file
// Feature detection for the SharedWorker constructor itself.
//
// Not every browser implements SharedWorker — notably Android Chrome does
// not (https://issues.chromium.org/issues/40290702, tracked upstream at
// https://github.com/livestorejs/livestore/issues/321 for a comparable
// project's web adapter). Callers that offer a SharedWorker-based mode as
// an enhancement over a single-tab fallback should check this before ever
// calling `IsolateBridge.spawn(sharedWorker: true, ...)` — constructing a
// SharedWorker where the global doesn't exist fails as a raw JS interop
// error, not a catchable Dart exception.

import 'dart:js_interop';

@JS('SharedWorker')
external JSAny? get _sharedWorkerConstructor;

/// Whether the `SharedWorker` constructor is available in this JS context.
///
/// False on browsers/embedders that don't implement it (e.g. Android
/// Chrome). Always call this before passing `sharedWorker: true` to
/// `IsolateBridge.spawn` if the caller can fall back to a dedicated worker
/// instead.
bool get isSharedWorkerSupported => _sharedWorkerConstructor != null;
