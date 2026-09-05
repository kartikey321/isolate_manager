// Dedicated Worker fixture for IsolateBridge browser tests.
//
// Mirrors the pattern a "leader worker" (in a SharedWorker proxy topology)
// uses to receive a MessagePort as part of its own initial handshake: the
// worker wires its own self.onmessage BEFORE constructing IsolateBridgeController,
// captures the first message's data AND event.ports itself, then hands the
// captured data to IsolateBridgeController as an explicit initialParams so it
// does not try to re-capture the (already consumed) first message.

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:web/web.dart';

@JS('self')
external DedicatedWorkerGlobalScope get _self;

void main() {
  final initialCompleter = Completer<(Object?, List<MessagePort>)>();

  _self.onmessage =
      ((MessageEvent event) {
        if (!initialCompleter.isCompleted) {
          initialCompleter.complete((
            event.data.dartify(),
            event.ports.toDart,
          ));
        }
      }).toJS;

  unawaited(
    initialCompleter.future.then((captured) {
      final (initialData, ports) = captured;
      final controller = IsolateBridgeController<Object?, Object?>(
        _self,
        initialParams: initialData,
      )..initialized();

      if (ports.isNotEmpty) {
        late final MessagePort handedOffPort;
        handedOffPort =
            ports.first
              ..start()
              ..onmessage =
                  ((MessageEvent inner) {
                    handedOffPort.postMessage(
                      <String, Object?>{
                        'type': 'handoffEcho',
                        'value': inner.data.dartify(),
                      }.jsify(),
                    );
                  }).toJS;
      }

      controller.send(<String, Object?>{
        'type': 'booted',
        'initial': initialData,
        'receivedPortCount': ports.length,
      });
    }),
  );
}
