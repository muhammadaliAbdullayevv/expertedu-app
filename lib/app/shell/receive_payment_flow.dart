import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters/phone_formatter.dart';
import '../../features/billing/presentation/record_payment_sheet.dart';
import '../../features/enrollments/data/enrollments_repository.dart';
import '../../features/students/data/students_repository.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// "To'lov qabul qilish" from anywhere: pick the student, then the group
/// they are paying for, then take the payment. Returns true if one was
/// recorded. (The full payment panel and sheet arrive with Phase 4; this
/// puts the one entry point -- the phone's "+" and the "+ Yangi" menu --
/// in place on top of the payment sheet that exists.)
Future<bool> showReceivePayment(BuildContext context, WidgetRef ref) async {
  const s = AppStrings.current;
  final student = await showDialog<Student>(
    context: context,
    builder: (context) => const _StudentPicker(),
  );
  if (student == null || !context.mounted) return false;

  final enrollments = (await ref
      .read(enrollmentsRepositoryProvider)
      .listForStudent(student.id));
  if (!context.mounted) return false;
  final active = enrollments.where((e) => e.status == 'active').toList();
  final candidates = active.isNotEmpty ? active : enrollments;
  if (candidates.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.studentHasNoGroup)));
    return false;
  }

  StudentEnrollment? chosen = candidates.length == 1 ? candidates.first : null;
  chosen ??= await showDialog<StudentEnrollment>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('${s.pickGroup} — ${student.fullName}'),
      children: <Widget>[
        for (final e in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(e),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(e.groupName)),
                if (e.balance > 0)
                  Text(
                    '${s.owes} ${e.balance}',
                    style: const TextStyle(color: AppColors.dangerText),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return false;

  final recorded = await showRecordPaymentSheet(
    context,
    enrollmentId: chosen.enrollmentId,
    balance: chosen.balance,
  );
  if (recorded == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.paymentRecorded)));
    return true;
  }
  return false;
}

class _StudentPicker extends ConsumerStatefulWidget {
  const _StudentPicker();

  @override
  ConsumerState<_StudentPicker> createState() => _StudentPickerState();
}

class _StudentPickerState extends ConsumerState<_StudentPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Student> _students = const [];
  bool _loading = false;
  Object? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(text));
  }

  Future<void> _search(String query) async {
    final id = ++_request;
    setState(() => _loading = true);
    try {
      final found = await ref
          .read(studentsRepositoryProvider)
          .list(query: query.trim());
      if (!mounted || id != _request) return;
      setState(() {
        _students = found.take(30).toList();
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _request) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                s.receivePayment,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                s.pickStudent,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: s.searchStudentHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _error != null
                    ? Center(
                        child: TextButton(
                          onPressed: () => _search(_controller.text),
                          child: Text(s.retry),
                        ),
                      )
                    : _loading && _students.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        shrinkWrap: true,
                        children: <Widget>[
                          for (final student in _students)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                student.fullName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                PhoneFormatter.display(student.phone),
                              ),
                              trailing: student.balance > 0
                                  ? Text(
                                      '${s.owes} ${student.balance}',
                                      style: const TextStyle(
                                        color: AppColors.dangerText,
                                        fontSize: 12,
                                      ),
                                    )
                                  : null,
                              onTap: () => Navigator.of(context).pop(student),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
