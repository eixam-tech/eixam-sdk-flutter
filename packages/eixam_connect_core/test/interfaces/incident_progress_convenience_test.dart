import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

const _watchdog = Duration(seconds: 2);

void main() {
  test(
    'direct provider control works without the convenience extension',
    () async {
      final progress = _progress(1);
      final provider = _ProviderSdk(
        Stream.value(progress),
        () async => progress,
      );
      final SosIncidentProgressProvider direct = provider;
      expect(await direct.getCurrentSosIncidentProgress(), same(progress));
      expect(
        await direct.currentSosIncidentProgressStream.first,
        same(progress),
      );
      expect(provider.snapshotCalls, 1);
      expect(provider.streamAccesses, 1);
    },
  );

  test(
    'base-typed snapshot delegates to provider once',
    () async {
      final progress = _progress(1);
      final provider = _ProviderSdk(const Stream.empty(), () async => progress);
      final EixamConnectSdk sdk = provider;
      expect(await sdk.getCurrentSosIncidentProgress(), same(progress));
      expect(provider.snapshotCalls, 1);
      expect(provider.streamAccesses, 0);
      expect(provider.unexpectedCalls, 0);
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test(
    'base-typed stream delegates to provider once',
    () async {
      final source = _CountingStream<SosIncidentProgress?>(Stream.value(null));
      final provider = _ProviderSdk(source);
      final EixamConnectSdk sdk = provider;
      final stream = sdk.currentSosIncidentProgressStream;
      expect(stream, same(source));
      expect(provider.streamAccesses, 1);
      expect(source.subscriptions, 0);
      expect(stream.isBroadcast, false);
      expect(await stream.first, isNull);
      expect(source.subscriptions, 1);
      expect(provider.snapshotCalls, 0);
      expect(provider.unexpectedCalls, 0);
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test('provider snapshot preserves null and asynchronous error', () async {
    final error = StateError('snapshot sentinel');
    final stack = StackTrace.fromString('snapshot-stack');
    final provider = _ProviderSdk(const Stream.empty(), () async => null);
    final EixamConnectSdk sdk = provider;
    expect(await sdk.getCurrentSosIncidentProgress(), isNull);
    provider.read = () => Future.error(error, stack);
    await expectLater(
      sdk.getCurrentSosIncidentProgress(),
      throwsA(same(error)),
    );
    expect(provider.snapshotCalls, 2);
    expect(provider.unexpectedCalls, 0);
  });

  test('provider stream preserves active values and ordered updates', () async {
    final progress = [_progress(1), _progress(2), _progress(3)];
    final source = _CountingStream<SosIncidentProgress?>(
      Stream.fromIterable(progress),
    );
    final provider = _ProviderSdk(source);
    final EixamConnectSdk sdk = provider;
    expect(await sdk.currentSosIncidentProgressStream.toList(), progress);
    expect(source.subscriptions, 1);
    expect(provider.streamAccesses, 1);
  });

  test('provider owns duplicate filtering; convenience adds none', () async {
    final a = _progress(1);
    final duplicate = _progress(1);
    final b = _progress(2);
    final source = _CountingStream<SosIncidentProgress?>(
      Stream.fromIterable([
        null,
        null,
        a,
        duplicate,
        b,
      ]).distinct((previous, next) => previous?.revision == next?.revision),
    );
    final EixamConnectSdk sdk = _ProviderSdk(source);
    expect(await sdk.currentSosIncidentProgressStream.toList(), [null, a, b]);
    expect(source.subscriptions, 1);
  });

  test(
    'provider errors, subsequent values and completion pass through',
    () async {
      final controller = StreamController<SosIncidentProgress?>();
      addTearDown(controller.close);
      final source = _CountingStream(controller.stream);
      final EixamConnectSdk sdk = _ProviderSdk(source);
      final values = <SosIncidentProgress?>[];
      final errors = <Object>[];
      final stacks = <StackTrace>[];
      final done = Completer<void>();
      final subscription = sdk.currentSosIncidentProgressStream.listen(
        values.add,
        onError: (Object error, StackTrace stack) {
          errors.add(error);
          stacks.add(stack);
        },
        onDone: done.complete,
      );
      addTearDown(subscription.cancel);
      final error = StateError('stream sentinel');
      final stack = StackTrace.fromString('stream-stack');
      final active = _progress(1);
      controller.add(null);
      controller.addError(error, stack);
      controller.add(active);
      await controller.close();
      await done.future.timeout(_watchdog);
      expect(values, [null, active]);
      expect(errors.single, same(error));
      expect(stacks.single, same(stack));
      expect(source.subscriptions, 1);
    },
  );

  test('provider idle cancellation detaches without a new event', () async {
    final controller = StreamController<SosIncidentProgress?>();
    addTearDown(controller.close);
    final provider = _ProviderSdk(_CountingStream(controller.stream));
    final EixamConnectSdk sdk = provider;
    final values = <SosIncidentProgress?>[];
    final subscription = sdk.currentSosIncidentProgressStream.listen(
      values.add,
    );
    addTearDown(subscription.cancel);
    controller.add(null);
    await pumpEventQueue();
    expect(values, [null]);
    await subscription.cancel().timeout(_watchdog);
    expect(controller.hasListener, false);
    expect(provider.unexpectedCalls, 0);
  });

  test('provider pause resume retains order and buffered duplicates', () async {
    final controller = StreamController<SosIncidentProgress?>();
    addTearDown(controller.close);
    final EixamConnectSdk sdk = _ProviderSdk(controller.stream);
    final values = <SosIncidentProgress?>[];
    final subscription = sdk.currentSosIncidentProgressStream.listen(
      values.add,
    );
    addTearDown(subscription.cancel);
    final a = _progress(1);
    final b = _progress(2);
    subscription.pause();
    controller.add(a);
    controller.add(a);
    controller.add(b);
    await pumpEventQueue();
    expect(values, isEmpty);
    subscription.resume();
    await pumpEventQueue();
    expect(values, [a, a, b]);
  });

  test('provider broadcast and two observers remain independent', () async {
    final controller = StreamController<SosIncidentProgress?>.broadcast();
    addTearDown(controller.close);
    final source = _CountingStream(controller.stream);
    final provider = _ProviderSdk(source);
    final EixamConnectSdk sdk = provider;
    final a = <SosIncidentProgress?>[];
    final b = <SosIncidentProgress?>[];
    final firstStream = sdk.currentSosIncidentProgressStream;
    final secondStream = sdk.currentSosIncidentProgressStream;
    expect(firstStream.isBroadcast, true);
    final first = firstStream.listen(a.add);
    addTearDown(first.cancel);
    final second = secondStream.listen(b.add);
    addTearDown(second.cancel);
    controller.add(null);
    await pumpEventQueue();
    await first.cancel().timeout(_watchdog);
    final active = _progress(1);
    controller.add(active);
    await pumpEventQueue();
    expect(a, [null]);
    expect(b, [null, active]);
    expect(provider.streamAccesses, 2);
    expect(source.subscriptions, 2);
    expect(provider.unexpectedCalls, 0);
  });

  test(
    'external required-only SDK retains null and active snapshot fallback',
    () async {
      final external = _RequiredSdk(const Stream.empty(), () async => null);
      final EixamConnectSdk sdk = external;
      expect(sdk, isNot(isA<SosIncidentProgressProvider>()));
      expect(await sdk.getCurrentSosIncidentProgress(), isNull);
      final incident = _incident();
      external.read = () async => incident;
      expect(
        (await sdk.getCurrentSosIncidentProgress())?.incidentId,
        incident.id,
      );
      expect(external.incidentReads, 2);
      expect(external.stateAccesses, 0);
      expect(external.unexpectedCalls, 0);
    },
  );

  test(
    'fallback has no added seed and retains duplicates and lazy reads',
    () async {
      final controller = StreamController<SosState>();
      addTearDown(controller.close);
      final source = _CountingStream(controller.stream);
      final external = _RequiredSdk(source, () async => _incident());
      final EixamConnectSdk sdk = external;
      final stream = sdk.currentSosIncidentProgressStream;
      expect(external.incidentReads, 0);
      expect(source.subscriptions, 0);
      final values = <SosIncidentProgress?>[];
      final subscription = stream.listen(values.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(values, isEmpty);
      expect(external.incidentReads, 0);
      controller.add(SosState.sent);
      controller.add(SosState.sent);
      await pumpEventQueue();
      expect(values.map((p) => p?.incidentId), ['fallback', 'fallback']);
      expect(external.incidentReads, 2);
      expect(external.stateAccesses, 1);
      expect(source.subscriptions, 1);
      expect(external.unexpectedCalls, 0);
      await subscription.cancel().timeout(_watchdog);
      expect(controller.hasListener, false);
    },
  );

  test('fallback awaits each lookup in order', () async {
    final controller = StreamController<SosState>();
    addTearDown(controller.close);
    final reads = [Completer<SosIncident?>(), Completer<SosIncident?>()];
    var next = 0;
    final external = _RequiredSdk(
      controller.stream,
      () => reads[next++].future,
    );
    final EixamConnectSdk sdk = external;
    final values = <SosIncidentProgress?>[];
    final subscription = sdk.currentSosIncidentProgressStream.listen(
      values.add,
    );
    addTearDown(subscription.cancel);
    controller.add(SosState.sent);
    controller.add(SosState.acknowledged);
    await pumpEventQueue();
    expect(external.incidentReads, 1);
    expect(values, isEmpty);
    reads[0].complete(null);
    await pumpEventQueue();
    expect(values, [null]);
    expect(external.incidentReads, 2);
    reads[1].complete(_incident());
    await pumpEventQueue();
    expect(values.last?.incidentId, 'fallback');
  });

  test('fallback snapshot errors propagate', () async {
    final error = StateError('fallback snapshot');
    final external = _RequiredSdk(
      const Stream.empty(),
      () => Future.error(error),
    );
    final EixamConnectSdk sdk = external;
    await expectLater(
      sdk.getCurrentSosIncidentProgress(),
      throwsA(same(error)),
    );
    expect(external.incidentReads, 1);
    expect(external.unexpectedCalls, 0);
  });

  test(
    'fallback forwards source and lookup errors then continues until close',
    () async {
      final controller = StreamController<SosState>();
      addTearDown(controller.close);
      final sourceError = StateError('fallback source');
      final lookupError = StateError('fallback lookup');
      final stack = StackTrace.fromString('fallback-source-stack');
      var failLookup = true;
      final external = _RequiredSdk(controller.stream, () async {
        if (failLookup) {
          failLookup = false;
          throw lookupError;
        }
        return null;
      });
      final EixamConnectSdk sdk = external;
      final errors = <Object>[];
      final stacks = <StackTrace>[];
      final values = <SosIncidentProgress?>[];
      final done = Completer<void>();
      final subscription = sdk.currentSosIncidentProgressStream.listen(
        values.add,
        onError: (Object error, StackTrace stack) {
          errors.add(error);
          stacks.add(stack);
        },
        onDone: done.complete,
      );
      addTearDown(subscription.cancel);
      controller.addError(sourceError, stack);
      controller.add(SosState.sent);
      controller.add(SosState.idle);
      await controller.close();
      await done.future.timeout(_watchdog);
      expect(errors, [sourceError, lookupError]);
      expect(stacks.first, same(stack));
      expect(values, [null]);
      expect(external.incidentReads, 2);
      expect(external.unexpectedCalls, 0);
    },
  );
}

SosIncidentProgress _progress(int revision) => SosIncidentProgress(
  incidentId: 'provider',
  steps: const [],
  lastUpdatedAt: DateTime.utc(2026),
  isTerminal: false,
  revision: revision,
);

SosIncident _incident() => SosIncident(
  id: 'fallback',
  state: SosState.sent,
  createdAt: DateTime.utc(2026),
);

class _ProviderSdk implements EixamConnectSdk, SosIncidentProgressProvider {
  _ProviderSdk(this.output, [Future<SosIncidentProgress?> Function()? read])
    : read = read ?? (() async => null);
  final Stream<SosIncidentProgress?> output;
  Future<SosIncidentProgress?> Function() read;
  int snapshotCalls = 0;
  int streamAccesses = 0;
  int unexpectedCalls = 0;
  @override
  Future<SosIncidentProgress?> getCurrentSosIncidentProgress() {
    snapshotCalls++;
    return read();
  }

  @override
  Stream<SosIncidentProgress?> get currentSosIncidentProgressStream {
    streamAccesses++;
    return output;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    throw StateError('Unexpected SDK operation: ${invocation.memberName}');
  }
}

class _RequiredSdk implements EixamConnectSdk {
  _RequiredSdk(this.states, this.read);
  final Stream<SosState> states;
  Future<SosIncident?> Function() read;
  int incidentReads = 0;
  int stateAccesses = 0;
  int unexpectedCalls = 0;
  @override
  Future<SosIncident?> getCurrentSosIncident() {
    incidentReads++;
    return read();
  }

  @override
  Stream<SosState> get currentSosStateStream {
    stateAccesses++;
    return states;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    throw StateError('Unexpected SDK operation: ${invocation.memberName}');
  }
}

class _CountingStream<T> extends Stream<T> {
  _CountingStream(this.source);
  final Stream<T> source;
  int subscriptions = 0;
  @override
  bool get isBroadcast => source.isBroadcast;
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    subscriptions++;
    return source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
