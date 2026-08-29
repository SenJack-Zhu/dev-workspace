import 'network_status_probe_stub.dart'
    if (dart.library.io) 'network_status_probe_io.dart' as implementation;

Future<bool?> probeLocalNetworkAvailability() {
  return implementation.probeLocalNetworkAvailability();
}
