import 'dart:typed_data';

import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/auth/application/session_controller.dart';
import 'package:expert_edu_center/features/photos/photo_picker.dart';
import 'package:expert_edu_center/features/photos/photos_repository.dart';
import 'package:expert_edu_center/features/teachers/data/teachers_repository.dart';
import 'package:expert_edu_center/features/teachers/presentation/teachers_screen.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

String plain(String v) => v.replaceAll(RegExp(r'[\u00a0\u202f]'), ' ');

Finder text(String value) => find.byWidgetPredicate(
  (w) => w is Text && plain(w.data ?? '') == value,
  description: 'text "$value"',
);

ScheduleSlot slot(int weekday, int h) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: 0),
  endsAt: TimeOfDay(hour: h + 1, minute: 30),
);

Teacher teacher(
  int id,
  String name, {
  bool active = true,
  int groups = 0,
  int students = 0,
  String? photo,
}) => Teacher(
  id: id,
  fullName: name,
  phone: '99890111000$id',
  isActive: active,
  groupCount: groups,
  studentCount: students,
  photo: photo,
);

TeacherProfileData profileOf(
  Teacher t, {
  DateTime? month,
  List<TeacherGroupCard> groups = const [],
  int collected = 0,
  int earned = 0,
  int paid = 0,
  String? method = 'percent',
  double? percent = 40,
  bool salaryVisible = true,
  List<TimetableLesson> lessons = const [],
}) {
  final m = month ?? DateTime(DateTime.now().year, DateTime.now().month);
  return TeacherProfileData(
    teacher: t,
    salaryVisible: salaryVisible,
    salaryMethod: method,
    salaryPercent: percent,
    groups: groups,
    studentTotal: groups.fold(0, (a, g) => a + g.studentCount),
    month: m,
    collected: collected,
    earned: earned,
    paid: paid,
    remaining: earned - paid,
    lessons: lessons,
    history: [
      for (var i = 5; i >= 0; i--)
        TeacherMonthPoint(
          month: DateTime(m.year, m.month - i),
          collected: 1000000 * (6 - i),
          earned: 400000 * (6 - i),
          paid: i == 0 ? 0 : 400000 * (6 - i),
          closed: i != 0,
        ),
    ],
  );
}

const beginner = TeacherGroupCard(
  groupId: 1,
  name: 'Beginner A',
  subjectName: 'Ingliz tili',
  level: 'A1',
  studentCount: 12,
  capacity: 15,
  schedule: [
    ScheduleSlot(
      weekday: 1,
      startsAt: TimeOfDay(hour: 9, minute: 0),
      endsAt: TimeOfDay(hour: 10, minute: 30),
    ),
    ScheduleSlot(
      weekday: 3,
      startsAt: TimeOfDay(hour: 9, minute: 0),
      endsAt: TimeOfDay(hour: 10, minute: 30),
    ),
    ScheduleSlot(
      weekday: 5,
      startsAt: TimeOfDay(hour: 9, minute: 0),
      endsAt: TimeOfDay(hour: 10, minute: 30),
    ),
  ],
);
const french = TeacherGroupCard(
  groupId: 2,
  name: 'Fransuz tili A1',
  subjectName: 'Fransuz tili',
  studentCount: 5,
  schedule: [
    ScheduleSlot(
      weekday: 2,
      startsAt: TimeOfDay(hour: 15, minute: 0),
      endsAt: TimeOfDay(hour: 16, minute: 30),
    ),
  ],
);

class FakeTeachers implements TeachersRepository {
  FakeTeachers(this.all, this.profiles);

  List<Teacher> all;
  final Map<int, TeacherProfileData> profiles;
  final profileCalls = <({int id, DateTime? month})>[];
  final activeCalls = <({int id, bool active})>[];

  @override
  Future<List<Teacher>> list({bool includeInactive = false}) async => [
    for (final t in all)
      if (includeInactive || t.isActive) t,
  ];

  @override
  Future<TeacherProfileData> profile(int id, {DateTime? month}) async {
    profileCalls.add((id: id, month: month));
    final base = profiles[id]!;
    return month == null
        ? base
        : profileOf(base.teacher, month: month, groups: base.groups);
  }

