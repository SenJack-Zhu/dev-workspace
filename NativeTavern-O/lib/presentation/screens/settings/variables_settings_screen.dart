import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/variables_service.dart';
import 'package:native_tavern/presentation/providers/variables_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/presentation/widgets/common/adaptive_popup_menu.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// Screen for managing variables
class VariablesSettingsScreen extends ConsumerWidget {
  final String? chatId;

  const VariablesSettingsScreen({super.key, this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final globalVars = ref.watch(globalVariablesProvider);
    final localVars = chatId != null
        ? ref.watch(localVariablesProvider(chatId!))
        : <String, dynamic>{};
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(chatId != null ? l10n.chatVariables : l10n.variables),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.addVariable,
            onPressed: () => _showAddVariableDialog(context, ref),
          ),
          AdaptivePopupMenuButton<String>(
            onSelected: (value) => _handleMenuAction(context, ref, value),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'clear_global',
                child: ListTile(
                  leading: const Icon(Icons.delete_sweep),
                  title: Text(l10n.clearGlobalVariables),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (chatId != null)
                PopupMenuItem(
                  value: 'clear_local',
                  child: ListTile(
                    leading: const Icon(Icons.delete_sweep),
                    title: Text(l10n.clearLocalVariables),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Info section
          _buildSection(
            title: l10n.aboutVariables,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.info_outline, color: AppTheme.accentColor),
                title: Text(l10n.variableSystem),
                subtitle: Text(l10n.variableSystemDescription),
              ),
              ListTile(
                leading: const Icon(Icons.code, color: AppTheme.textMuted),
                title: Text(l10n.macroUsage),
                subtitle: Text(
                  l10n.macroUsageDescription(
                    '{{getvar::name}}',
                    '{{getglobalvar::name}}',
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Global variables
          _buildSection(
            title: l10n.globalVariablesCount(globalVars.length),
            children: [
              if (globalVars.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      children: [
                        const Icon(Icons.data_object,
                            size: 48, color: AppTheme.textMuted),
                        const SizedBox(height: 16),
                        Text(
                          l10n.noGlobalVariables,
                          style: const TextStyle(color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...globalVars.entries.map((entry) => _VariableTile(
                      name: entry.key,
                      value: entry.value,
                      isGlobal: true,
                      onEdit: () => _showEditVariableDialog(
                          context, ref, entry.key, entry.value, true),
                      onDelete: () =>
                          _confirmDeleteVariable(context, ref, entry.key, true),
                      onIncrement: () => ref
                          .read(globalVariablesProvider.notifier)
                          .increment(entry.key),
                      onDecrement: () => ref
                          .read(globalVariablesProvider.notifier)
                          .decrement(entry.key),
                    )),
            ],
          ),

          if (chatId != null) ...[
            const SizedBox(height: 16),

            // Local variables
            _buildSection(
              title: l10n.localVariablesCount(localVars.length),
              children: [
                if (localVars.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(Icons.data_object,
                              size: 48, color: AppTheme.textMuted),
                          const SizedBox(height: 16),
                          Text(
                            l10n.noLocalVariables,
                            style: const TextStyle(color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ...localVars.entries.map((entry) => _VariableTile(
                        name: entry.key,
                        value: entry.value,
                        isGlobal: false,
                        onEdit: () => _showEditVariableDialog(
                            context, ref, entry.key, entry.value, false),
                        onDelete: () => _confirmDeleteVariable(
                            context, ref, entry.key, false),
                        onIncrement: () => ref
                            .read(localVariablesProvider(chatId!).notifier)
                            .increment(entry.key),
                        onDecrement: () => ref
                            .read(localVariablesProvider(chatId!).notifier)
                            .decrement(entry.key),
                      )),
              ],
            ),
          ],

          const SizedBox(height: 16),

          // Test section
          _buildSection(
            title: l10n.test,
            children: [
              _VariableTestWidget(chatId: chatId),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      color: AppTheme.darkCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppTheme.accentColor,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  void _handleMenuAction(BuildContext context, WidgetRef ref, String action) {
    switch (action) {
      case 'clear_global':
        _confirmClearVariables(context, ref, true);
        break;
      case 'clear_local':
        if (chatId != null) {
          _confirmClearVariables(context, ref, false);
        }
        break;
    }
  }

  void _showAddVariableDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final valueController = TextEditingController();
    bool isGlobal = true;
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.addVariable),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: l10n.variableName,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: valueController,
                decoration: InputDecoration(
                  labelText: l10n.variableValue,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (chatId != null)
                Row(
                  children: [
                    Text('${l10n.scope}: '),
                    ChoiceChip(
                      label: Text(l10n.global),
                      selected: isGlobal,
                      onSelected: (selected) => setState(() => isGlobal = true),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(l10n.local),
                      selected: !isGlobal,
                      onSelected: (selected) =>
                          setState(() => isGlobal = false),
                    ),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                final value = valueController.text;
                if (name.isNotEmpty) {
                  if (isGlobal) {
                    ref
                        .read(globalVariablesProvider.notifier)
                        .setVariable(name, value);
                  } else if (chatId != null) {
                    ref
                        .read(localVariablesProvider(chatId!).notifier)
                        .setVariable(name, value);
                  }
                  Navigator.pop(context);
                }
              },
              child: Text(l10n.add),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditVariableDialog(BuildContext context, WidgetRef ref, String name,
      dynamic value, bool isGlobal) {
    final valueController =
        TextEditingController(text: value?.toString() ?? '');
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editVariable(name)),
        content: TextField(
          controller: valueController,
          decoration: InputDecoration(
            labelText: l10n.variableValue,
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final newValue = valueController.text;
              if (isGlobal) {
                ref
                    .read(globalVariablesProvider.notifier)
                    .setVariable(name, newValue);
              } else if (chatId != null) {
                ref
                    .read(localVariablesProvider(chatId!).notifier)
                    .setVariable(name, newValue);
              }
              Navigator.pop(context);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteVariable(
      BuildContext context, WidgetRef ref, String name, bool isGlobal) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteVariable),
        content: Text(l10n.deleteVariableQuestion(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (isGlobal) {
                ref.read(globalVariablesProvider.notifier).deleteVariable(name);
              } else if (chatId != null) {
                ref
                    .read(localVariablesProvider(chatId!).notifier)
                    .deleteVariable(name);
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  void _confirmClearVariables(
      BuildContext context, WidgetRef ref, bool isGlobal) {
    final l10n = AppLocalizations.of(context);
    final scope = isGlobal ? l10n.global : l10n.local;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.clearVariables(scope)),
        content: Text(l10n.clearVariablesConfirmation(scope.toLowerCase())),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (isGlobal) {
                ref.read(globalVariablesProvider.notifier).clearAll();
              } else if (chatId != null) {
                ref.read(localVariablesProvider(chatId!).notifier).clearAll();
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l10n.clearAll),
          ),
        ],
      ),
    );
  }
}

/// Tile for displaying a variable
class _VariableTile extends StatelessWidget {
  final String name;
  final dynamic value;
  final bool isGlobal;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  const _VariableTile({
    required this.name,
    required this.value,
    required this.isGlobal,
    required this.onEdit,
    required this.onDelete,
    required this.onIncrement,
    required this.onDecrement,
  });

  String get _valueType {
    if (value == null) return 'null';
    if (value is int) return 'int';
    if (value is double) return 'double';
    if (value is bool) return 'bool';
    if (value is String) {
      final num = double.tryParse(value as String);
      if (num != null) return 'number';
      return 'string';
    }
    if (value is List) return 'array';
    if (value is Map) return 'object';
    return value.runtimeType.toString();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(
        isGlobal ? Icons.public : Icons.chat_bubble_outline,
        color: isGlobal ? AppTheme.accentColor : Colors.orange,
      ),
      title: Row(
        children: [
          Text(name),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.textMuted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _valueType,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.textMuted,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        value?.toString() ?? 'null',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: onDecrement,
            tooltip: l10n.decrement,
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: onIncrement,
            tooltip: l10n.increment,
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            onPressed: onEdit,
            tooltip: l10n.edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18, color: Colors.red),
            onPressed: onDelete,
            tooltip: l10n.delete,
          ),
        ],
      ),
      onTap: onEdit,
    );
  }
}

/// Widget for testing variable macros
class _VariableTestWidget extends ConsumerStatefulWidget {
  final String? chatId;

  const _VariableTestWidget({this.chatId});

  @override
  ConsumerState<_VariableTestWidget> createState() =>
      _VariableTestWidgetState();
}

class _VariableTestWidgetState extends ConsumerState<_VariableTestWidget> {
  final _inputController = TextEditingController();
  String? _result;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final service = ref.read(variablesServiceProvider);
    final result = await service.processVariableMacros(
      _inputController.text,
      chatId: widget.chatId,
    );
    setState(() {
      _result = result;
    });
    // Refresh providers to show any changes
    ref.read(globalVariablesProvider.notifier).refresh();
    if (widget.chatId != null) {
      ref.read(localVariablesProvider(widget.chatId!).notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _inputController,
            decoration: InputDecoration(
              labelText: l10n.testInput,
              hintText: l10n.variableTestHint,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _test,
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.processMacros),
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.accentColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check,
                          size: 16, color: AppTheme.accentColor),
                      const SizedBox(width: 8),
                      Text(
                        l10n.result,
                        style: const TextStyle(
                          color: AppTheme.accentColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.darkBackground,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _result!.isEmpty ? l10n.emptyString : _result!,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _result!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.copiedToClipboard)),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: Text(l10n.copy),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
