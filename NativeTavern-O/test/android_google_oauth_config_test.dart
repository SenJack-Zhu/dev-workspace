import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/google_drive_service.dart';

void main() {
  test('Android Google Sign-In uses the web OAuth client ID', () async {
    final service = await File(
      'lib/domain/services/google_drive_service.dart',
    ).readAsString();

    expect(
      GoogleDriveService.webClientId,
      '1077961567755-p0khm1rtqf9d16mjp1ckccb17nc8qlef.apps.googleusercontent.com',
    );
    expect(service, contains('else if (Platform.isAndroid)'));
    expect(service, contains('serverClientId: webClientId'));
  });
}