  @override
  Future<void> setActive(int id, bool active) async {
    activeCalls.add((id: id, active: active));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePhotos implements PhotosRepository {
  final sets = <({PhotoOwner owner, int id, int bytes})>[];
  final removes = <({PhotoOwner owner, int id})>[];

  @override
  Future<String> set(PhotoOwner owner, int id, Uint8List png) async {
    sets.add((owner: owner, id: id, bytes: png.length));
    return 'teacher-$id-new.png';
  }

  @override
  Future<void> remove(PhotoOwner owner, int id) async {
    removes.add((owner: owner, id: id));
  }

  @override
  Future<Uint8List> bytes(String name) => throw StateError('no picture');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSession extends ChangeNotifier implements SessionController {
  FakeSession({required this.owner});
  final bool owner;

  @override
  bool get isOwner => owner;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Rig {
  Rig({this.owner = true}) {
    final madina = teacher(1, 'Madina Karimova', groups: 2, students: 17);
    final jasur = teacher(2, 'Jasur Rahimov', groups: 1, students: 8);
    final free = teacher(3, 'Bo\'sh Ustoz');
    final gone = teacher(4, 'Ketgan Ustoz', active: false);
    teachers = FakeTeachers(
      [madina, jasur, free, gone],
      {
        1: profileOf(
          madina,
          groups: [beginner, french],
          collected: 3800000,
          earned: 1600000,
          paid: 500000,
          lessons: [
            TimetableLesson(
              groupId: 1,
              groupName: 'Beginner A',
              room: '2-xona',
              startsAt: DateTime.now().add(const Duration(hours: 1)),
              endsAt: DateTime.now().add(const Duration(hours: 2)),
              status: 'scheduled',
              isExtra: false,
              studentCount: 12,
              markedCount: 0,
              presentCount: 0,
            ),
          ],
        ),
        2: profileOf(jasur, groups: [french]),
        3: profileOf(free),
        4: profileOf(gone),
      },
    );
  }

  final bool owner;
  late final FakeTeachers teachers;
  final photos = FakePhotos();
  Future<Uint8List?> Function() picker = () async =>
      Uint8List.fromList([1, 2, 3]);
}

late ProviderContainer container;

Future<void> pump(WidgetTester tester, Rig rig) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        teachersRepositoryProvider.overrideWithValue(rig.teachers),
        photosRepositoryProvider.overrideWithValue(rig.photos),
        photoPickerProvider.overrideWithValue(() => rig.picker()),
        sessionControllerProvider.overrideWithValue(
          FakeSession(owner: rig.owner),
        ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: TeachersScreen()),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('the table', () {
    testWidgets('lists teachers with groups and students -- and no money', (
      tester,
    ) async {
      await pump(tester, Rig());
      final row = find.byKey(const ValueKey('teacher-1'));
      expect(
        find.descendant(of: row, matching: find.text('Madina Karimova')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('17')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('2')),
        findsOneWidget,
      );
      // The table never shows what a teacher collects or earns.
      expect(find.text('Oylik'), findsNothing);
      expect(find.text('Bu oy yig\'ilgan'), findsNothing);
      expect(
        find.descendant(of: row, matching: find.textContaining('so\'m')),
        findsNothing,
      );
    });
    testWidgets('tabs: Faol, Guruhsiz and Arxiv with their counts', (
      tester,
    ) async {
      await pump(tester, Rig());
      expect(find.text('3'), findsWidgets);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('count-active'))).data,
        '3',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('count-free'))).data,
        '1',
      );
      // Archived people only show on their tab.
      expect(find.byKey(const ValueKey('teacher-4')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tab-archive')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('teacher-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tab-free')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('teacher-1')), findsNothing);
    });

    testWidgets('search finds by name or phone', (tester) async {
      await pump(tester, Rig());
      await tester.enterText(
        find.byKey(const ValueKey('teachers-search')),
        'jasur',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('teacher-1')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('teachers-search')),
        '9989011100',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-1')), findsOneWidget);
    });
  });

