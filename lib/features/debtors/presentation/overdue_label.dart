/// "45 kundan beri" / "bugundan" -- how long the oldest unpaid charge has
/// been due, in whole calendar days up to [today]. Pass the server's date
/// where there is one (the dashboard's), so it matches the center's own
/// calendar rather than whatever the device clock says.
String overdueLabel(DateTime? oldestUnpaidDue, DateTime today) {
  if (oldestUnpaidDue == null) return '';
  final days = DateTime.utc(today.year, today.month, today.day)
      .difference(
        DateTime.utc(
          oldestUnpaidDue.year,
          oldestUnpaidDue.month,
          oldestUnpaidDue.day,
        ),
      )
      .inDays;
  if (days <= 0) return 'bugundan';
  return '$days kundan beri';
}
