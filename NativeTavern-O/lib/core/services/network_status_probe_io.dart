import 'dart:io';

Future<bool?> probeLocalNetworkAvailability() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      includeLoopback: false,
    );
    return interfaces.any((interface) => interface.addresses.isNotEmpty);
  } on SocketException {
    return false;
  } on UnsupportedError {
    return null;
  }
}
