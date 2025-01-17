import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import '../modelinfo/entity_definition.dart';
import 'bindings/bindings.dart';
import 'bindings/helpers.dart';
import 'query/query.dart';
import 'store.dart';

/// Simple wrapper used below in ObservableStore to reduce code duplication.
/// Contains shared code for single-entity observer and the generic/global one.
class _Observer<StreamValueType> {
  /*late final*/ StreamController<StreamValueType> controller;
  Pointer<OBX_observer> /*?*/ _cObserver;
  ReceivePort /*?*/ receivePort;

  int get nativePort => receivePort /*!*/ .sendPort.nativePort;

  set cObserver(Pointer<OBX_observer> value) {
    _cObserver = checkObxPtr(value, 'observer initialization failed');
    _debugLog('started');
  }

  Stream<StreamValueType> get stream => controller.stream;

  _Observer() {
    initializeDartAPI();
  }

  // start() is called whenever user starts listen()-ing to the stream
  void init(void Function() start) {
    controller = StreamController<StreamValueType>(
        onListen: start, onPause: stop, onResume: start, onCancel: stop);
  }

  // stop() is called when the stream subscription is paused or canceled
  void stop() {
    _debugLog('stopped');
    if (_cObserver != null) {
      checkObx(C.observer_close(_cObserver));
      _cObserver = null;
    }

    if (receivePort != null) {
      receivePort.close();
      receivePort = null;
    }
  }

  void _debugLog(String message) {
    // print('Observer=${_cObserver?.address} $message');
  }
}

/// StreamController implementation inspired by the sample controller sample at:
/// https://dart.dev/articles/libraries/creating-streams#honoring-the-pause-state
/// https://dart.dev/articles/libraries/code/stream_controller.dart
extension ObservableStore on Store {
  /// Create a stream to data changes on EntityT (stored Entity class).
  ///
  /// The stream receives an event whenever an object of EntityT is created or
  /// changed or deleted. Make sure to cancel() the subscription after you're
  /// done with it to avoid hanging change listeners.
  Stream<void> subscribe<EntityT>() {
    final observer = _Observer<void>();
    final entityId = InternalStoreAccess.entityDef<EntityT>(this).model.id.id;

    observer.init(() {
      // We're listening to events on single entity so there's no argument.
      // Ideally, controller.add() would work but it doesn't, even though we're
      // using StreamController<Void> so the argument type is `void`.
      observer.receivePort = ReceivePort()
        ..listen((dynamic _) => observer.controller.add(null));
      observer.cObserver = C.dartc_observe_single_type(
          InternalStoreAccess.ptr(this), entityId, observer.nativePort);
    });

    return observer.stream;
  }

  /// Create a stream to data changes on all Entity types.
  ///
  /// The stream receives an event whenever any data changes in the database.
  /// Make sure to cancel() the subscription after you're done with it to avoid
  /// hanging change listeners.
  Stream<Type> subscribeAll() {
    initializeDartAPI();
    final observer = _Observer<Type>();

    // create a map from Entity ID to Entity type (dart class)
    final entityTypesById = <int, Type>{};
    InternalStoreAccess.defs(this).bindings.forEach(
        (Type entity, EntityDefinition entityDef) =>
            entityTypesById[entityDef.model.id.id] = entity);

    observer.init(() {
      // We're listening to a events for all entity types. C-API sends entity ID
      // and we must map it to a dart type (class) corresponding to that entity.
      observer.receivePort = ReceivePort()
        ..listen((dynamic entityIds) {
          if (entityIds is! Uint32List) {
            observer.controller.addError(Exception(
                'Received invalid data format from the core notification: (${entityIds.runtimeType}) $entityIds'));
            return;
          }

          (entityIds as Uint32List).forEach((int entityId) {
            if (entityId is! int) {
              observer.controller.addError(Exception(
                  'Received invalid item data format from the core notification: (${entityId.runtimeType}) $entityId'));
              return;
            }

            final entityType = entityTypesById[entityId];
            if (entityType == null) {
              observer.controller.addError(Exception(
                  'Received data change notification for an unknown entity ID $entityId'));
            } else {
              observer.controller.add(entityType);
            }
          });
        });
      observer.cObserver =
          C.dartc_observe(InternalStoreAccess.ptr(this), observer.nativePort);
    });

    return observer.stream;
  }
}

/// Streamable adds stream support to queries.
extension Streamable<T> on Query<T> {
  /// Create a stream, executing [Query.find()] whenever there's a change to any
  /// of the objects in the queried Box.
  /// TODO consider removing, see issue #195
  Stream<List<T>> findStream() => stream.map((q) => q.find());

  /// The stream gets notified whenever there's a change in any of the objects
  /// in the queried Box (regardless of the filter conditions).
  ///
  /// You can use the given [Query] object to run any of its operation,
  /// e.g. find(), count(), execute a [property()] query
  Stream<Query<T>> get stream => store.subscribe<T>().map((_) => this);
}
