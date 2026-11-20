import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/ambiguous_tag_sos_prompt_tracker.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AmbiguousTagSosPromptTracker (F17c)', () {
    late ProtectionOwnTagSosPrompt? native;
    late List<String> answers;
    late String answerResult;
    late AmbiguousTagSosPromptTracker tracker;
    final now = DateTime.utc(2026, 11, 16, 12);

    setUp(() {
      native = null;
      answers = <String>[];
      answerResult = 'none';
      tracker = AmbiguousTagSosPromptTracker(
        read: () async => native,
        answer: (choice) async {
          answers.add(choice);
          if (answerResult != 'none') {
            native = null;
          }
          return answerResult;
        },
        clock: () => now,
      );
    });

    tearDown(() => tracker.dispose());

    test('mirrors native: opened, then closed; watch seeds the current '
        'value', () async {
      final seen = <AmbiguousTagSosPrompt?>[];
      final sub = tracker.watch().listen(seen.add);
      await pumpEventQueue();
      native = ProtectionOwnTagSosPrompt(
        terminal: 'resolve',
        deadlineAt: now.add(const Duration(seconds: 30)),
      );
      await tracker.refresh('opened');
      expect(tracker.current?.terminal, AmbiguousTagSosTerminal.resolve);
      expect(tracker.current?.secondsLeft(now), 30);
      native = null;
      await tracker.refresh('closed');
      await pumpEventQueue();
      expect(seen, hasLength(3));
      expect(seen.first, isNull);
      expect(seen[1]?.terminal, AmbiguousTagSosTerminal.resolve);
      expect(seen.last, isNull);
      await sub.cancel();
    });

    test('answers map to outcomes and re-read native', () async {
      native = ProtectionOwnTagSosPrompt(
        terminal: 'cancel',
        deadlineAt: now.add(const Duration(seconds: 30)),
      );
      await tracker.refresh('opened');
      answerResult = 'stop';
      expect(
        await tracker.answer(AmbiguousTagSosChoice.stopTag),
        AmbiguousTagSosAnswerOutcome.tagStopped,
      );
      expect(answers, <String>['stopTag']);
      expect(tracker.current, isNull);
      answerResult = 'sosOpened';
      expect(
        await tracker.answer(AmbiguousTagSosChoice.sendSos),
        AmbiguousTagSosAnswerOutcome.sosSent,
      );
      answerResult = 'none';
      expect(
        await tracker.answer(AmbiguousTagSosChoice.sendSos),
        AmbiguousTagSosAnswerOutcome.noPrompt,
      );
      expect(answers, <String>['stopTag', 'sendSos', 'sendSos']);
    });

    test('a failed read keeps what is shown (native still owns the '
        'timeout)', () async {
      var fail = false;
      final failing = AmbiguousTagSosPromptTracker(
        read: () async {
          if (fail) throw StateError('channel');
          return ProtectionOwnTagSosPrompt(
            terminal: 'cancel',
            deadlineAt: now.add(const Duration(seconds: 30)),
          );
        },
        answer: (_) async => 'none',
        clock: () => now,
      );
      await failing.refresh('opened');
      fail = true;
      await failing.refresh('again');
      expect(failing.current, isNotNull);
      await failing.dispose();
    });

    test('sign-out clears at once; a read started before it never '
        'resurrects the prompt', () async {
      final gate = Completer<ProtectionOwnTagSosPrompt?>();
      final slow = AmbiguousTagSosPromptTracker(
        read: () => gate.future,
        answer: (_) async => 'none',
        clock: () => now,
      );
      final pending = slow.refresh('opened');
      slow.clear('session_changed');
      gate.complete(
        ProtectionOwnTagSosPrompt(
          terminal: 'cancel',
          deadlineAt: now.add(const Duration(seconds: 30)),
        ),
      );
      await pending;
      expect(slow.current, isNull);
      await slow.dispose();
    });

    test('native prompt map parsing', () {
      expect(ProtectionOwnTagSosPrompt.fromMap(null), isNull);
      expect(ProtectionOwnTagSosPrompt.fromMap(<String, Object>{}), isNull);
      final parsed = ProtectionOwnTagSosPrompt.fromMap(<String, Object>{
        'terminal': 'resolve',
        'deadlineAtMs': now.millisecondsSinceEpoch,
      });
      expect(parsed?.terminal, 'resolve');
      expect(parsed?.deadlineAt, now);
    });

    test('secondsLeft counts 30 s to 0, never negative', () {
      final prompt = AmbiguousTagSosPrompt(
        terminal: AmbiguousTagSosTerminal.cancel,
        deadline: now.add(const Duration(seconds: 30)),
      );
      expect(prompt.secondsLeft(now), 30);
      expect(
        prompt.secondsLeft(now.add(const Duration(milliseconds: 29001))),
        1,
      );
      expect(prompt.secondsLeft(now.add(const Duration(seconds: 30))), 0);
      expect(prompt.secondsLeft(now.add(const Duration(minutes: 1))), 0);
    });
  });
}
