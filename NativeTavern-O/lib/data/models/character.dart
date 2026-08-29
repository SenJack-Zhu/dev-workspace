import 'package:native_tavern/data/models/live2d.dart';

/// Character depth prompt (ST extensions.depth_prompt):
/// a note injected at a fixed depth in the chat history
class DepthPrompt {
  final int depth;
  final String prompt;
  final String role; // system, user, or assistant

  const DepthPrompt({
    this.depth = 4,
    this.prompt = '',
    this.role = 'system',
  });

  Map<String, dynamic> toJson() => {
        'depth': depth,
        'prompt': prompt,
        'role': role,
      };

  factory DepthPrompt.fromJson(Map<String, dynamic> json) => DepthPrompt(
        depth: (json['depth'] as num?)?.toInt() ?? 4,
        prompt: json['prompt'] as String? ?? '',
        role: json['role'] as String? ?? 'system',
      );
}

/// Character model for NativeTavern
class Character {
  final String id;
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMessage;
  final List<String> alternateGreetings;
  final String exampleMessages;
  final String systemPrompt;
  final String postHistoryInstructions;
  final String creatorNotes;
  final List<String> tags;
  final String creator;
  final String version;
  final CharacterAssets? assets;
  final CharacterBook? characterBook;
  final Map<String, dynamic> extensions;
  final bool isFavorite;

  /// Soft-deleted characters stay available to old links and editing.
  final bool isDeleted;

  /// Note injected at a fixed depth (ST extensions.depth_prompt)
  final DepthPrompt? depthPrompt;

  /// Group chat response weight 0.0-1.0 (ST extensions.talkativeness)
  final double talkativeness;

  final DateTime createdAt;
  final DateTime modifiedAt;

  const Character({
    required this.id,
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMessage = '',
    this.alternateGreetings = const [],
    this.exampleMessages = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.creatorNotes = '',
    this.tags = const [],
    this.creator = '',
    this.version = '',
    this.assets,
    this.characterBook,
    this.extensions = const {},
    this.isFavorite = false,
    this.isDeleted = false,
    this.depthPrompt,
    this.talkativeness = 0.5,
    required this.createdAt,
    required this.modifiedAt,
  });

