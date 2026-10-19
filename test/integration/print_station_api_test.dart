// The print station against a real, running API: it takes the job the bot queued, downloads the PDF and
// reports the result. Opt-in (needs a throwaway server with one queued job in the branch of the account):
//
//   flutter test test/integration/print_station_api_test.dart \
//     --dart-define=API_BASE_URL=http://127.0.0.1:8765 --dart-define=E2E_TOKEN=<an admin's JWT> \
//     --dart-define=E2E_EXPECTED_PDF=/path/to/the/queued.pdf

import 'dart:io';

import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/printing/print_driver.dart';
import 'package:expert_edu_center/services/printing/print_station.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = String.fromEnvironment('E2E_TOKEN');
const _expected = String.fromEnvironment('E2E_EXPECTED_PDF');

class _Tokens extends TokenStorage {
  @override
  Future<String?> readToken() async => _token;
}

class _Recording implements PrintDriver {
  final List<PrintRequest> printed = <PrintRequest>[];
  final List<List<int>> contents = <List<int>>[];

  @override
  Future<List<PrinterInfo>> printers() async => const <PrinterInfo>[PrinterInfo('Test printer')];

  @override
  Future<String?> problem() async => null;

  @override
  Future<void> print(String printer, PrintRequest request) async {
    printed.add(request);
    contents.add(File(request.path).readAsBytesSync());
  }
}

void main() {
  test('takes the queued job, gets its PDF, "prints" it and reports', () async {
    final dir = Directory.systemTemp.createTempSync('station_e2e');
    final driver = _Recording();
    final station = PrintStation(
      api: ApiClient(_Tokens()),
      driver: driver,
      signedIn: () => true,
      configDirectory: () async => dir,
      tempDirectory: () async => dir,
    );
    await station.start();
    await station.setEnabled(true); // says "I'm here" and takes the job
    expect(driver.printed, hasLength(1), reason: station.status);
    final request = driver.printed.single;
    expect((request.copies, request.duplex, request.color), (2, true, false));
    expect(driver.contents.single, File(_expected).readAsBytesSync());
    await station.loadHistory();
    expect(station.history.first.status, 'done');
    expect(station.history.first.title, 'Headway.pdf');
    station.dispose();
    dir.deleteSync(recursive: true);
  }, skip: _token.isEmpty ? 'needs a running API (see the top of this file)' : null);
}
