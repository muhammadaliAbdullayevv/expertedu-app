import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/auth/application/session_controller.dart';
import 'package:expert_edu_center/features/auth/data/auth_repository.dart';
import 'package:expert_edu_center/features/branches/application/branch_view.dart';
import 'package:expert_edu_center/features/branches/data/branches_repository.dart';
import 'package:expert_edu_center/features/branches/presentation/branch_switcher.dart';
import 'package:expert_edu_center/features/branches/presentation/branches_tab.dart';
import 'package:expert_edu_center/features/branches/presentation/choose_branch.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/students/data/student_models.dart';
import 'package:expert_edu_center/features/students/data/students_repository.dart';
import 'package:expert_edu_center/features/students/presentation/add_student_dialog.dart';
import 'package:expert_edu_center/features/students/presentation/student_panel.dart';
import 'package:expert_edu_center/features/students/presentation/students_list_screen.dart';
import 'package:expert_edu_center/features/billing/data/transactions_repository.dart';
import 'package:expert_edu_center/features/photos/photos_repository.dart';
import 'package:expert_edu_center/features/teachers/data/teachers_repository.dart';
import 'package:expert_edu_center/features/teachers/presentation/teacher_branches_dialog.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/load_fonts.dart';
import 'students_page_test.dart' hide main, plain;
import 'teachers_page_test.dart' as teachers show FakeTeachers, teacher;

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => 'token';
}

class FakeBranches implements BranchesRepository {
  FakeBranches(this.branches);

  List<Branch> branches;
  final created = <String>[];
  final updates = <({int id, String? name, bool? active})>[];
  ApiException? error;

  @override
  Future<List<Branch>> list() async => branches;

  @override
  Future<Branch> create(String name) async {
    if (error != null) throw error!;
    created.add(name);
    final b = Branch(id: 100 + created.length, name: name);
    branches = [...branches, b];
    return b;
  }

