import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_tavern/domain/services/markdown_hotkey_service.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/presentation/widgets/common/adaptive_popup_menu.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';

/// A text input field with markdown formatting support
///
/// Features:
/// - Keyboard shortcuts for common markdown formatting
/// - Optional formatting toolbar
/// - Supports bold, italic, underline, strikethrough, code, links, quotes
class MarkdownInputField extends StatefulWidget {
  /// The text editing controller
  final TextEditingController controller;

  /// The focus node for the input field
  final FocusNode? focusNode;

  /// Hint text to display when empty
  final String? hintText;

  /// Maximum number of lines
  final int? maxLines;

  /// Minimum number of lines
  final int? minLines;

  /// Callback when the user submits (e.g., presses Enter)
  final ValueChanged<String>? onSubmitted;

  /// Text input action
  final TextInputAction? textInputAction;

  /// Whether to show the formatting toolbar
  final bool showToolbar;

  /// Callback when text changes
  final ValueChanged<String>? onChanged;

  /// Input decoration
  final InputDecoration? decoration;

  const MarkdownInputField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.maxLines,
    this.minLines,
    this.onSubmitted,
    this.textInputAction,
    this.showToolbar = false,
    this.onChanged,
    this.decoration,
  });

  @override
  State<MarkdownInputField> createState() => _MarkdownInputFieldState();
}

class _MarkdownInputFieldState extends State<MarkdownInputField> {
  late FocusNode _focusNode;
  bool _showToolbar = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChange);
    }
    super.dispose();
  }

  void _onFocusChange() {
    if (widget.showToolbar) {
      setState(() {
        _showToolbar = _focusNode.hasFocus;
      });
    }
  }

  void _applyFormat(MarkdownFormat format) {
    // Ensure we have a valid selection before applying format
    // If the text field has never been focused, selection might be invalid (offset -1)
    var currentValue = widget.controller.value;
    if (!currentValue.selection.isValid) {
      // Set selection to end of text
      currentValue = currentValue.copyWith(
        selection: TextSelection.collapsed(offset: currentValue.text.length),
      );
      widget.controller.value = currentValue;
    }

    final newValue = MarkdownHotkeyService.applyFormat(
      value: currentValue,
      format: format,
    );
    widget.controller.value = newValue;
    _focusNode.requestFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final format = MarkdownHotkeyService.getFormatFromKeyEvent(event);
    if (format != null) {
      _applyFormat(format);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Formatting toolbar
        if (widget.showToolbar && _showToolbar)
          _MarkdownToolbar(
            onFormat: _applyFormat,
          ),
        // Text field with key handler
        Focus(
          onKeyEvent: _handleKeyEvent,
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            maxLines: widget.maxLines,
            minLines: widget.minLines,
            decoration: widget.decoration ??
                InputDecoration(
                  hintText: widget.hintText,
                  filled: true,
                  fillColor: AppTheme.darkBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
            onSubmitted: widget.onSubmitted,
            textInputAction: widget.textInputAction,
            onChanged: widget.onChanged,
          ),
        ),
      ],
    );
  }
}

/// Toolbar with markdown formatting buttons
class _MarkdownToolbar extends StatelessWidget {
  final void Function(MarkdownFormat) onFormat;

  const _MarkdownToolbar({required this.onFormat});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.darkDivider),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarButton(
              format: MarkdownFormat.bold,
              onTap: () => onFormat(MarkdownFormat.bold),
            ),
            _ToolbarButton(
              format: MarkdownFormat.italic,
              onTap: () => onFormat(MarkdownFormat.italic),
            ),
            _ToolbarButton(
              format: MarkdownFormat.underline,
              onTap: () => onFormat(MarkdownFormat.underline),
            ),
            _ToolbarButton(
              format: MarkdownFormat.strikethrough,
              onTap: () => onFormat(MarkdownFormat.strikethrough),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.inlineCode,
              onTap: () => onFormat(MarkdownFormat.inlineCode),
            ),
            _ToolbarButton(
              format: MarkdownFormat.codeBlock,
              onTap: () => onFormat(MarkdownFormat.codeBlock),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.link,
              onTap: () => onFormat(MarkdownFormat.link),
            ),
            _ToolbarButton(
              format: MarkdownFormat.quote,
              onTap: () => onFormat(MarkdownFormat.quote),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.bulletList,
              onTap: () => onFormat(MarkdownFormat.bulletList),
            ),
            _ToolbarButton(
              format: MarkdownFormat.numberedList,
              onTap: () => onFormat(MarkdownFormat.numberedList),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final MarkdownFormat format;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.format,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          '${_markdownFormatName(format, AppLocalizations.of(context))}${format.shortcutHint != null ? ' (${format.shortcutHint})' : ''}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            format.icon,
            size: 18,
            color: AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: AppTheme.darkDivider,
    );
  }
}

/// A standalone markdown formatting toolbar that can be used with any TextField
class MarkdownToolbar extends StatelessWidget {
  /// The text editing controller to apply formatting to
  final TextEditingController controller;

  /// Focus node to return focus to after formatting
  final FocusNode? focusNode;

