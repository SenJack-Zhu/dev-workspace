import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/widgets/chat/data_bank_citation_preview.dart';

void main() {
  testWidgets('reply preview opens exact document and locator details',
      (tester) async {
    final locator = DataBankSourceLocator(
      documentVersionId: 'version-2',
      sectionId: 'section-2',
      chapter: 'Safe Harbor',
      pageStart: 7,
      startOffset: 320,
      endOffset: 390,
    );
    final chunk = DataBankTextChunk(
      id: 'chunk-2',
      documentVersionId: 'version-2',
      sectionId: 'section-2',
      ordinal: 0,
      text: 'Ships enter through the eastern channel.',
      locator: locator,
    );
    final snapshot = DataBankContextSnapshot(
      sessionId: 'session-2',
      originalQuery: 'eastern channel',
      queries: const ['eastern channel'],
      mode: DataBankRetrievalMode.semanticReranked,
      sources: [
        DataBankContextSource(
          label: 'D1',
          documentName: 'harbor-guide.pdf',
          snippet: 'eastern channel',
          injectedText: chunk.text,
          citation: chunk.toCitation('document-2'),
        ),
      ],
    );
    final message = ChatMessage(
      id: 'message-1',
      chatId: 'chat-1',
      role: MessageRole.assistant,
      content: 'Use the eastern channel.',
      timestamp: DateTime.utc(2026, 8, 8),
      swipes: const ['Use the eastern channel.'],
      metadata: appendDataBankContextMetadata(
        metadata: const {},
        existingSwipeCount: 0,
        snapshot: snapshot,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DataBankCitationPreview(message: message),
        ),
      ),
    );

    expect(find.text('1 Data Bank source'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-bank-citations-message-1')));
    await tester.pumpAndSettle();

    expect(find.text('[D1] harbor-guide.pdf'), findsOneWidget);
    expect(find.text('Safe Harbor | p. 7 | chars 320-390'), findsOneWidget);
    expect(find.text(chunk.text), findsOneWidget);
    expect(find.text('Hybrid semantic reranking'), findsOneWidget);
  });
}