  @override
  Future<Branch> update(int id, {String? name, bool? isActive}) async {
    if (error != null) throw error!;
    updates.add((id: id, name: name, active: isActive));
    return branches.firstWhere((b) => b.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSession extends ChangeNotifier implements SessionController {
  FakeSession({required this.owner, this.branchName});

  final bool owner;
  final String? branchName;

  @override
  bool get isOwner => owner;

  @override
  AuthUser? get user => AuthUser(
    id: '1',
    phone: '998900000001',
    fullName: 'Foydalanuvchi',
    role: owner ? 'owner' : 'admin',
    branchId: owner ? null : 2,
    branchName: branchName,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const hq = Branch(id: 1, name: 'Bosh ofis', isHeadquarters: true);
const chilonzor = Branch(id: 2, name: 'Chilonzor');
const yunusobod = Branch(id: 3, name: 'Yunusobod');

ProviderContainer? _container;

Future<FakeBranches> pumpWidget(
  WidgetTester tester,
  Widget child, {
  List<Branch> branches = const [hq, chilonzor, yunusobod],
  bool owner = true,
  String? branchName,
  List<Override> extra = const [],
}) async {
  final fake = FakeBranches(branches);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        branchesRepositoryProvider.overrideWithValue(fake),
        sessionControllerProvider.overrideWithValue(
          FakeSession(owner: owner, branchName: branchName),
        ),
        apiClientProvider.overrideWithValue(ApiClient(_NoTokens())),
        ...extra,
      ],
      child: Consumer(
        builder: (context, ref, _) {
          _container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: Center(child: child)),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  setUpAll(loadAppFonts);

  group('the branch in view travels with every request', () {
    test(
      'X-Branch is sent for the owner\'s choice and left out for all',
      () async {
        final seen = <Map<String, String>>[];
        final api = ApiClient(
          _NoTokens(),
          MockClient((request) async {
            seen.add(request.headers);
            return http.Response('[]', 200);
          }),
        );
        await api.get('/groups');
        api.branchId = 2;
        await api.get('/groups');
        // A single call can look past it ("all") or at another branch.
        await api.get('/groups/search', headers: {'X-Branch': 'all'});
        await api.get('/groups/search', headers: {'X-Branch': '3'});
        expect(seen[0].containsKey('X-Branch'), isFalse);
        expect(seen[1]['X-Branch'], '2');
        expect(seen[2]['X-Branch'], 'all');
        expect(seen[3]['X-Branch'], '3');
        // A new session starts looking at everything.
        api.resetAuthBlock();
        expect(api.branchId, isNull);
      },
    );

    test('the notifier mirrors the api and tells listeners', () {
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(_NoTokens())),
        ],
      );
      addTearDown(container.dispose);
      final seen = <int?>[];
      container.listen<int?>(branchViewProvider, (_, v) => seen.add(v));
      expect(container.read(branchViewProvider), isNull);
      container.read(branchViewProvider.notifier).select(2);
      expect(container.read(apiClientProvider).branchId, 2);
      container.read(branchViewProvider.notifier).select(2); // no change
      container.read(branchViewProvider.notifier).reset();
      expect(seen, [2, null]);
      expect(container.read(apiClientProvider).branchId, isNull);
    });

    test(
      'labels appear only when every branch is in view and there are several',
      () async {
        Future<bool> labels({required int count, int? viewing}) async {
          final container = ProviderContainer(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(_NoTokens())),
              branchesRepositoryProvider.overrideWithValue(
                FakeBranches([
                  for (var i = 1; i <= count; i++) Branch(id: i, name: 'F$i'),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.read(branchViewProvider.notifier).select(viewing);
          await container.read(branchListProvider.future);
          return container.read(showBranchLabelsProvider);
        }

        expect(await labels(count: 3), isTrue);
        expect(await labels(count: 3, viewing: 2), isFalse);
        // An admin's list has just their own branch.
        expect(await labels(count: 1), isFalse);
      },
    );
  });

  group('the sidebar switcher', () {
    testWidgets('the owner picks Hammasi or one branch', (tester) async {
      await pumpWidget(tester, const BranchSwitcher());
      expect(find.text('Hammasi'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('branch-switcher')));
      await tester.pumpAndSettle();
      for (final id in [1, 2, 3]) {
        expect(find.byKey(ValueKey('branch-option-$id')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('branch-option-2')));
      await tester.pumpAndSettle();
      expect(_container!.read(branchViewProvider), 2);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher')),
          matching: find.text('Chilonzor'),
        ),
        findsOneWidget,
      );
      // And back to everything.
      await tester.tap(find.byKey(const ValueKey('branch-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('branch-option-all')));
      await tester.pumpAndSettle();
      expect(_container!.read(branchViewProvider), isNull);
    });

    testWidgets('an admin only sees the name of their branch', (tester) async {
      await pumpWidget(
        tester,
        const BranchSwitcher(),
        owner: false,
        branches: const [chilonzor],
        branchName: 'Chilonzor',
      );
      expect(find.byKey(const ValueKey('branch-label')), findsOneWidget);
      expect(find.text('Chilonzor'), findsOneWidget);
      expect(find.byKey(const ValueKey('branch-switcher')), findsNothing);
    });

    testWidgets('with a single branch there is nothing to switch', (
      tester,
    ) async {
      await pumpWidget(tester, const BranchSwitcher(), branches: const [hq]);
      expect(find.byKey(const ValueKey('branch-switcher')), findsNothing);
    });
  });

  group('creating something while looking at every branch', () {
    Future<bool?> run(
      WidgetTester tester, {
      int? viewing,
      List<Branch> branches = const [hq, chilonzor, yunusobod],
      int? pick,
      bool cancel = false,
    }) async {
      bool? result;
      await pumpWidget(
        tester,
        Consumer(
          builder: (context, ref, _) => FilledButton(
            key: const ValueKey('go'),
            onPressed: () async =>
                result = await ensureBranchChosen(context, ref),
            child: const Text('go'),
          ),
        ),
        branches: branches,
      );
      _container!.read(branchViewProvider.notifier).select(viewing);
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      if (find.byKey(const ValueKey('choose-branch')).evaluate().isNotEmpty) {
        if (cancel) {
          await tester.tapAt(const Offset(2, 2));
        } else {
          await tester.tap(find.byKey(ValueKey('choose-branch-$pick')));
        }
        await tester.pumpAndSettle();
      }
      return result;
    }

    testWidgets('asks which branch, then looks at it', (tester) async {
      expect(await run(tester, pick: 3), isTrue);
      expect(_container!.read(branchViewProvider), 3);
    });

    testWidgets('cancelling changes nothing and does not go on', (
      tester,
    ) async {
      expect(await run(tester, cancel: true), isFalse);
      expect(_container!.read(branchViewProvider), isNull);
    });

    testWidgets('a branch already in view, or only one branch: no question', (
      tester,
    ) async {
      expect(await run(tester, viewing: 2), isTrue);
      expect(find.byKey(const ValueKey('choose-branch')), findsNothing);
    });

    testWidgets('only one branch exists: no question either', (tester) async {
      expect(await run(tester, branches: const [hq]), isTrue);
      expect(find.byKey(const ValueKey('choose-branch')), findsNothing);
    });
  });

  group('Filial labels', () {
    testWidgets(
      'the students table says which branch, only with every branch in view',
      (tester) async {
        Future<void> pumpStudents(bool labels) async {
          final rig = Rig(
            rows: [
              row(
                1,
                'Botir Aliyev',
              ).copyWithBranches(['Bosh ofis', 'Chilonzor']),
              row(2, 'Dilnoza Ergasheva'),
            ],
          );
          tester.view.physicalSize = const Size(1500, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                studentsRepositoryProvider.overrideWithValue(rig.students),
                transactionsRepositoryProvider.overrideWithValue(
                  rig.transactions,
                ),
                enrollmentsRepositoryProvider.overrideWithValue(
                  rig.enrollments,
                ),
                qabulRepositoryProvider.overrideWithValue(rig.qabul),
                photosRepositoryProvider.overrideWithValue(rig.photos),
                showBranchLabelsProvider.overrideWithValue(labels),
              ],
              child: MaterialApp(
                theme: AppTheme.light(),
                home: const Scaffold(body: StudentsListScreen()),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpStudents(true);
        expect(find.textContaining('Bosh ofis, Chilonzor'), findsOneWidget);
        await pumpStudents(false);
        expect(find.textContaining('Bosh ofis, Chilonzor'), findsNothing);
      },
    );
  });

  group('the same person in another branch', () {
    testWidgets('a number from another branch can be joined, not duplicated', (
      tester,
    ) async {
      final rig = Rig();
      var joined = false;
      final students = _JoinStudents(
        rig.students,
        () => joined,
        () => joined = true,
      );
      tester.view.physicalSize = const Size(1500, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            studentsRepositoryProvider.overrideWithValue(students),
            groupsRepositoryProvider.overrideWithValue(_NoGroups()),
            enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAddStudentDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextFormField),
            )
            .at(1),
        '901234567',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // It names the other branch -- and nothing else about the student.
      expect(
        find.byKey(const ValueKey('other-branch-warning')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'allaqachon Bosh ofis filialida mavjud: Botir Aliyev',
        ),
        findsOneWidget,
      );
      expect(find.text('Boshqa guruhga qo\'shish'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('join-branch')));
      await tester.pumpAndSettle();
      expect(students.joins, [(id: 7, phone: '998901234567')]);
      // Now it is the usual warning: he is in this branch too.
      expect(find.byKey(const ValueKey('other-branch-warning')), findsNothing);
      expect(
        find.textContaining('Bu raqam allaqachon mavjud: Botir Aliyev'),
        findsOneWidget,
      );
    });
  });

  group('Filiallar tab (owner)', () {
    testWidgets('lists the branches, adds one and renames one', (tester) async {
      final fake = await pumpWidget(
        tester,
        const SizedBox(width: 900, height: 600, child: BranchesTab()),
        branches: const [hq, chilonzor],
      );
      expect(find.text('Bosh ofis'), findsWidgets);
      expect(find.text('Chilonzor'), findsOneWidget);
      // The headquarters cannot be switched off.
      expect(find.byKey(const ValueKey('toggle-branch-1')), findsNothing);
      expect(find.byKey(const ValueKey('toggle-branch-2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('new-branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('branch-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('branch-error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('branch-name')),
        'Yunusobod',
      );
      await tester.tap(find.byKey(const ValueKey('branch-save')));
      await tester.pumpAndSettle();
      expect(fake.created, ['Yunusobod']);
      expect(find.text('Yunusobod'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-branch-2')));
      await tester.pumpAndSettle();
      expect(fake.updates, [(id: 2, name: null, active: false)]);
    });

    testWidgets('a name that is taken is refused with the server\'s words', (
      tester,
    ) async {
      final fake = await pumpWidget(
        tester,
        const SizedBox(width: 900, height: 600, child: BranchesTab()),
        branches: const [hq],
      );
      fake.error = ApiException(409, 'Bu nomli filial allaqachon bor.');
      await tester.tap(find.byKey(const ValueKey('new-branch')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('branch-name')),
        'Bosh ofis',
      );
      await tester.tap(find.byKey(const ValueKey('branch-save')));
      await tester.pumpAndSettle();
      expect(find.text('Bu nomli filial allaqachon bor.'), findsOneWidget);
    });
  });

  group('a teacher in several branches', () {
    testWidgets('the owner picks the branches; at least one', (tester) async {
      final repo = teachers.FakeTeachers([
        teachers.teacher(1, 'Madina Karimova'),
      ], {});
      var saved = <int>[];
      final spy = _BranchSpyTeachers(repo, (ids) => saved = ids);
      await pumpWidget(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTeacherBranchesDialog(
              context,
              teacher: const Teacher(
                id: 1,
                fullName: 'Madina Karimova',
                isActive: true,
                branchIds: [1],
                branchNames: ['Bosh ofis'],
              ),
            ),
            child: const Text('open'),
          ),
        ),
        extra: [teachersRepositoryProvider.overrideWithValue(spy)],
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('teacher-branch-1')),
            )
            .value,
        isTrue,
      );
      // Un-ticking the last one is refused.
      await tester.tap(find.byKey(const ValueKey('teacher-branch-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('teacher-branches-save')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('teacher-branches-error')),
        findsOneWidget,
      );
      expect(saved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('teacher-branch-2')));
      await tester.tap(find.byKey(const ValueKey('teacher-branch-3')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('teacher-branches-save')));
      await tester.pumpAndSettle();
      expect(saved, [2, 3]);
    });
  });

  group(
    'moving to another branch is the owner\'s: the new group is searched by Filial',
    () {
      testWidgets('the owner can narrow the groups to one branch or see all', (
        tester,
      ) async {
        final asked = <int?>[];
        final rig = Rig(
          rows: [
            row(2, 'Dilnoza Ergasheva', groups: [english]),
          ],
          profiles: {
            2: profile(
              2,
              'Dilnoza Ergasheva',
              balance: 0,
              groups: [pgroup(21, 1, 'Fransuz tili, A1')],
            ),
          },
        );
        tester.view.physicalSize = const Size(900, 1300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              studentsRepositoryProvider.overrideWithValue(rig.students),
              transactionsRepositoryProvider.overrideWithValue(
                rig.transactions,
              ),
              enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
              qabulRepositoryProvider.overrideWithValue(_BranchQabul(asked)),
              photosRepositoryProvider.overrideWithValue(rig.photos),
              branchesRepositoryProvider.overrideWithValue(
                FakeBranches(const [hq, chilonzor]),
              ),
              apiClientProvider.overrideWithValue(ApiClient(_NoTokens())),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 440,
                    height: 1200,
                    child: StudentPanel(studentId: 2, onChanged: () {}),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('panel-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('menu-transfer')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('transfer-search')),
          'beginner',
        );
        await tester.pumpAndSettle();
        // Starts with every branch (nothing is in view): both groups, each labelled.
        expect(
          find.byKey(const ValueKey('transfer-branch-all')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('transfer-to-7')), findsOneWidget);
        expect(find.byKey(const ValueKey('transfer-to-8')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-branch-7')), findsOneWidget);
        // Chilonzor: only its groups are asked for and shown.
        await tester.tap(find.byKey(const ValueKey('transfer-branch-2')));
        await tester.pumpAndSettle();
        expect(asked.last, 2);
        expect(find.byKey(const ValueKey('transfer-to-8')), findsOneWidget);
        expect(find.byKey(const ValueKey('transfer-to-7')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('transfer-branch-all')));
        await tester.pumpAndSettle();
        expect(asked.last, 0);
        expect(find.byKey(const ValueKey('transfer-to-7')), findsOneWidget);
      });
    },
  );
}

extension on StudentRow {
  StudentRow copyWithBranches(List<String> names) => StudentRow(
    id: id,
    fullName: fullName,
    phone: phone,
    balance: balance,
    createdAt: createdAt,
    groups: groups,
    attendanceRecent: attendanceRecent,
    attendanceRate: attendanceRate,
    isNew: isNew,
    isDebtor: isDebtor,
    isAtRisk: isAtRisk,
    isActive: isActive,
    isArchived: isArchived,
    branches: names,
  );
}

/// Students: a number of another branch, then (after joining) the same person here.
class _JoinStudents extends FakeStudents {
  _JoinStudents(FakeStudents base, this.joinedNow, this.markJoined)
    : super(base.rowList, base.profiles);

  final bool Function() joinedNow;
  final void Function() markJoined;
  final joins = <({int id, String phone})>[];

  @override
  Future<PhoneOwner?> checkPhone(String phone) async => PhoneOwner(
    studentId: 7,
    fullName: 'Botir Aliyev',
    phone: '998901234567',
    groupNames: joinedNow() ? const ['Fransuz tili, A1'] : const [],
    branchNames: const ['Bosh ofis'],
    inScope: joinedNow(),
  );

  @override
  Future<Student> joinBranch(int id, {required String phone}) async {
    joins.add((id: id, phone: phone));
    markJoined();
    return Student(id: id, fullName: 'Botir Aliyev', phone: phone);
  }
}

class _NoGroups implements GroupsRepository {
  @override
  Future<List<Group>> list({bool includeInactive = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BranchSpyTeachers implements TeachersRepository {
  _BranchSpyTeachers(this.inner, this.onSet);

  final TeachersRepository inner;
  final void Function(List<int>) onSet;

  @override
  Future<Teacher> setBranches(int id, List<int> branchIds) async {
    onSet(branchIds);
    return Teacher(id: id, fullName: 'Madina Karimova', isActive: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Two groups, one in each branch; a branch pick narrows the answer.
class _BranchQabul implements QabulRepository {
  _BranchQabul(this.asked);

  final List<int?> asked;

  GroupMatch _g(int id, String name, int branch, String branchName) =>
      GroupMatch(
        groupId: id,
        branchId: branch,
        branchName: branchName,
        name: name,
        subjectName: 'Ingliz tili',
        teacherName: 'Madina Karimova',
        feeAmount: 300000,
        billingMode: 'fixed_day',
        billingDay: 1,
        prorateFirstPeriod: true,
        enrolled: 3,
        slots: const [],
        matchedDays: 0,
        totalDays: 0,
      );

  @override
  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
    int? branchId,
  }) async {
    asked.add(branchId);
    final all = [
      _g(7, 'Beginner A', 1, 'Bosh ofis'),
      _g(8, 'Beginner B', 2, 'Chilonzor'),
    ];
    final shown = branchId == null || branchId == 0
        ? all
        : all.where((g) => g.branchId == branchId).toList();
    return GroupSearchResult(exact: shown, near: const []);
  }

  @override
  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
