import 'dart:io';

void main() {
  const headerPath = 'packages/spine_flutter_4_1_compat/src/spine_flutter.h';
  const implementationPath =
      'packages/spine_flutter_4_1_compat/src/spine_flutter.cpp';
  const outputPath =
      'packages/spine_flutter_4_1_compat/ios/spine_flutter.exports';
  final header = File(headerPath).readAsStringSync();
  final declaredNames = RegExp(
    r'SPINE_FLUTTER_EXPORT\s+[^;\n]*?\b(spine_[A-Za-z0-9_]+)\s*\(',
  ).allMatches(header).map((match) => match.group(1)!).toSet();
  final definitionPattern = RegExp(
    r'^(?:[A-Za-z_][A-Za-z0-9_:<>]*[\s*&]+)+'
    r'(spine_[A-Za-z0-9_]+)\s*\(',
  );
  final definedNames = <String>{
    for (final line in File(implementationPath).readAsLinesSync())
      if (definitionPattern.firstMatch(line) case final match?) match.group(1)!,
  };
  final missingDefinitions = declaredNames.difference(definedNames);
  const expectedMissingDefinitions = {
    'spine_bone_set_a_shear_y',
    'spine_ik_constraint_data_set_uniform',
  };
  if (missingDefinitions.length != expectedMissingDefinitions.length ||
      !missingDefinitions.containsAll(expectedMissingDefinitions)) {
    stderr.writeln(
      'Unexpected Spine declarations without implementations: '
      '${missingDefinitions.toList()..sort()}',
    );
    exitCode = 1;
    return;
  }
  final names = declaredNames.intersection(definedNames).toList()..sort();

  if (names.length < 100 ||
      !names.contains('spine_major_version') ||
      !names.contains('spine_minor_version')) {
    stderr.writeln(
      'Refusing to generate an incomplete Spine export list '
      '(${names.length} symbols).',
    );
    exitCode = 1;
    return;
  }

  File(outputPath).writeAsStringSync(
    '${names.map((name) => '_$name').join('\n')}\n',
  );
  stdout.writeln(
    'Generated ${names.length} Spine iOS exports; skipped '
    '${missingDefinitions.length} unimplemented declarations.',
  );
}
