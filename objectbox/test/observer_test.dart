import 'dart:async';

import 'package:test/test.dart';

import 'entity.dart';
import 'entity2.dart';
import 'objectbox.g.dart';
import 'test_env.dart';

void main() async {
  /*late final*/ TestEnv env;
  /*late final*/
  Box<TestEntity> box;

  final simpleStringItems = () => <String>[
        'One',
        'Two',
        'Three',
        'Four',
        'Five',
        'Six'
      ].map((s) => TestEntity(tString: s)).toList().cast<TestEntity>();

  setUp(() {
    env = TestEnv('observers');
    box = env.box;
  });

  tearDown(() {
    env.close();
  });

  if (!asyncCallbacksAvailable()) return;

  test('Observe single entity', () async {
    Completer<void> completer;
    var expectedEvents = 0;

    final stream = env.store.subscribe<TestEntity>();
    final subscription = stream.listen((_) {
      print('TestEntity updated');
      expectedEvents--;
      if (expectedEvents == 0) {
        completer.complete();
      }
    });

    // expect two events after one put() and one putMany()
    expectedEvents = 2;
    completer = Completer();
    box.put(simpleStringItems().first);
    Box<TestEntity2>(env.store).put(TestEntity2());
    box.putMany(simpleStringItems());
    await completer.future.timeout(defaultTimeout);
    expect(expectedEvents, 0);

    // cancel the subscription
    await subscription.cancel();

    // make sure there are no more events after cancelling
    expectedEvents = 1;
    completer = Completer();
    box.put(simpleStringItems().first);
    expect(completer.future.timeout(defaultTimeout),
        throwsA(isA<TimeoutException>()));
    expect(expectedEvents, 1); // note: unchanged, no events received anymore
  });

  test('Observe multiple entities', () async {
    Completer<void> completer;
    var expectedEvents = 0;
    var typesUpdates = <Type, int>{}; // number of events per entity type

    final stream = env.store.subscribeAll();

    final subscription = stream.listen((entityType) {
      print('Entity updated: $entityType');
      expectedEvents--;

      if (typesUpdates[entityType] == null) {
        typesUpdates[entityType] = 0;
      }
      typesUpdates[entityType]++;

      if (expectedEvents == 0) {
        completer.complete();
      }
    });

    // expect three events: two puts() (separate entities), one putMany()
    expectedEvents = 3;
    completer = Completer();
    box.put(simpleStringItems().first);
    Box<TestEntity2>(env.store).put(TestEntity2());
    box.putMany(simpleStringItems());
    await completer.future.timeout(defaultTimeout);
    expect(expectedEvents, 0);
    expect(typesUpdates.keys, sameAsList<Type>([TestEntity, TestEntity2]));
    expect(typesUpdates[TestEntity], 2);
    expect(typesUpdates[TestEntity2], 1);

    // cancel the subscription
    await subscription.cancel();

    // make sure there are no more events after cancelling
    expectedEvents = 1;
    completer = Completer();
    box.put(simpleStringItems().first);
    expect(completer.future.timeout(defaultTimeout),
        throwsA(isA<TimeoutException>()));
    expect(expectedEvents, 1); // note: unchanged, no events received anymore
  });

  test('Observer pause/resume', () async {
    final testPauseResume = (Stream stream) async {
      Completer<void> completer;
      final subscription = stream.listen((dynamic _) {
        completer.complete();
      });

      // triggers when listening
      completer = Completer();
      box.put(simpleStringItems().first);
      await completer.future.timeout(defaultTimeout);

      // won't trigger when paused
      subscription.pause();
      completer = Completer();
      box.put(simpleStringItems().first);
      expect(completer.future.timeout(defaultTimeout),
          throwsA(isA<TimeoutException>()));

      // triggers when resumed (Note: no buffering of previous events)
      subscription.resume();
      completer = Completer();
      box.put(simpleStringItems().first);
      await completer.future.timeout(defaultTimeout);

      // won't trigger when cancelled
      await subscription.cancel();
      completer = Completer();
      box.put(simpleStringItems().first);
      expect(completer.future.timeout(defaultTimeout),
          throwsA(isA<TimeoutException>()));
    };

    await testPauseResume(env.store.subscribe<TestEntity>());
    await testPauseResume(env.store.subscribeAll());
  });
}
