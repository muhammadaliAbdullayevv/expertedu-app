/// How a payment was made, as stored ('cash' | 'card' | 'click_payme') and
/// as shown. Order is the order offered in forms.
const Map<String, String> paymentMethodLabels = <String, String>{
  'cash': 'Naqd',
  'card': 'Karta',
  'click_payme': 'Click/Payme',
};

/// "-" for payments recorded before methods existed (null) -- and for any
/// value this build doesn't know, rather than failing.
String paymentMethodLabel(String? method) => paymentMethodLabels[method] ?? '-';
