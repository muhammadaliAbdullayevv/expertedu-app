import 'package:flutter/material.dart';

/// Placeholder until billing exists -- once charges/payments are wired up
/// (see the plan's Billing phase), this becomes collected-this-month,
/// overdue count, per-group breakdown, etc.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'To\'lovlar funksiyasi qo\'shilgach, bu yerda oylik tushum va qarzdorlik statistikasi chiqadi.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
