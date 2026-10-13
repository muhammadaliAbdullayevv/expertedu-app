import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityService(),
);

/// Whether the device *has a link* (wifi/mobile data connected) -- not
/// proof the internet actually works. A link event is only ever used to
/// trigger a real sync attempt; `SyncEngine` treats an actual HTTP failure
/// as the real signal, since shop wifi commonly stays "connected" with no
/// real uplink.
class ConnectivityService {
  Stream<bool> get onLinkChanged {
    return Connectivity().onConnectivityChanged.map(
      (results) => results.any((r) => r != ConnectivityResult.none),
    );
  }
}
