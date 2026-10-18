import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/auth/application/session_controller.dart';
import 'package:expert_edu_center/features/groups/presentation/group_form_dialog.dart';
import 'package:expert_edu_center/features/subjects/data/subjects_repository.dart';
import 'package:expert_edu_center/features/teachers/data/teachers_repository.dart';
import 'package:expert_edu_center/features/teachers/presentation/teacher_form_dialog.dart';
import 'package:expert_edu_center/features/teachers/presentation/teacher_merge_dialog.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';
import 'branches_test.dart' show FakeSession;
import 'subjects_test.dart' show FakeSubjects;

class FakeTeachers implements TeachersRepository {
  FakeTeachers({this.matches = const [], this.everyone = const []});

  List<TeacherMatch> matches;
  final List<Teacher> everyone;
  final lookups = <({String? phone, String? name})>[];
  final joined = <({int id, String? phone})>[];
  final merged = <({int id, int into})>[];
  final created = <String>[];
  ApiException? mergeError;

  @override
  Future<List<TeacherMatch>> lookup({String? phone, String? name}) async {
    lookups.add((phone: phone, name: name));
    return matches;
  }

  @override
  Future<Teacher> joinBranch(int id, {String? phone}) async {
    joined.add((id: id, phone: phone));
    return const Teacher(id: 1, fullName: 'X', isActive: true);
  }

  @override
  Future<Teacher> create({
    required String fullName,
    String? phone,
    String? note,
  }) async {
    created.add(fullName);
    return Teacher(id: 99, fullName: fullName, isActive: true);
  }

  @override
  Future<List<Teacher>> listEverywhere() async => everyone;

  @override
  Future<List<Teacher>> list({bool includeInactive = false}) async => everyone;

