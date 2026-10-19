import 'dart:convert';
import 'dart:typed_data';

/// A one-page PDF for trying the printer: the center's name and the time.
/// (Written by hand -- plain ASCII text, standard Helvetica -- so no PDF
/// library is needed.)
Uint8List testPagePdf(String printer, DateTime now) {
  String ascii(String s) => s
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '?')
      .replaceAll(r'\', r'\\')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)');
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
  final content =
      'BT /F1 28 Tf 72 740 Td (Expert Edu Center) Tj ET\n'
      'BT /F1 16 Tf 72 700 Td (Printer sinov varag\'i / Printer test page) Tj ET\n'
      'BT /F1 12 Tf 72 670 Td (${ascii(printer)}) Tj ET\n'
      'BT /F1 12 Tf 72 650 Td ($stamp) Tj ET\n'
      '0.5 w 72 630 451 0 re S\n';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(out.toString()));
}
