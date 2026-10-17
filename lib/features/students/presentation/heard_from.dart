/// Where a student heard about the center, as stored and as shown. Order is
/// the order offered in the add dialog.
const Map<String, String> heardFromLabels = <String, String>{
  'instagram': 'Instagram',
  'telegram': 'Telegram',
  'referral': 'Do\'st tavsiyasi',
  'walk_in': 'Tashrif',
  'other': 'Boshqa',
};

String heardFromLabel(String? value) => heardFromLabels[value] ?? '-';
