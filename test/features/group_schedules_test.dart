import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/admissions/presentation/group_schedules_dialog.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_repository.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

Group group(
  int id,
  String name, {
  List<ScheduleSlot> schedule = const [],
  int? capacity,
}) => Group(
  id: id,
  subjectId: 1,
  name: name,
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: 'fixed_day',
  billingDay: 1,
  capacity: capacity,
  isActive: true,
  schedule: schedule,
);

ScheduleSlot slot(int weekday, int h, [int endH = 0]) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: 0),
  endsAt: TimeOfDay(hour: endH == 0 ? h + 1 : endH, minute: 30),
);

class FakeGroups implements GroupsRepository {
  FakeGroups(this.groups);
  final List<Group> groups;
  final updates = <({int id, int? capacity})>[];

  @override
  Future<List<Group>> list({bool includeInactive = false}) async => groups;

  @override
  Future<Group> update(
    int id, {
    required int subjectId,
    required String name,
    int? teacherId,
    required int feeAmount,
    required String billingMode,
    int? billingDay,
    bool prorateFirstPeriod = true,
    int? capacity,
    String? note,
  }) async {
    updates.add((id: id, capacity: capacity));
    return groups.firstWhere((g) => g.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTimetable implements TimetableRepository {
  final saved = <int, List<ScheduleSlot>>{};
  final Map<int, String> refuse = {};

  @override
  Future<void> setSchedule(int groupId, List<ScheduleSlot> slots) async {
    if (refuse.containsKey(groupId)) throw ApiException(409, refuse[groupId]!);
    saved[groupId] = slots;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<({FakeGroups groups, FakeTimetable timetable})> open(
  WidgetTester tester,
  List<Group> list, {
  FakeTimetable? timetable,
}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final groups = FakeGroups(list);
  final tt = timetable ?? FakeTimetable();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        groupsRepositoryProvider.overrideWithValue(groups),
        timetableRepositoryProvider.overrideWithValue(tt),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showGroupSchedulesDialog(context),
              child: const Text('ochish'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ochish'));
  await tester.pumpAndSettle();
  return (groups: groups, timetable: tt);
}

Future<void> type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  test('times are read as 09:00, 9:00, 0900 or 9.00, and nothing else', () {
    expect(parseClock('09:00'), const TimeOfDay(hour: 9, minute: 0));
    expect(parseClock('9:30'), const TimeOfDay(hour: 9, minute: 30));
    expect(parseClock('1830'), const TimeOfDay(hour: 18, minute: 30));
    expect(parseClock('9.05'), const TimeOfDay(hour: 9, minute: 5));
    for (final bad in ['', '25:00', '09:60', '9', 'abc', '09:0']) {
      expect(parseClock(bad), isNull, reason: bad);
    }
  });

  testWidgets('every group is on one screen, with what it already has', (
    tester,
  ) async {
    await open(tester, [
      group(1, 'Ingliz tili - Beginner'),
      group(
        2,
        'Matematika',
        schedule: [slot(1, 15), slot(3, 15), slot(5, 15)],
        capacity: 12,
      ),
    ]);
    expect(find.text('Ingliz tili - Beginner'), findsOneWidget);
    expect(find.text('Matematika'), findsOneWidget);
    expect(find.text('Madina Karimova'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('start-2')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('start-2')))
          .controller!
          .text,
      '15:00',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('end-2')))
          .controller!
          .text,
      '16:30',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('capacity-2')))
          .controller!
          .text,
      '12',
    );
    // Nothing changed yet: nothing to save.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('save-schedules')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'days, times and seats of several groups are saved in one go; untouched groups are left alone',
    (tester) async {
      final o = await open(tester, [
        group(1, 'Ingliz tili - Beginner'),
        group(2, 'Matematika', schedule: [slot(1, 15)]),
        group(3, 'Fizika'),
      ]);
      // Group 1: Du Chor Ju 09:00-10:30, 14 seats.
      for (final d in [1, 3, 5]) {
        await tester.tap(find.byKey(ValueKey('day-1-$d')));
      }
      await type(tester, 'start-1', '0900');
      await type(tester, 'end-1', '10:30');
      await type(tester, 'capacity-1', '14');
      // Group 3: only seats.
      await type(tester, 'capacity-3', '10');
      await tester.pump();
      expect(find.text('Hammasini saqlash (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('save-schedules')));
      await tester.pumpAndSettle();

      final slots = o.timetable.saved[1]!;
      expect([for (final s in slots) s.weekday], [1, 3, 5]);
      expect(
        slots.every((s) => s.startsAt == const TimeOfDay(hour: 9, minute: 0)),
        isTrue,
      );
      expect(
        slots.every((s) => s.endsAt == const TimeOfDay(hour: 10, minute: 30)),
        isTrue,
      );
      expect(o.groups.updates, [(id: 1, capacity: 14), (id: 3, capacity: 10)]);
      // Group 2 was not touched and group 3's schedule was not rewritten.
      expect(o.timetable.saved.containsKey(2), isFalse);
      expect(o.timetable.saved.containsKey(3), isFalse);
      // Everything saved, so the screen closes.
      expect(find.text('Guruh jadvallari'), findsNothing);
    },
  );

  testWidgets(
    'a time that is not a time is refused on that row; the other rows still save',
    (tester) async {
      final o = await open(tester, [
        group(1, 'Ingliz tili - Beginner'),
        group(2, 'Fizika'),
      ]);
      await tester.tap(find.byKey(const ValueKey('day-1-1')));
      await type(tester, 'start-1', '25:99');
      await type(tester, 'end-1', '10:30');
      await tester.tap(find.byKey(const ValueKey('day-2-2')));
      await type(tester, 'start-2', '18:00');
      await type(tester, 'end-2', '19:30');
      await tester.tap(find.byKey(const ValueKey('save-schedules')));
      await tester.pumpAndSettle();
      expect(find.text('Vaqtni 09:00 ko\'rinishida kiriting.'), findsOneWidget);
      expect(o.timetable.saved.keys, [2]);
      expect(find.text('1 ta saqlandi, 1 tasida xato bor.'), findsOneWidget);
      // The screen stays open so the error can be fixed.
      expect(find.text('Guruh jadvallari'), findsOneWidget);
    },
  );

  testWidgets(
    'a clash reported by the server is shown on the group it belongs to',
    (tester) async {
      final timetable = FakeTimetable()
        ..refuse[1] = 'O\'qituvchi shu vaqtda band.';
      await open(tester, [
        group(1, 'Ingliz tili - Beginner'),
      ], timetable: timetable);
      await tester.tap(find.byKey(const ValueKey('day-1-1')));
      await type(tester, 'start-1', '09:00');
      await type(tester, 'end-1', '10:30');
      await tester.tap(find.byKey(const ValueKey('save-schedules')));
      await tester.pumpAndSettle();
      expect(find.text('O\'qituvchi shu vaqtda band.'), findsOneWidget);
    },
  );

  testWidgets(
    'a group with a different time on each day is not overwritten here',
    (tester) async {
      final o = await open(tester, [
        group(1, 'Aralash', schedule: [slot(1, 9), slot(3, 18)]),
      ]);
      expect(find.textContaining('turli vaqtda'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('start-1'))).enabled,
        isFalse,
      );
      expect(find.byKey(const ValueKey('day-1-1')), findsNothing);
      expect(o.timetable.saved, isEmpty);
    },
  );

  testWidgets('clearing the seats removes the limit', (tester) async {
    final o = await open(tester, [
      group(1, 'Matematika', schedule: [slot(1, 15)], capacity: 12),
    ]);
    await type(tester, 'capacity-1', '');
    await tester.tap(find.byKey(const ValueKey('save-schedules')));
    await tester.pumpAndSettle();
    expect(o.groups.updates, [(id: 1, capacity: null)]);
  });
}
