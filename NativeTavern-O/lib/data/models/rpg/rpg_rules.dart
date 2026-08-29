enum RpgConditionOperator {
  equals,
  notEquals,
  greaterThan,
  greaterThanOrEqual,
  lessThan,
  lessThanOrEqual,
  contains,
  notContains,
  exists,
  all,
  any,
  not;

  static RpgConditionOperator fromJson(String value) =>
      RpgConditionOperator.values
          .firstWhere((operator) => operator.name == value);
}

/// A declarative condition tree. It deliberately has no callback or source
/// field, so imported packages cannot embed executable predicates.
class RpgCondition {
  final RpgConditionOperator operator;
  final String? path;
  final Object? value;
  final List<RpgCondition> conditions;

  const RpgCondition({
    required this.operator,
    this.path,
    this.value,
    this.conditions = const [],
  });

  Map<String, dynamic> toJson() => {
        'operator': operator.name,
        if (path != null) 'path': path,
        if (value != null) 'value': value,
        if (conditions.isNotEmpty)
          'conditions':
              conditions.map((condition) => condition.toJson()).toList(),
      };

  factory RpgCondition.fromJson(Map<String, dynamic> json) => RpgCondition(
        operator: RpgConditionOperator.fromJson(json['operator'] as String),
        path: json['path'] as String?,
        value: json['value'],
        conditions: _ruleMapList(
          json['conditions'],
        ).map(RpgCondition.fromJson).toList(),
      );
}

enum RpgEffectType {
  setValue,
  incrementValue,
  decrementValue,
  addItem,
  removeItem,
  adjustRelationship,
  moveTo,
  setQuestStatus,
  setCooldown,
  appendEvent;

  static RpgEffectType fromJson(String value) =>
      RpgEffectType.values.firstWhere((type) => type.name == value);
}

/// A typed state transition description interpreted by the future rule engine.
class RpgEffect {
  final RpgEffectType type;
  final String target;
  final Object? value;
  final num? amount;

  const RpgEffect({
    required this.type,
    required this.target,
    this.value,
    this.amount,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'target': target,
        if (value != null) 'value': value,
        if (amount != null) 'amount': amount,
      };

  factory RpgEffect.fromJson(Map<String, dynamic> json) => RpgEffect(
        type: RpgEffectType.fromJson(json['type'] as String),
        target: json['target'] as String,
        value: json['value'],
        amount: json['amount'] as num?,
      );
}

class RpgActionCost {
  final String path;
  final num amount;

  const RpgActionCost({required this.path, required this.amount});

  Map<String, dynamic> toJson() => {'path': path, 'amount': amount};

  factory RpgActionCost.fromJson(Map<String, dynamic> json) => RpgActionCost(
        path: json['path'] as String,
        amount: json['amount'] as num,
      );
}

/// Canonical dice notation such as `1d20`, `2d6+3`, or `4d8-1`.
class RpgDiceSpec {
  final String expression;

  const RpgDiceSpec(this.expression);

  Map<String, dynamic> toJson() => {'expression': expression};

  factory RpgDiceSpec.fromJson(Map<String, dynamic> json) =>
      RpgDiceSpec(json['expression'] as String);
}

class RpgSkillCheck {
  final String attributeId;
  final RpgDiceSpec dice;
  final num difficulty;
  final List<RpgEffect> successEffects;
  final List<RpgEffect> failureEffects;

  const RpgSkillCheck({
    required this.attributeId,
    required this.dice,
    required this.difficulty,
    this.successEffects = const [],
    this.failureEffects = const [],
  });

  Map<String, dynamic> toJson() => {
        'attributeId': attributeId,
        'dice': dice.toJson(),
        'difficulty': difficulty,
        if (successEffects.isNotEmpty)
          'successEffects':
              successEffects.map((effect) => effect.toJson()).toList(),
        if (failureEffects.isNotEmpty)
          'failureEffects':
              failureEffects.map((effect) => effect.toJson()).toList(),
      };

  factory RpgSkillCheck.fromJson(Map<String, dynamic> json) => RpgSkillCheck(
        attributeId: json['attributeId'] as String,
        dice: RpgDiceSpec.fromJson(json['dice'] as Map<String, dynamic>),
        difficulty: json['difficulty'] as num,
        successEffects: _ruleMapList(
          json['successEffects'],
        ).map(RpgEffect.fromJson).toList(),
        failureEffects: _ruleMapList(
          json['failureEffects'],
        ).map(RpgEffect.fromJson).toList(),
      );
}

class RpgActionDefinition {
  final String id;
  final String label;
  final String description;
  final List<RpgCondition> availability;
  final List<RpgActionCost> costs;
  final RpgSkillCheck? check;
  final List<RpgEffect> effects;

  const RpgActionDefinition({
    required this.id,
    required this.label,
    this.description = '',
    this.availability = const [],
    this.costs = const [],
    this.check,
    this.effects = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (description.isNotEmpty) 'description': description,
        if (availability.isNotEmpty)
          'availability':
              availability.map((condition) => condition.toJson()).toList(),
        if (costs.isNotEmpty)
          'costs': costs.map((cost) => cost.toJson()).toList(),
        if (check != null) 'check': check!.toJson(),
        if (effects.isNotEmpty)
          'effects': effects.map((effect) => effect.toJson()).toList(),
      };

  factory RpgActionDefinition.fromJson(Map<String, dynamic> json) =>
      RpgActionDefinition(
        id: json['id'] as String,
        label: json['label'] as String,
        description: json['description'] as String? ?? '',
        availability: _ruleMapList(
          json['availability'],
        ).map(RpgCondition.fromJson).toList(),
        costs: _ruleMapList(json['costs']).map(RpgActionCost.fromJson).toList(),
        check: json['check'] == null
            ? null
            : RpgSkillCheck.fromJson(json['check'] as Map<String, dynamic>),
        effects: _ruleMapList(json['effects']).map(RpgEffect.fromJson).toList(),
      );
}

enum RpgMutationSource {
  ruleEngine,
  narrative;

  static RpgMutationSource fromJson(String value) =>
      RpgMutationSource.values.firstWhere((source) => source.name == value);
}

/// Proposed changes are tagged by origin so protected state can reject changes
/// derived directly from narrative/LLM output.
class RpgStatePatch {
  final RpgMutationSource source;
  final List<RpgEffect> effects;

  const RpgStatePatch({required this.source, required this.effects});

  Map<String, dynamic> toJson() => {
        'source': source.name,
        'effects': effects.map((effect) => effect.toJson()).toList(),
      };

  factory RpgStatePatch.fromJson(Map<String, dynamic> json) => RpgStatePatch(
        source: RpgMutationSource.fromJson(json['source'] as String),
        effects: _ruleMapList(json['effects']).map(RpgEffect.fromJson).toList(),
      );
}

List<Map<String, dynamic>> _ruleMapList(Object? value) =>
    (value as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item as Map<String, dynamic>)
        .toList();
