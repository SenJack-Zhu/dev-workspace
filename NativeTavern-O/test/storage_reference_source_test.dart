import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as character_models;
import 'package:native_tavern/data/models/chat.dart' as chat_models;
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/data/repositories/persona_repository.dart';
import 'package:native_tavern/presentation/providers/storage_governance_providers.dart';

void main() {
  late AppDatabase database;
  late Directory dataRoot;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataRoot = Directory.systemTemp.createTempSync('storage_references_');
  });

  tearDown(() async {
    await database.close();
    dataRoot.deleteSync(recursive: true);
  });

  test('loads message attachments and Data Bank IDs from Drift', () async {
    final now = DateTime.utc(2026, 8, 8, 12);
    final characters = CharacterRepository(database, dataRoot.path);
    final chats = ChatRepository(database);
    final dataBank = DriftDataBankRepository(database);
    final attachmentPath = '${dataRoot.path}/attachments/message.jpg';
    await characters.createCharacter(
      character_models.Character(
        id: 'character-1',
        name: 'Reference owner',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    await chats.createChat(
      chat_models.Chat(
        id: 'chat-1',
        characterId: 'character-1',
        title: 'Storage references',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chats.addMessage(
      chat_models.ChatMessage(
        id: 'message-1',
        chatId: 'chat-1',
        role: chat_models.MessageRole.user,
        content: 'Attached image',
        timestamp: now,
        attachments: [
          chat_models.ChatAttachment(
            id: 'attachment-1',
            path: attachmentPath,
          ),
        ],
      ),
    );
    final version = DataBankDocumentVersion(
      id: 'version-1',
      documentId: 'document-1',
      versionNumber: 1,
      originalFileName: 'guide.md',
      mediaType: 'text/markdown',
      byteSize: 16,
      contentHash: DataBankContentHash(
        algorithm: DataBankHashAlgorithm.sha256,
        digest: 'a' * 64,
      ),
      importedAt: now,
    );
    await dataBank.saveVersion(version);
    await dataBank.saveDocument(
      DataBankDocument(
        id: 'document-1',
        currentVersionId: version.id,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final source = RepositoryStorageReferenceSource(
      characters: characters,
      chats: chats,
      groups: GroupRepository(database),
      personas: PersonaRepository(database),
      dataBank: dataBank,
    );

    final references = await source.loadReferences();

    expect(references.filePaths, contains(attachmentPath));
    expect(references.dataBankDocumentIds, {'document-1'});
  });
}
