// coverage:ignore-file
// Dart-idiomatic wrapper around the `BroadcastChannel` API.
//
// Gives every JS context on the same origin (tabs, dedicated workers, shared
// workers) a named fan-out channel independent of any MessagePort. Intended
// as a second, ordering-independent signal alongside a MessagePort-based
// protocol — e.g. a shutdown broadcast that every listener sees regardless of
// which port-based connection state they're currently in.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// A named [web.BroadcastChannel], exposed as a [Stream] instead of an
/// `onmessage` callback.
class WebBroadcastChannel {
  /// Opens (or joins) the channel named [name]. Every [WebBroadcastChannel]
  /// with the same [name] on the same origin receives what any other one
  /// [send]s (never its own sends).
  WebBroadcastChannel(String name) : _channel = web.BroadcastChannel(name) {
    _channel.onmessage =
        ((web.MessageEvent event) {
          if (!_controller.isClosed) _controller.add(event.data.dartify());
        }).toJS;
  }

  final web.BroadcastChannel _channel;
  final StreamController<Object?> _controller =
      StreamController<Object?>.broadcast();

  /// This channel's name, as passed to the constructor.
  String get name => _channel.name;

  /// Messages sent by any other [WebBroadcastChannel] with this [name].
  Stream<Object?> get messages => _controller.stream;

  /// Broadcasts [data] to every other listener on this [name].
  void send(Object? data) => _channel.postMessage(data.jsify());

  /// Closes this side of the channel. Other listeners are unaffected.
  Future<void> close() async {
    _channel.close();
    await _controller.close();
  }
}
