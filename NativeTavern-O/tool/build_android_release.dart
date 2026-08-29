import 'dart:convert';
import 'dart:io';

class AndroidRegistrantCleanup {
  const AndroidRegistrantCleanup({
    required this.source,
    required this.removedPlugins,
  });

  final String source;
  final Set<String> removedPlugins;
}

Set<String> readAndroidDevPluginNames(File metadata) {
  final decoded = jsonDecode(metadata.readAsStringSync());
  if (decoded is! Map<String, dynamic>) return const {};
  final plugins = decoded['plugins'];
  if (plugins is! Map<String, dynamic>) return const {};
  final android = plugins['android'];
  if (android is! List<dynamic>) return const {};

  return android
      .whereType<Map<String, dynamic>>()
      .where((plugin) => plugin['dev_dependency'] == true)
      .map((plugin) => plugin['name'])
      .whereType<String>()
      .where((name) => name.isNotEmpty)
      .toSet();
}

AndroidRegistrantCleanup removeAndroidDevPluginRegistrations(
  String source,
  Set<String> devPluginNames,
) {
  if (devPluginNames.isEmpty) {
    return AndroidRegistrantCleanup(
      source: source,
      removedPlugins: const {},
    );
  }

  final lines = const LineSplitter().convert(source);
  final output = <String>[];
  final removed = <String>{};
  var index = 0;

  while (index < lines.length) {
    if (lines[index].trim() != 'try {') {
      output.add(lines[index]);
      index++;
      continue;
    }

    var end = index;
    var braceDepth = 0;
    do {
      final line = lines[end];
      braceDepth += '{'.allMatches(line).length;
      braceDepth -= '}'.allMatches(line).length;
      end++;
    } while (end < lines.length && braceDepth > 0);

    final block = lines.sublist(index, end);
    String? matchedPlugin;
    for (final plugin in devPluginNames) {
      if (block.any((line) => line.contains('plugin $plugin,'))) {
        matchedPlugin = plugin;
        break;
      }
    }

    if (matchedPlugin == null) {
      output.addAll(block);
    } else {
      removed.add(matchedPlugin);
    }
    index = end;
  }

  var result = output.join('\n');
  if (source.endsWith('\n')) result += '\n';
  return AndroidRegistrantCleanup(source: result, removedPlugins: removed);
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln(
      'usage: dart run tool/build_android_release.dart '
      '<plugin-metadata> <generated-registrant>',
    );
    exitCode = 64;
    return;
  }

  final metadata = File(arguments[0]);
  final registrant = File(arguments[1]);
  if (!metadata.existsSync()) {
    stderr.writeln('Plugin metadata not found: ${metadata.path}');
    exitCode = 66;
    return;
  }
  if (!registrant.existsSync()) {
    stderr.writeln('Android plugin registrant not found: ${registrant.path}');
    exitCode = 66;
    return;
  }

  final devPlugins = readAndroidDevPluginNames(metadata);
  final cleanup = removeAndroidDevPluginRegistrations(
    registrant.readAsStringSync(),
    devPlugins,
  );
  registrant.writeAsStringSync(cleanup.source);

  final names = cleanup.removedPlugins.toList()..sort();
  if (names.isEmpty) {
    stdout.writeln('Android registrant has no dev-only plugin entries.');
  } else {
    stdout.writeln(
      'Removed dev-only Android plugin registrations: ${names.join(', ')}',
    );
  }
}
