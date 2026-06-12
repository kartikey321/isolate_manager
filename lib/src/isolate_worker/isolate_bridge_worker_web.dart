// coverage:ignore-file

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:web/web.dart';

@JS('self')
external DedicatedWorkerGlobalScope get _self;

/// Boots an [IsolateBridgeController] inside a web worker and passes the first
/// message received from the main side as `initialParams`.
///
/// ```dart
/// import 'package:isolate_manager/isolate_manager.dart';
///
/// Future<void> main() {
///   return isolateBridgeWorkerMain<String, String>((controller, params) async {
///     controller.send('init:$params');
///     controller.messages.listen(controller.send);
///     controller.initialized();
///   });
/// }
/// ```
Future<void> isolateBridgeWorkerMain<R, P>(
  Future<void> Function(
    IsolateBridgeController<R, P> controller,
    Object? initialParams,
  )
  setup, {
  void Function()? onDispose,
}) async {
  final initialParamsCompleter = Completer<Object?>();

  _self.onmessage =
      ((MessageEvent event) {
        if (!initialParamsCompleter.isCompleted) {
          initialParamsCompleter.complete(event.data.dartify());
        }
      }).toJS;

  final initialParams = await initialParamsCompleter.future;
  final controller = IsolateBridgeController<R, P>(
    _self,
    onDispose: onDispose,
    initialParams: initialParams,
  );

  await setup(controller, initialParams);
}