  /// Whether to show the toolbar in a compact mode
  final bool compact;

  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.compact = false,
  });

  void _applyFormat(MarkdownFormat format) {
    // Ensure we have a valid selection before applying format
    // If the text field has never been focused, selection might be invalid (offset -1)
    var currentValue = controller.value;
    if (!currentValue.selection.isValid) {
      // Set selection to end of text
      currentValue = currentValue.copyWith(
        selection: TextSelection.collapsed(offset: currentValue.text.length),
      );
      controller.value = currentValue;
    }

    final newValue = MarkdownHotkeyService.applyFormat(
      value: currentValue,
      format: format,
    );
    controller.value = newValue;
    focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return _buildCompactToolbar(context);
    }
    return _buildFullToolbar();
  }

  Widget _buildFullToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.darkDivider),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarButton(
              format: MarkdownFormat.bold,
              onTap: () => _applyFormat(MarkdownFormat.bold),
            ),
            _ToolbarButton(
              format: MarkdownFormat.italic,
              onTap: () => _applyFormat(MarkdownFormat.italic),
            ),
            _ToolbarButton(
              format: MarkdownFormat.underline,
              onTap: () => _applyFormat(MarkdownFormat.underline),
            ),
            _ToolbarButton(
              format: MarkdownFormat.strikethrough,
              onTap: () => _applyFormat(MarkdownFormat.strikethrough),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.inlineCode,
              onTap: () => _applyFormat(MarkdownFormat.inlineCode),
            ),
            _ToolbarButton(
              format: MarkdownFormat.codeBlock,
              onTap: () => _applyFormat(MarkdownFormat.codeBlock),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.link,
              onTap: () => _applyFormat(MarkdownFormat.link),
            ),
            _ToolbarButton(
              format: MarkdownFormat.quote,
              onTap: () => _applyFormat(MarkdownFormat.quote),
            ),
            _ToolbarDivider(),
            _ToolbarButton(
              format: MarkdownFormat.bulletList,
              onTap: () => _applyFormat(MarkdownFormat.bulletList),
            ),
            _ToolbarButton(
              format: MarkdownFormat.numberedList,
              onTap: () => _applyFormat(MarkdownFormat.numberedList),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactToolbar(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CompactToolbarButton(
          icon: Icons.format_bold,
          tooltip: '${l10n.bold} (⌘B)',
          onTap: () => _applyFormat(MarkdownFormat.bold),
        ),
        _CompactToolbarButton(
          icon: Icons.format_italic,
          tooltip: '${l10n.italic} (⌘I)',
          onTap: () => _applyFormat(MarkdownFormat.italic),
        ),
        _CompactToolbarButton(
          icon: Icons.code,
          tooltip: '${l10n.inlineCode} (⌘`)',
          onTap: () => _applyFormat(MarkdownFormat.inlineCode),
        ),
        AdaptivePopupMenuButton<MarkdownFormat>(
          icon: Icon(
            Icons.more_horiz,
            size: 18,
            color: AppTheme.textMuted,
          ),
          tooltip: l10n.moreFormatting,
          onSelected: _applyFormat,
          itemBuilder: (context) => [
            _buildMenuItem(MarkdownFormat.underline, l10n),
            _buildMenuItem(MarkdownFormat.strikethrough, l10n),
            const PopupMenuDivider(),
            _buildMenuItem(MarkdownFormat.codeBlock, l10n),
            _buildMenuItem(MarkdownFormat.link, l10n),
            _buildMenuItem(MarkdownFormat.quote, l10n),
            const PopupMenuDivider(),
            _buildMenuItem(MarkdownFormat.bulletList, l10n),
            _buildMenuItem(MarkdownFormat.numberedList, l10n),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<MarkdownFormat> _buildMenuItem(
    MarkdownFormat format,
    AppLocalizations l10n,
  ) {
    return PopupMenuItem<MarkdownFormat>(
      value: format,
      child: Row(
        children: [
          Icon(format.icon, size: 18),
          const SizedBox(width: 12),
          Text(_markdownFormatName(format, l10n)),
          if (format.shortcutHint != null) ...[
            const Spacer(),
            Text(
              format.shortcutHint!,
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _markdownFormatName(
  MarkdownFormat format,
  AppLocalizations l10n,
) =>
    switch (format) {
      MarkdownFormat.bold => l10n.bold,
      MarkdownFormat.italic => l10n.italic,
      MarkdownFormat.underline => l10n.underline,
      MarkdownFormat.strikethrough => l10n.strikethrough,
      MarkdownFormat.inlineCode => l10n.inlineCode,
      MarkdownFormat.codeBlock => l10n.codeBlock,
      MarkdownFormat.link => l10n.link,
      MarkdownFormat.quote => l10n.quote,
      MarkdownFormat.heading1 => l10n.heading1,
      MarkdownFormat.heading2 => l10n.heading2,
      MarkdownFormat.heading3 => l10n.heading3,
      MarkdownFormat.bulletList => l10n.bulletList,
      MarkdownFormat.numberedList => l10n.numberedList,
      MarkdownFormat.horizontalRule => l10n.horizontalRule,
    };

class _CompactToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CompactToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color: AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}
