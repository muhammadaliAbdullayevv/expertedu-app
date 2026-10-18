import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/groups/presentation/group_form_dialog.dart';
import 'package:expert_edu_center/features/subjects/data/subjects_repository.dart';
import 'package:expert_edu_center/features/subjects/presentation/subjects_list_screen.dart';
import 'package:expert_edu_center/features/teachers/data/teachers_repository.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

class FakeSubjects implements SubjectsRepository {
  FakeSubjects([List<Subject>? start]) : subjects = [...?start];

  final List<Subject> subjects;
  ApiException? error;
  final created = <String>[];

  @override
  Future<List<Subject>> list() async => [...subjects];

  @override
  Future<Subject> create(String name) async {
    if (error != null) throw error!;
    created.add(name);
    final s = Subject(id: 50 + created.length, name: name, groupCount: 0);
    subjects.add(s);
    return s;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoTeachers implements TeachersRepository {
  @override
  Future<List<Teacher>> list({bool includeInactive = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pump(
  WidgetTester tester,
  Widget home,
  FakeSubjects subjects,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subjectsRepositoryProvider.overrideWithValue(subjects),
        teachersRepositoryProvider.overrideWithValue(NoTeachers()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: home),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> addSubject(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const ValueKey('subject-name')), name);
  await tester.tap(find.byKey(const ValueKey('subject-save')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('Guruhlar: the subject list', () {
    testWidgets('with none yet it says so and offers to add one', (
      tester,
    ) async {
      final subjects = FakeSubjects();
      await pump(tester, const SubjectsListScreen(), subjects);
      expect(find.byKey(const ValueKey('no-subjects')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new-subject-empty')));
      await tester.pumpAndSettle();
      await addSubject(tester, 'Ingliz tili');
      expect(subjects.created, ['Ingliz tili']);
      expect(find.text('Ingliz tili'), findsOneWidget);
      expect(find.byKey(const ValueKey('no-subjects')), findsNothing);
    });

    testWidgets('the button is there when subjects exist too', (tester) async {
      final subjects = FakeSubjects(const [
        Subject(id: 1, name: 'Matematika', groupCount: 2),
      ]);
      await pump(tester, const SubjectsListScreen(), subjects);
      await tester.tap(find.byKey(const ValueKey('new-subject')));
      await tester.pumpAndSettle();
      await addSubject(tester, 'IELTS');
      expect(find.text('Matematika'), findsOneWidget);
      expect(find.text('IELTS'), findsOneWidget);
    });

    testWidgets('a name that exists is refused with the server\'s words', (
      tester,
    ) async {
      final subjects = FakeSubjects()
        ..error = ApiException(409, 'Bu fan allaqachon mavjud.');
      await pump(tester, const SubjectsListScreen(), subjects);
      await tester.tap(find.byKey(const ValueKey('new-subject-empty')));
      await tester.pumpAndSettle();
      await addSubject(tester, 'Ingliz tili');
      expect(find.text('Bu fan allaqachon mavjud.'), findsOneWidget);
    });

    testWidgets('an empty name is not sent', (tester) async {
      final subjects = FakeSubjects();
      await pump(tester, const SubjectsListScreen(), subjects);
      await tester.tap(find.byKey(const ValueKey('new-subject-empty')));
      await tester.pumpAndSettle();
      await addSubject(tester, '  ');
      expect(subjects.created, isEmpty);
      expect(find.text('Fan nomini kiriting.'), findsOneWidget);
    });
  });

  group('the new-group form', () {
    Widget opener() => Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-form'),
          onPressed: () => showGroupFormDialog(context),
          child: const Text('open'),
        ),
      ),
    );

    testWidgets(
      'with no subject it offers to make one right there and picks it',
      (tester) async {
        final subjects = FakeSubjects();
        await pump(tester, opener(), subjects);
        await tester.tap(find.byKey(const ValueKey('open-form')));
        await tester.pumpAndSettle();
        expect(find.text('Fan yo\'q: yangi fan qo\'shish'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('group-new-subject')));
        await tester.pumpAndSettle();
        await addSubject(tester, 'Ingliz tili');
        expect(subjects.created, ['Ingliz tili']);
        // The form is still open, with the new subject chosen.
        expect(find.text('Yangi guruh'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DropdownButtonFormField<int>),
            matching: find.text('Ingliz tili'),
          ),
          findsOneWidget,
        );
        expect(find.text('Yangi fan qo\'shish'), findsOneWidget);
      },
    );

    testWidgets('saving without a subject asks to add one first', (
      tester,
    ) async {
      await pump(tester, opener(), FakeSubjects());
      await tester.tap(find.byKey(const ValueKey('open-form')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saqlash'));
      await tester.pumpAndSettle();
      expect(find.text('Avval fan qo\'shing'), findsOneWidget);
    });
  });
}