  Character copyWith({
    String? id,
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMessage,
    List<String>? alternateGreetings,
    String? exampleMessages,
    String? systemPrompt,
    String? postHistoryInstructions,
    String? creatorNotes,
    List<String>? tags,
    String? creator,
    String? version,
    CharacterAssets? assets,
    bool clearAssets = false,
    CharacterBook? characterBook,
    Map<String, dynamic>? extensions,
    bool? isFavorite,
    bool? isDeleted,
    DepthPrompt? depthPrompt,
    double? talkativeness,
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) {
    return Character(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      personality: personality ?? this.personality,
      scenario: scenario ?? this.scenario,
      firstMessage: firstMessage ?? this.firstMessage,
      alternateGreetings: alternateGreetings ?? this.alternateGreetings,
      exampleMessages: exampleMessages ?? this.exampleMessages,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      postHistoryInstructions:
          postHistoryInstructions ?? this.postHistoryInstructions,
      creatorNotes: creatorNotes ?? this.creatorNotes,
      tags: tags ?? this.tags,
      creator: creator ?? this.creator,
      version: version ?? this.version,
      assets: clearAssets ? null : (assets ?? this.assets),
      characterBook: characterBook ?? this.characterBook,
      extensions: extensions ?? this.extensions,
      isFavorite: isFavorite ?? this.isFavorite,
      isDeleted: isDeleted ?? this.isDeleted,
      depthPrompt: depthPrompt ?? this.depthPrompt,
      talkativeness: talkativeness ?? this.talkativeness,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'personality': personality,
        'scenario': scenario,
        'firstMessage': firstMessage,
        'alternateGreetings': alternateGreetings,
        'exampleMessages': exampleMessages,
        'systemPrompt': systemPrompt,
        'postHistoryInstructions': postHistoryInstructions,
        'creatorNotes': creatorNotes,
        'tags': tags,
        'creator': creator,
        'version': version,
        'assets': assets?.toJson(),
        'characterBook': characterBook?.toJson(),
        'extensions': extensions,
        'isFavorite': isFavorite,
        'isDeleted': isDeleted,
        'depthPrompt': depthPrompt?.toJson(),
        'talkativeness': talkativeness,
        'createdAt': createdAt.toIso8601String(),
        'modifiedAt': modifiedAt.toIso8601String(),
      };

  factory Character.fromJson(Map<String, dynamic> json) => Character(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        personality: json['personality'] as String? ?? '',
        scenario: json['scenario'] as String? ?? '',
        firstMessage: json['firstMessage'] as String? ?? '',
        alternateGreetings:
            (json['alternateGreetings'] as List<dynamic>?)?.cast<String>() ??
                [],
        exampleMessages: json['exampleMessages'] as String? ?? '',
        systemPrompt: json['systemPrompt'] as String? ?? '',
        postHistoryInstructions:
            json['postHistoryInstructions'] as String? ?? '',
        creatorNotes: json['creatorNotes'] as String? ?? '',
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
        creator: json['creator'] as String? ?? '',
        version: json['version'] as String? ?? '',
        assets: json['assets'] != null
            ? CharacterAssets.fromJson(json['assets'] as Map<String, dynamic>)
            : null,
        characterBook: json['characterBook'] != null
            ? CharacterBook.fromJson(
                json['characterBook'] as Map<String, dynamic>)
            : null,
        extensions: json['extensions'] as Map<String, dynamic>? ?? {},
        isFavorite: json['isFavorite'] as bool? ?? false,
        isDeleted: json['isDeleted'] as bool? ?? false,
        depthPrompt: json['depthPrompt'] != null
            ? DepthPrompt.fromJson(json['depthPrompt'] as Map<String, dynamic>)
            : (json['extensions'] is Map<String, dynamic> &&
                    (json['extensions'] as Map<String, dynamic>)['depth_prompt']
                        is Map<String, dynamic>)
                ? DepthPrompt.fromJson(
                    (json['extensions'] as Map<String, dynamic>)['depth_prompt']
                        as Map<String, dynamic>)
                : null,
        talkativeness: (json['talkativeness'] as num?)?.toDouble() ??
            (json['extensions'] is Map<String, dynamic>
                ? _parseTalkativeness((json['extensions']
                    as Map<String, dynamic>)['talkativeness'])
                : 0.5),
        createdAt: DateTime.parse(json['createdAt'] as String),
        modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      );

  static double _parseTalkativeness(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.5;
    return 0.5;
  }

  /// Extract a depth prompt from an ST extensions map, if present
  static DepthPrompt? depthPromptFromExtensions(
      Map<String, dynamic> extensions) {
    final raw = extensions['depth_prompt'];
    if (raw is Map<String, dynamic>) return DepthPrompt.fromJson(raw);
    return null;
  }

  /// Extract talkativeness from an ST extensions map (default 0.5)
  static double talkativenessFromExtensions(Map<String, dynamic> extensions) {
    return _parseTalkativeness(extensions['talkativeness']);
  }

  /// Extensions map with first-class depth_prompt/talkativeness merged
  /// back in for SillyTavern-compatible export
  Map<String, dynamic> extensionsForExport() {
    final merged = Map<String, dynamic>.from(extensions);
    if (depthPrompt != null && depthPrompt!.prompt.isNotEmpty) {
      merged['depth_prompt'] = depthPrompt!.toJson();
    }
    merged['talkativeness'] = talkativeness;
    return merged;
  }
}

/// Character assets (avatar, expression packs, etc.)
class CharacterAssets {
  final String? avatarPath;
  final String? avatarUrl;
  final Map<String, String>? expressionPack;
  final Live2DConfig? live2d;

  const CharacterAssets({
    this.avatarPath,
    this.avatarUrl,
    this.expressionPack,
    this.live2d,
  });

  bool get hasAssets =>
      avatarPath != null ||
      avatarUrl != null ||
      (expressionPack?.isNotEmpty ?? false) ||
      live2d != null;

  CharacterAssets copyWith({
    String? avatarPath,
    String? avatarUrl,
    Map<String, String>? expressionPack,
    Live2DConfig? live2d,
    bool clearLive2D = false,
  }) {
    return CharacterAssets(
      avatarPath: avatarPath ?? this.avatarPath,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      expressionPack: expressionPack ?? this.expressionPack,
      live2d: clearLive2D ? null : (live2d ?? this.live2d),
    );
  }

  Map<String, dynamic> toJson() => {
        'avatarPath': avatarPath,
        'avatarUrl': avatarUrl,
        'expressionPack': expressionPack,
        'live2d': live2d?.toJson(),
      };

  factory CharacterAssets.fromJson(Map<String, dynamic> json) =>
      CharacterAssets(
        avatarPath: json['avatarPath'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
        expressionPack: (json['expressionPack'] as Map<String, dynamic>?)
            ?.cast<String, String>(),
        live2d: json['live2d'] is Map<String, dynamic>
            ? Live2DConfig.fromJson(json['live2d'] as Map<String, dynamic>)
            : null,
      );
}

/// Embedded character lorebook (character_book in V2/V3 spec)
class CharacterBook {
  final String? name;
  final String? description;
  final bool scanDepth;
  final int tokenBudget;
  final bool recursiveScanning;
  final List<CharacterBookEntry> entries;
  final Map<String, dynamic> extensions;

  const CharacterBook({
    this.name,
    this.description,
    this.scanDepth = true,
    this.tokenBudget = 2048,
    this.recursiveScanning = false,
    this.entries = const [],
    this.extensions = const {},
  });

  CharacterBook copyWith({
    String? name,
    String? description,
    bool? scanDepth,
    int? tokenBudget,
    bool? recursiveScanning,
    List<CharacterBookEntry>? entries,
    Map<String, dynamic>? extensions,
  }) {
    return CharacterBook(
      name: name ?? this.name,
      description: description ?? this.description,
      scanDepth: scanDepth ?? this.scanDepth,
      tokenBudget: tokenBudget ?? this.tokenBudget,
      recursiveScanning: recursiveScanning ?? this.recursiveScanning,
      entries: entries ?? this.entries,
      extensions: extensions ?? this.extensions,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'scan_depth': scanDepth,
        'token_budget': tokenBudget,
        'recursive_scanning': recursiveScanning,
        'entries': entries.map((e) => e.toJson()).toList(),
        'extensions': extensions,
      };

  factory CharacterBook.fromJson(Map<String, dynamic> json) => CharacterBook(
        name: json['name'] as String?,
        description: json['description'] as String?,
        scanDepth: json['scan_depth'] as bool? ?? true,
        tokenBudget: json['token_budget'] as int? ?? 2048,
        recursiveScanning: json['recursive_scanning'] as bool? ?? false,
        entries: (json['entries'] as List<dynamic>?)
                ?.map((e) =>
                    CharacterBookEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        extensions: json['extensions'] as Map<String, dynamic>? ?? {},
      );
}

/// Entry in a character book (embedded lorebook)
class CharacterBookEntry {
  final int id;
  final List<String> keys;
  final List<String> secondaryKeys;
  final String content;
  final String comment;
  final bool enabled;
  final int insertionOrder;
  final bool caseSensitive;
  final String name;
  final int priority;
  final bool constant;
  final bool selective;
  final int position; // 0 = before char defs, 1 = after char defs
  final Map<String, dynamic> extensions;

  const CharacterBookEntry({
    required this.id,
    this.keys = const [],
    this.secondaryKeys = const [],
    this.content = '',
    this.comment = '',
    this.enabled = true,
    this.insertionOrder = 0,
    this.caseSensitive = false,
    this.name = '',
    this.priority = 10,
    this.constant = false,
    this.selective = false,
    this.position = 0,
    this.extensions = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'keys': keys,
        'secondary_keys': secondaryKeys,
        'content': content,
        'comment': comment,
        'enabled': enabled,
        'insertion_order': insertionOrder,
        'case_sensitive': caseSensitive,
        'name': name,
        'priority': priority,
        'constant': constant,
        'selective': selective,
        'position': position,
        'extensions': extensions,
      };

  factory CharacterBookEntry.fromJson(Map<String, dynamic> json) =>
      CharacterBookEntry(
        id: json['id'] as int? ?? 0,
        keys: (json['keys'] as List<dynamic>?)?.cast<String>() ?? [],
        secondaryKeys:
            (json['secondary_keys'] as List<dynamic>?)?.cast<String>() ?? [],
        content: json['content'] as String? ?? '',
        comment: json['comment'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        insertionOrder: json['insertion_order'] as int? ?? 0,
        caseSensitive: json['case_sensitive'] as bool? ?? false,
        name: json['name'] as String? ?? '',
        priority: json['priority'] as int? ?? 10,
        constant: json['constant'] as bool? ?? false,
        selective: json['selective'] as bool? ?? false,
        position: json['position'] as int? ?? 0,
        extensions: json['extensions'] as Map<String, dynamic>? ?? {},
      );
}
