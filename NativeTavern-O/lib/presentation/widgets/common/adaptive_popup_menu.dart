import 'package:flutter/material.dart';

/// Keeps overflow actions anchored to their trigger on every platform.
///
/// Flutter 3.44.9 or newer is required because older releases could interpret
/// an iPadOS top-bar tap twice and immediately dismiss the opened menu.
class AdaptivePopupMenuButton<T> extends StatelessWidget {
  const AdaptivePopupMenuButton({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    this.icon,
    this.tooltip,
    this.padding = const EdgeInsets.all(8),
    this.iconSize,
    this.enabled = true,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;
  final Widget? icon;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final double? iconSize;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      icon: icon,
      tooltip: tooltip,
      padding: padding,
      iconSize: iconSize,
      enabled: enabled,
    );
  }
}