  @override
  Future<Teacher> merge(int id, {required int intoId}) async {
    if (mergeError != null) throw mergeError!;
    merged.add((id: id, into: intoId));
    return const Teacher(id: 1, fullName: 'X', isActive: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const hqTeacher = Teacher(
  id: 1,
  fullName: 'Dilmurod Imomqulov',
  phone: '998947894561',
  isActive: true,
  branchNames: ['Bosh ofis'],
);
const turonTeacher = Teacher(
  id: 2,
  fullName: 'Dilmurod Imomqulov',
  phone: '998941789456',
  isActive: true,
  branchNames: ['Turon'],
);

Future<void> pump(
  WidgetTester tester,
  FakeTeachers teachers, {
  bool owner = false,
  required Widget Function(BuildContext) opener,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        teachersRepositoryProvider.overrideWithValue(teachers),
        subjectsRepositoryProvider.overrideWithValue(
          FakeSubjects(const [
            Subject(id: 7, name: 'Ingliz tili', groupCount: 0),
            Subject(id: 8, name: 'IELTS', groupCount: 0),
          ]),
        ),
        sessionControllerProvider.overrideWithValue(FakeSession(owner: owner)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Builder(builder: opener)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget button(Future<Object?> Function(BuildContext) open) => Center(
  child: Builder(
    builder: (context) => FilledButton(
      key: const ValueKey('open'),
      onPressed: () => open(context),
      child: const Text('open'),
    ),
  ),
);

Future<void> typeName(WidgetTester tester, String name) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'F.I.Sh.'), name);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  Future<void> openForm(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  group('adding a teacher', () {
    Widget opener(BuildContext _) => button(showTeacherFormDialog);

    testWidgets(
      'a number that belongs to someone elsewhere offers to join them',
      (tester) async {
        final teachers = FakeTeachers(
          matches: const [
            TeacherMatch(
              teacherId: 1,
              fullName: 'Dilmurod Imomqulov',
              branchNames: ['Bosh ofis'],
              inScope: false,
              samePhone: true,
            ),
          ],
        );
        await pump(tester, teachers, opener: opener);
        await openForm(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Telefon (ixtiyoriy)'),
          '947894561',
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(teachers.lookups.last.phone, '+998947894561');
        expect(
          find.textContaining(
            'Bu raqam bilan "Dilmurod Imomqulov" Bosh ofis filialida ishlaydi',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('join-teacher-1')));
        await tester.pumpAndSettle();
        expect(teachers.joined.single, (id: 1, phone: '+998947894561'));
        expect(teachers.created, isEmpty);
      },
    );

    testWidgets('a teacher already in this branch cannot be added again', (
      tester,
    ) async {
      final teachers = FakeTeachers(
        matches: const [
          TeacherMatch(
            teacherId: 1,
            fullName: 'Dilmurod Imomqulov',
            branchNames: ['Bosh ofis'],
            inScope: true,
            samePhone: false,
          ),
        ],
      );
      await pump(tester, teachers, opener: opener);
      await openForm(tester);
      await typeName(tester, 'Dilmurod Imomqulov');
      expect(find.textContaining('bu filialda allaqachon bor'), findsOneWidget);
      expect(find.byKey(const ValueKey('join-teacher-1')), findsNothing);
      await tester.tap(find.text('Saqlash'));
      await tester.pumpAndSettle();
      expect(teachers.created, isEmpty);
    });

    testWidgets(
      'the same name elsewhere: an admin is told, the owner can join',
      (tester) async {
        const match = TeacherMatch(
          teacherId: 1,
          fullName: 'Dilmurod Imomqulov',
          branchNames: ['Bosh ofis'],
          inScope: false,
          samePhone: false,
        );
        final admin = FakeTeachers(matches: const [match]);
        await pump(tester, admin, opener: opener);
        await openForm(tester);
        await typeName(tester, 'Dilmurod Imomqulov');
        expect(find.textContaining('egasiga ayting'), findsOneWidget);
        expect(find.byKey(const ValueKey('join-teacher-1')), findsNothing);
        // Still saveable: it may be a different person.
        await tester.tap(find.text('Saqlash'));
        await tester.pumpAndSettle();
        expect(admin.created, ['Dilmurod Imomqulov']);
      },
    );

    testWidgets('the owner joins by name, without a number', (tester) async {
      final owner = FakeTeachers(
        matches: const [
          TeacherMatch(
            teacherId: 1,
            fullName: 'Dilmurod Imomqulov',
            branchNames: ['Bosh ofis'],
            inScope: false,
            samePhone: false,
          ),
        ],
      );
      await pump(tester, owner, owner: true, opener: opener);
      await openForm(tester);
      await typeName(tester, 'Dilmurod');
      await tester.tap(find.byKey(const ValueKey('join-teacher-1')));
      await tester.pumpAndSettle();
      expect(owner.joined.single, (id: 1, phone: null));
    });

    testWidgets('nobody like them: nothing is shown and it saves', (
      tester,
    ) async {
      final teachers = FakeTeachers();
      await pump(tester, teachers, opener: opener);
      await openForm(tester);
      await typeName(tester, 'Yangi Odam');
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains('teacher-match'),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Saqlash'));
      await tester.pumpAndSettle();
      expect(teachers.created, ['Yangi Odam']);
    });
  });

  group('merging a duplicate (owner)', () {
    Widget opener(BuildContext _) =>
        button((c) => showTeacherMergeDialog(c, teacher: turonTeacher));

    testWidgets('pick the real one, read what happens, merge', (tester) async {
      final teachers = FakeTeachers(everyone: const [hqTeacher, turonTeacher]);
      await pump(tester, teachers, owner: true, opener: opener);
      await openForm(tester);
      expect(find.byKey(const ValueKey('merge-warning')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('merge-into')));
      await tester.pumpAndSettle();
      // The teacher itself is not offered; the other one shows number and branch.
      expect(
        find.textContaining('+998 94 789 45 61 · Bosh ofis'),
        findsWidgets,
      );
      expect(find.textContaining('94 178 94 56'), findsNothing);
      await tester.tap(find.textContaining('Bosh ofis').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('merge-warning')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('merge-save')));
      await tester.pumpAndSettle();
      expect(teachers.merged.single, (id: 2, into: 1));
    });

    testWidgets('the server\'s reason is shown when it refuses', (
      tester,
    ) async {
      final teachers = FakeTeachers(everyone: const [hqTeacher, turonTeacher])
        ..mergeError = ApiException(409, 'Dars vaqtlari to\'qnashadi.');
      await pump(tester, teachers, owner: true, opener: opener);
      await openForm(tester);
      await tester.tap(find.byKey(const ValueKey('merge-into')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Bosh ofis').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('merge-save')));
      await tester.pumpAndSettle();
      expect(find.text('Dars vaqtlari to\'qnashadi.'), findsOneWidget);
      expect(teachers.merged, isEmpty);
    });

    testWidgets('nothing is merged until one is picked', (tester) async {
      await pump(
        tester,
        FakeTeachers(everyone: const [hqTeacher, turonTeacher]),
        owner: true,
        opener: opener,
      );
      await openForm(tester);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('merge-save')),
      );
      expect(save.onPressed, isNull);
    });
  });

  group('the group form opened from a course', () {
    testWidgets('has the course already chosen', (tester) async {
      await pump(
        tester,
        FakeTeachers(everyone: const [hqTeacher]),
        opener: (_) => button((c) => showGroupFormDialog(c, subjectId: 8)),
      );
      await openForm(tester);
      expect(
        find.descendant(
          of: find.byType(DropdownButtonFormField<int>).first,
          matching: find.text('IELTS'),
        ),
        findsOneWidget,
      );
    });
  });
}
