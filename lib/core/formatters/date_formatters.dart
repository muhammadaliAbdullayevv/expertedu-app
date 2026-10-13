import 'package:intl/intl.dart';

class DateFormatters {
  DateFormatters._();

  // Spelled out manually (rather than relying on intl's locale data for
  // 'uz', which isn't reliably bundled) so "10 iyul 2026" always renders
  // correctly regardless of what locale data happens to be initialized.
  static const List<String> _monthNames = <String>[
    'yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun',
    'iyul', 'avgust', 'sentyabr', 'oktyabr', 'noyabr', 'dekabr',
  ];
  static final DateFormat _time = DateFormat('HH:mm');

  static String date(DateTime value) {
    final local = value.toLocal();
    return '${local.day} ${_monthNames[local.month - 1]} ${local.year}';
  }

  /// "Sentyabr 2026" -- a whole month with no day number, for browsing the
  /// "Shu oy" report card back to an earlier month.
  static String monthYearLabel(DateTime value) {
    final local = value.toLocal();
    final name = _monthNames[local.month - 1];
    return '${name[0].toUpperCase()}${name.substring(1)} ${local.year}';
  }

  static String dateTime(DateTime value) => '${date(value)} ${_time.format(value.toLocal())}';

  static String time(DateTime value) => _time.format(value.toLocal());

  static String backupStamp(DateTime value) =>
      DateFormat('yyyyMMdd_HHmmss').format(value.toLocal());

  /// "Bugun, dd.MM.yyyy HH:mm" for today, otherwise the plain date and time.
  /// "Hozir faol" / "5 daqiqa oldin" / "3 soat oldin" / "2 kun oldin" --
  /// for presence ("last seen") text, not general timestamps.
  static String lastSeen(DateTime? value) {
    if (value == null) {
      return 'Hech qachon kirmagan';
    }
    final diff = DateTime.now().difference(value.toLocal());
    if (diff.inSeconds < 60) {
      return 'Hozir faol';
    }
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} daqiqa oldin faol edi';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} soat oldin faol edi';
    }
    if (diff.inDays < 30) {
      return '${diff.inDays} kun oldin faol edi';
    }
    return '${dateTime(value)} da faol edi';
  }

  static String relativeDateTime(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return 'Bugun, ${dateTime(value)}';
    }
    return dateTime(value);
  }

  /// "Bugun" / "Kecha" / "10 iyul 2026" -- for grouping a list by day.
  static String dateGroupLabel(DateTime value) {
    final local = value.toLocal();
    final today = DateTime.now();
    final diffDays = DateTime(today.year, today.month, today.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    if (diffDays == 0) return 'Bugun';
    if (diffDays == 1) return 'Kecha';
    return date(value);
  }

  static bool isSameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  /// "14:32" for today, "Kecha" for yesterday, otherwise a short date --
  /// for a chat list's per-conversation last-message timestamp.
  static String chatListTimestamp(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final diffDays = DateTime(now.year, now.month, now.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    if (diffDays == 0) return _time.format(local);
    if (diffDays == 1) return 'Kecha';
    return date(value);
  }

  /// "14-20 sentyabr" (one shared month), or "28 avgust - 3 sentyabr" if the
  /// range crosses a month -- for a collapsed run of no-activity days.
  static String dateRangeLabel(DateTime from, DateTime to) {
    final f = from.toLocal();
    final t = to.toLocal();
    if (f.year == t.year && f.month == t.month) {
      return '${f.day}-${t.day} ${_monthNames[f.month - 1]}';
    }
    if (f.year == t.year) {
      return '${f.day} ${_monthNames[f.month - 1]} - ${t.day} ${_monthNames[t.month - 1]}';
    }
    return '${date(f)} - ${date(t)}';
  }
}
