/// Advanced, low-level primitives for building custom isolate / Web Worker
/// abstractions on top of `isolate_manager`.
///
/// These are intentionally kept out of the main `isolate_manager.dart` surface
/// so the everyday `IsolateManager` / `compute` API stays small. Import this
/// library only when you need to build your own controller-level abstraction
/// (for example a persistent bidirectional bridge) directly on top of the
/// package's platform channel:
///
/// ```dart
/// import 'package:isolate_manager/isolate_manager_advanced.dart';
/// ```
///
/// The exported `IsolateContactorController` is the platform-selected channel
/// controller that backs `IsolateManager`. It is lower level than
/// `IsolateManagerController` and gives direct access to the bidirectional
/// message ports, the initialization handshake, and lifecycle teardown.
library;

export 'src/base/contactor/isolate_contactor_controller.dart'
    show IsolateContactorController;
export 'src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_web.dart'
    if (dart.library.io) 'src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_stub.dart'
    show IsolateContactorControllerImpl;
