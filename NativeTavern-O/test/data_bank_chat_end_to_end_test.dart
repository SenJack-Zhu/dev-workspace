// Test fixtures intentionally exercise real asynchronous file I/O.
// ignore_for_file: avoid_slow_async_io

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/chat.dart' as chat_models;
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/data_bank_context.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/presentation/providers/chat_extension_providers.dart';
import 'package:native_tavern/presentation/providers/chat_providers.dart';
import 'package:native_tavern/presentation/providers/data_bank_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/vector_storage_providers.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late Directory input;
  late AppDatabase database;
  late CharacterRepository characterRepository;
  late ChatRepository chatRepository;
  late DriftDataBankRepository dataBankRepository;
  late _RecordingLLMService llmService;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    temporary = Directory.systemTemp.createTempSync('nt_data_bank_chat_');
    input = Directory(path.join(temporary.path, 'input'))..createSync();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    characterRepository = CharacterRepository(database, temporary.path);
    chatRepository = ChatRepository(database);
    dataBankRepository = DriftDataBankRepository(database);
    llmService = _RecordingLLMService();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      dataPathProvider.overrideWithValue(temporary.path),
      characterRepositoryProvider.overrideWithValue(characterRepository),
      chatRepositoryProvider.overrideWithValue(chatRepository),
      dataBankRepositoryProvider.overrideWithValue(dataBankRepository),
      llmServiceProvider.overrideWithValue(llmService),
      sharedPreferencesProvider.overrideWithValue(preferences),
      ragContextProvider.overrideWithValue((_) async => null),
    ]);

    final now = DateTime.utc(2026, 8, 8, 12);
    await characterRepository.createCharacter(models.Character(
      id: 'character-1',
      name: 'Archivist',
      description: 'Answers with verifiable references.',
      createdAt: now,
      modifiedAt: now,
    ));
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test(
      'real imports, bindings, lifecycle, chat injection, and citations stay aligned',
      () async {
    final notifier = container.read(activeChatProvider.notifier);
    final chatId = await notifier.createChat('character-1');
    expect(chatId, isNotNull);
    final library = container.read(dataBankLibraryServiceProvider);

    final global = await library.importDocument(
      _writeDocument(
        input,
        'global.md',
        '# Global Route\nnavigation marker global route',
      ),
    );
    final character = await library.importDocument(
      _writeDocument(
        input,
        'character.md',
        '# Character Route\nnavigation marker character route',
      ),
    );
    await library.removeBinding(character.bindings.single.id);
    await library.saveBinding(
      documentId: character.document.id,
      scope: DataBankBindingScope.character,
      targetId: 'character-1',
    );
    final chat = await library.importDocument(
      _writeDocument(
        input,
        'chat.md',
        '# Chat Route\nnavigation marker chat route',
      ),
    );
    await library.removeBinding(chat.bindings.single.id);
    await library.saveBinding(
      documentId: chat.document.id,
      scope: DataBankBindingScope.chat,
      targetId: chatId,
    );

    await notifier.sendMessage('navigation marker', _config);

    expect(llmService.requests, hasLength(1));
    final firstPrompt = _joinedPrompt(llmService.requests.single);
    expect(firstPrompt, contains('global.md'));
    expect(firstPrompt, contains('character.md'));
    expect(firstPrompt, contains('chat.md'));
    final firstSaved = await chatRepository.getMessages(chatId!);
    final firstContext = dataBankContextForSwipe(
      firstSaved.last.metadata,
      firstSaved.last.currentSwipeIndex,
    );
    expect(firstContext, isNotNull);
    expect(
      firstContext!.sources.map((source) => source.citation.documentId).toSet(),
      {global.document.id, character.document.id, chat.document.id},
    );
    expect(
      firstContext.sources.every(
        (source) => source.citation.quote.contains('navigation marker'),
      ),
      isTrue,
    );
    final chatChunkId = firstContext.sources
        .singleWhere(
          (source) => source.citation.documentId == chat.document.id,
        )
        .citation
        .chunkId;

    final replacementId = '${global.version.id}-replacement';
    const replacementText = 'navigation marker revised global route';
    final replacement = DataBankDocumentVersion(
      id: replacementId,
      documentId: global.document.id,
      versionNumber: 2,
      supersedesVersionId: global.version.id,
      originalFileName: 'global-revised.md',
      mediaType: 'text/markdown',
      byteSize: replacementText.length,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: 'b' * 64,
      ),
      importedAt: global.document.createdAt.add(const Duration(hours: 1)),
      processingState: DataBankProcessingState.ready,
      indexState: DataBankIndexState.indexed,
    );
    await dataBankRepository.replaceCurrentVersion(
      documentId: global.document.id,
      expectedCurrentVersionId: global.version.id,
      replacement: replacement,
    );
    final replacementSectionId = '$replacementId-section';
    final replacementLocator = DataBankSourceLocator(
      documentVersionId: replacementId,
      sectionId: replacementSectionId,
      chapter: 'Revised Route',
      startOffset: 0,
      endOffset: replacementText.length,
    );
    await dataBankRepository.replaceSections(replacementId, [
      DataBankSection(
        id: replacementSectionId,
        documentVersionId: replacementId,
        kind: DataBankSectionKind.chapter,
        title: 'Revised Route',
        ordinal: 0,
        locator: replacementLocator,
      ),
    ]);
    await dataBankRepository.replaceChunks(replacementId, [
      DataBankTextChunk(
        id: '$replacementId-chunk',
        documentVersionId: replacementId,
        sectionId: replacementSectionId,
        ordinal: 0,
        text: replacementText,
        locator: replacementLocator,
      ),
    ]);
    await library.setDocumentEnabled(character.document.id, false);

    await notifier.sendMessage('navigation marker', _config);

    final secondContext =
        _latestContext(await chatRepository.getMessages(chatId));
    expect(
      secondContext.sources.map((source) => source.citation.documentId),
      isNot(contains(character.document.id)),
    );
    final revisedSource = secondContext.sources.singleWhere(
      (source) => source.citation.documentId == global.document.id,
    );
    expect(revisedSource.citation.documentVersionId, replacementId);
    expect(revisedSource.citation.quote, replacementText);
    expect(
      secondContext.sources.map((source) => source.citation.documentVersionId),
      isNot(contains(global.version.id)),
    );

    final chatManagedDirectory = Directory(
      path.join(temporary.path, 'data_bank', chat.document.id),
    );
    expect(chatManagedDirectory.existsSync(), isTrue);
    await library.deleteDocument(chat.document.id);
    expect(chatManagedDirectory.existsSync(), isFalse);

    await notifier.sendMessage('navigation marker', _config);

    final thirdContext =
        _latestContext(await chatRepository.getMessages(chatId));
    expect(thirdContext.sources, hasLength(1));
    expect(thirdContext.sources.single.citation.documentId, global.document.id);
    expect(await dataBankRepository.getDocument(chat.document.id), isNull);
    expect(await dataBankRepository.getChunk(chatChunkId), isNull);

    container.read(dataBankContextSettingsProvider.notifier).setEnabled(false);
    await notifier.sendMessage('navigation marker', _config);

    final assembly = container.read(lastContextAssemblyProvider);
    expect(assembly, isNotNull);
    final dataBankTrace = assembly!.traces.singleWhere(
      (trace) => trace.contributorId == 'data-bank.retrieval',
    );
    expect(dataBankTrace.status, ContextContributionStatus.disabled);
    expect(
      _joinedPrompt(llmService.requests.last),
      isNot(contains('Relevant Data Bank sources')),
    );
    final lastSaved = (await chatRepository.getMessages(chatId)).last;
    expect(
      dataBankContextForSwipe(lastSaved.metadata, lastSaved.currentSwipeIndex),
      isNull,
    );
  });
}

File _writeDocument(Directory input, String name, String contents) {
  return File(path.join(input.path, name))..writeAsStringSync(contents);
}

DataBankContextSnapshot _latestContext(
  List<chat_models.ChatMessage> messages,
) {
  final message = messages.last;
  return dataBankContextForSwipe(message.metadata, message.currentSwipeIndex)!;
}

String _joinedPrompt(List<ChatMessageMap> messages) {
  return messages
      .map((message) => message['content'])
      .whereType<String>()
      .join('\n');
}

const _config = LLMConfig(
  provider: LLMProvider.openAICompatible,
  model: 'test-model',
  apiKey: '',
  apiUrl: 'http://localhost',
  contextLength: 8192,
  maxTokens: 256,
  streamEnabled: false,
  autoSummarizeEnabled: false,
);

final class _RecordingLLMService extends LLMService {
  final List<List<ChatMessageMap>> requests = [];

  @override
  Future<LLMResponse> generateWithReasoning(
    List<Map<String, dynamic>> messages,
    LLMConfig config,
  ) async {
    requests.add(
      messages.map((message) => Map<String, dynamic>.from(message)).toList(),
    );
    return const LLMResponse(content: 'Answer from verified sources.');
  }
}
