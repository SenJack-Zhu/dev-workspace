import 'dart:math';

import 'package:native_tavern/domain/services/tokenizer_service.dart';

class ContextWindowFit {
  const ContextWindowFit({
    required this.messages,
    required this.estimatedTokens,
    required this.inputBudget,
    required this.removedMessages,
    required this.truncatedMessages,
  });

  final List<Map<String, dynamic>> messages;
  final int estimatedTokens;
  final int inputBudget;
  final int removedMessages;
  final int truncatedMessages;
}

/// Last-resort context fitting used after higher-quality summarization.
class ContextWindowService {
  ContextWindowService({TokenizerService? tokenizer})
      : _tokenizer = tokenizer ?? TokenizerService();

  final TokenizerService _tokenizer;

  int effectiveResponseTokenLimit({
    required int contextLength,
    required int requestedTokens,
  }) {
    if (contextLength <= 0) return max(1, requestedTokens);
    final maximum = max(1, contextLength ~/ 2);
    return min(max(1, requestedTokens), maximum);
  }

  ContextWindowFit fit(
    List<Map<String, dynamic>> messages, {
    required int contextLength,
    required int responseTokens,
  }) {
    if (messages.isEmpty || contextLength <= 0) {
      return ContextWindowFit(
        messages: messages,
        estimatedTokens: _estimateMessages(messages),
        inputBudget: contextLength,
        removedMessages: 0,
        truncatedMessages: 0,
      );
    }

    final availableForInput = max(1, contextLength - responseTokens);
    final safetyMargin = min(
      max(32, (contextLength * 0.05).ceil()),
      max(0, availableForInput - 1),
    );
    final inputBudget = max(1, availableForInput - safetyMargin);
    final working =
        messages.map((message) => Map<String, dynamic>.from(message)).toList();
    var estimated = _estimateMessages(working);
    if (estimated <= inputBudget) {
      return ContextWindowFit(
        messages: working,
        estimatedTokens: estimated,
        inputBudget: inputBudget,
        removedMessages: 0,
        truncatedMessages: 0,
      );
    }

    var removed = 0;
    var truncated = 0;
    Map<String, dynamic>? primarySystem;
    for (final message in working) {
      if (message['role'] == 'system') {
        primarySystem = message;
        break;
      }
    }

    // Retain the primary system prompt and the four newest turns first.
    var index = 0;
    while (estimated > inputBudget &&
        working.length > 5 &&
        index < working.length - 4) {
      final isPrimarySystem = identical(working[index], primarySystem);
      if (isPrimarySystem) {
        index++;
        continue;
      }
      estimated -= _estimateMessage(working.removeAt(index));
      removed++;
    }

    // If large prompt sections still overflow, keep only the primary system
    // prompt and the newest message before truncating their text.
    index = 0;
    while (estimated > inputBudget &&
        working.length > 2 &&
        index < working.length - 1) {
      final isPrimarySystem = identical(working[index], primarySystem);
      if (isPrimarySystem) {
        index++;
        continue;
      }
      estimated -= _estimateMessage(working.removeAt(index));
      removed++;
    }

    while (estimated > inputBudget) {
      final candidate = _largestTruncatableMessage(working);
      if (candidate == null) break;
      final oldTokens = _estimateMessage(working[candidate]);
      final content = working[candidate]['content'] as String;
      final contentTokens = _tokenizer.estimateTokenCount(content);
      const truncationMarkerAllowance = 8;
      final reduction = min(
        estimated - inputBudget + truncationMarkerAllowance,
        max(1, contentTokens - 8),
      );
      final targetTokens = max(8, contentTokens - reduction);
      final targetCharacters = max(
        1,
        (targetTokens * TokenizerService.charsPerTokenRatio).floor(),
      );
      final role = working[candidate]['role'];
      working[candidate]['content'] = role == 'system'
          ? '${content.substring(0, min(content.length, targetCharacters))}\n[truncated]'
          : '[truncated]\n${content.substring(max(0, content.length - targetCharacters))}';
      final newTokens = _estimateMessage(working[candidate]);
      if (newTokens >= oldTokens) break;
      estimated += newTokens - oldTokens;
      truncated++;
    }

    return ContextWindowFit(
      messages: working,
      estimatedTokens: estimated,
      inputBudget: inputBudget,
      removedMessages: removed,
      truncatedMessages: truncated,
    );
  }

  int? _largestTruncatableMessage(List<Map<String, dynamic>> messages) {
    int? result;
    var largest = 8;
    for (var index = 0; index < messages.length; index++) {
      final content = messages[index]['content'];
      if (content is! String) continue;
      final tokens = _tokenizer.estimateTokenCount(content);
      if (tokens > largest) {
        largest = tokens;
        result = index;
      }
    }
    return result;
  }

  int _estimateMessages(List<Map<String, dynamic>> messages) =>
      messages.fold(0, (total, message) => total + _estimateMessage(message));

  int _estimateMessage(Map<String, dynamic> message) {
    final content = message['content'];
    var tokens = 4;
    if (content is String) {
      tokens += _tokenizer.estimateTokenCount(content);
    } else if (content is List) {
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          tokens += _tokenizer.estimateTokenCount(part['text'] as String);
        } else {
          tokens += 1024;
        }
      }
    } else if (content != null) {
      tokens += _tokenizer.estimateTokenCount(content.toString());
    }
    return tokens;
  }
}
