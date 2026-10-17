import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../billing/presentation/transaction_history_screen.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../data/students_repository.dart';
import 'heard_from.dart';

/// A read-only card for one student: contacts and every group they're in
/// with its balance -- tap a group for its payment history. Opened by the
/// add dialog's "Ochish" when a phone number already belongs to someone.
Future<void> showStudentSummaryDialog(BuildContext context, int studentId) {
  return showDialog<void>(
    context: context,
    builder: (_) => _StudentSummaryDialog(studentId: studentId),
  );
}

typedef _Summary = ({Student student, List<StudentEnrollment> enrollments});

class _StudentSummaryDialog extends ConsumerStatefulWidget {
  const _StudentSummaryDialog({required this.studentId});

  final int studentId;

  @override
  ConsumerState<_StudentSummaryDialog> createState() =>
      _StudentSummaryDialogState();
}

class _StudentSummaryDialogState extends ConsumerState<_StudentSummaryDialog> {
  late final Future<_Summary> _summary = () async {
    final student = await ref
        .read(studentsRepositoryProvider)
        .get(widget.studentId);
    final enrollments = await ref
        .read(enrollmentsRepositoryProvider)
        .listForStudent(widget.studentId);
    return (student: student, enrollments: enrollments);
  }();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: SizedBox(
        width: 460,
        child: FutureBuilder<_Summary>(
          future: _summary,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text('Xatolik: ${snapshot.error}');
            }
            final student = snapshot.data!.student;
            final enrollments = snapshot.data!.enrollments;
            final muted = context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(student.fullName, style: context.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(PhoneFormatter.display(student.phone)),
                if (student.parentPhone != null)
                  Text(
                    'Ota-ona: ${PhoneFormatter.display(student.parentPhone!)}',
                    style: muted,
                  ),
                if (student.heardFrom != null)
                  Text(
                    'Qayerdan eshitdi: ${heardFromLabel(student.heardFrom)}',
                    style: muted,
                  ),
                if (student.note != null && student.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(student.note!, style: muted),
                  ),
                const SizedBox(height: 16),
                Text('Guruhlar', style: context.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (enrollments.isEmpty)
                  Text('Hech qaysi guruhda emas', style: muted),
                for (final enrollment in enrollments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(enrollment.groupName),
                    subtitle: Text(
                      enrollment.status == 'active' ? 'faol' : 'chiqib ketgan',
                      style: muted,
                    ),
                    trailing: Text(
                      enrollment.balance > 0
                          ? 'Qarz: ${CurrencyFormatter.format(enrollment.balance)}'
                          : 'Qarzi yo\'q',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: enrollment.balance > 0
                            ? context.colors.error
                            : Colors.green.shade700,
                      ),
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TransactionHistoryScreen(
                          enrollmentId: enrollment.enrollmentId,
                          studentName: student.fullName,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Yopish'),
        ),
      ],
    );
  }
}