  group('the teacher page', () {
    testWidgets('the first teacher is open; clicking another opens theirs', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('teacher-panel-name')))
            .data,
        'Madina Karimova',
      );
      await tester.tap(find.byKey(const ValueKey('teacher-2')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('teacher-panel-name')))
            .data,
        'Jasur Rahimov',
      );
      expect(rig.teachers.profileCalls.map((c) => c.id), containsAll([1, 2]));
    });

    testWidgets('each group: name, days, time, number of students', (
      tester,
    ) async {
      await pump(tester, Rig());
      expect(find.text('Beginner A'), findsWidgets);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('teacher-group-info-1')))
            .data,
        'Du, Cho, Ju 09:00 · 12 / 15 o\'quvchi',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('teacher-group-info-2')))
            .data,
        'Se 15:00 · 5 o\'quvchi',
      );
    });

    testWidgets(
      'the salary is one figure: the share of what ALL groups collected',
      (tester) async {
        await pump(tester, Rig());
        expect(
          plain(
            tester
                .widget<Text>(find.byKey(const ValueKey('teacher-earned')))
                .data!,
          ),
          '1 600 000 so\'m',
        );
        expect(
          plain(
            tester
                .widget<Text>(find.byKey(const ValueKey('teacher-collected')))
                .data!,
          ),
          'Yig\'ilgan 3 800 000 so\'m dan 40%',
        );
        expect(text('500 000 so\'m'), findsOneWidget);
        expect(text('1 100 000 so\'m'), findsOneWidget);
        // With two groups the card says it is the total of both.
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('teacher-month'))).data,
          contains('2 ta guruh jami'),
        );
      },
    );

    testWidgets(
      'a group shows only its name, students and days -- no group stats',
      (tester) async {
        await pump(tester, Rig());
        final card = find.byKey(const ValueKey('teacher-group-1'));
        expect(
          find.descendant(of: card, matching: find.text('Beginner A')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.textContaining('o\'quvchi')),
          findsOneWidget,
        );
        expect(find.textContaining('ulush'), findsNothing);
        expect(find.textContaining('Yig\'ilgan 3 000 000'), findsNothing);
        expect(find.text('90%'), findsNothing);
        expect(find.textContaining('avomat'), findsNothing);
        expect(
          find.descendant(
            of: card,
            matching: find.byIcon(Icons.chevron_right_rounded),
          ),
          findsNothing,
        );
      },
    );
    testWidgets('a teacher with no pay rule is told so and earns nothing', (
      tester,
    ) async {
      final rig = Rig();
      rig.teachers.profiles[1] = profileOf(
        rig.teachers.all.first,
        method: null,
        percent: null,
        groups: [beginner],
      );
      await pump(tester, rig);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('teacher-collected')))
            .data,
        contains('belgilanmagan'),
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('teacher-rule'))).data,
        'Kelishuv: Belgilanmagan',
      );
    });

    testWidgets('the owner can change the percent', (tester) async {
      await pump(tester, Rig(owner: true));
      expect(find.byKey(const ValueKey('teacher-rule-edit')), findsOneWidget);
    });

    testWidgets('an admin sees no pay at all: no card, no rule, no history', (
      tester,
    ) async {
      final rig = Rig(owner: false);
      // What the server sends an admin: groups yes, pay figures none.
      rig.teachers.profiles[1] = profileOf(
        rig.teachers.all.first,
        groups: [beginner, french],
        salaryVisible: false,
        method: null,
        percent: null,
      );
      await pump(tester, rig);
      expect(find.byKey(const ValueKey('teacher-salary')), findsNothing);
      expect(find.byKey(const ValueKey('teacher-earned')), findsNothing);
      expect(find.byKey(const ValueKey('teacher-rule')), findsNothing);
      expect(find.byKey(const ValueKey('teacher-rule-edit')), findsNothing);
      expect(find.byKey(const ValueKey('teacher-history')), findsNothing);
      expect(find.text('So\'nggi 6 oy'), findsNothing);
      // The groups and today's lessons are still there.
      expect(find.byKey(const ValueKey('teacher-group-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('teacher-lessons')), findsOneWidget);
    });

    testWidgets('the month can be moved back; this month has no way forward', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      final next = tester.widget<IconButton>(
        find.byKey(const ValueKey('teacher-month-next')),
      );
      expect(next.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('teacher-month-prev')));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final last = DateTime(now.year, now.month - 1);
      expect(rig.teachers.profileCalls.last.month, last);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('teacher-month-next')),
            )
            .onPressed,
        isNotNull,
      );
      // Forward again lands on this month (no month asked for).
      await tester.tap(find.byKey(const ValueKey('teacher-month-next')));
      await tester.pumpAndSettle();
      expect(rig.teachers.profileCalls.last.month, isNull);
    });

    testWidgets('tapping a group does not leave this page', (tester) async {
      await pump(tester, Rig());
      await tester.tap(find.byKey(const ValueKey('teacher-group-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-panel-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('teachers-list')), findsOneWidget);
    });
    testWidgets('today\'s lessons and six months of pay', (tester) async {
      await pump(tester, Rig());
      expect(find.byKey(const ValueKey('teacher-lessons')), findsOneWidget);
      expect(find.textContaining('Beginner A · 2-xona'), findsOneWidget);
      expect(find.byKey(const ValueKey('teacher-week')), findsNothing);
      expect(find.byKey(const ValueKey('teacher-attendance')), findsNothing);
      final history = find.byKey(const ValueKey('teacher-history'));
      expect(
        find.descendant(
          of: history,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNWidgets(6),
      );
    });
    testWidgets('a teacher with no groups says so', (tester) async {
      await pump(tester, Rig());
      await tester.tap(find.byKey(const ValueKey('teacher-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('teacher-no-groups')), findsOneWidget);
      expect(find.text('Bugun va ertaga dars yo\'q.'), findsOneWidget);
    });
  });

  group('the three dots', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('teacher-menu')));
      await tester.pumpAndSettle();
    }

    testWidgets('upload a photo: the picked picture is sent for this teacher', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      await openMenu(tester);
      // No photo yet: nothing to remove.
      expect(find.byKey(const ValueKey('menu-photo-remove')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('menu-photo')));
      await tester.pumpAndSettle();
      expect(rig.photos.sets, [(owner: PhotoOwner.teacher, id: 1, bytes: 3)]);
    });

    testWidgets('cancelling the file chooser changes nothing', (tester) async {
      final rig = Rig()..picker = () async => null;
      await pump(tester, rig);
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('menu-photo')));
      await tester.pumpAndSettle();
      expect(rig.photos.sets, isEmpty);
    });

    testWidgets('a teacher with a photo can have it removed', (tester) async {
      final rig = Rig();
      rig.teachers.profiles[1] = profileOf(
        teacher(1, 'Madina Karimova', photo: 'teacher-1-abc.png'),
        groups: [beginner],
      );
      await pump(tester, rig);
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('menu-photo-remove')));
      await tester.pumpAndSettle();
      expect(rig.photos.removes, [(owner: PhotoOwner.teacher, id: 1)]);
    });

    testWidgets('archiving asks first when the teacher still has groups', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('menu-archive')));
      await tester.pumpAndSettle();
      expect(find.text('Arxivga o\'tkazilsinmi?'), findsOneWidget);
      await tester.tap(find.text('Bekor qilish'));
      await tester.pumpAndSettle();
      expect(rig.teachers.activeCalls, isEmpty);

      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('menu-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arxivga o\'tkazish').last);
      await tester.pumpAndSettle();
      expect(rig.teachers.activeCalls, [(id: 1, active: false)]);
    });

    testWidgets('a teacher with no groups is archived at once', (tester) async {
      final rig = Rig();
      await pump(tester, rig);
      await tester.tap(find.byKey(const ValueKey('teacher-3')));
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('menu-archive')));
      await tester.pumpAndSettle();
      expect(rig.teachers.activeCalls, [(id: 3, active: false)]);
    });
  });
}
