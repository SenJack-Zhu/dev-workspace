import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/group_repository.dart';
import 'package:native_tavern/data/repositories/persona_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/storage_governance_service.dart';
import 'package:native_tavern/presentation/providers/data_bank_providers.dart';
import 'package:path_provider/path_provider.dart';

final storageReferenceSourceProvider = Provider<StorageReferenceSource>((ref) {
  return RepositoryStorageReferenceSource(
    characters: ref.watch(characterRepositoryProvider),
    chats: ref.watch(chatRepositoryProvider),
    groups: ref.watch(groupRepositoryProvider),
    personas: ref.watch(personaRepositoryProvider),
    dataBank: ref.watch(dataBankRepositoryProvider),
  );
});

final storageGovernanceServiceProvider =
    FutureProvider<StorageGovernanceOperations>((ref) async {
  final cacheRoots = <Directory>[];
  final temporaryRoots = <Directory>[];
  try {
    cacheRoots.add(await getApplicationCacheDirectory());
  } on MissingPlatformDirectoryException {
    // Managed in-data caches are still included when no platform cache exists.
  }
  try {
    temporaryRoots.add(await getTemporaryDirectory());
  } on MissingPlatformDirectoryException {
    // Managed audio remains available when no platform temp directory exists.
  }
  return StorageGovernanceService(
    dataRoot: Directory(ref.watch(dataPathProvider)),
    cacheRoots: cacheRoots,
    temporaryRoots: temporaryRoots,
    referenceSource: ref.watch(storageReferenceSourceProvider),
  );
});

final storageSnapshotProvider = FutureProvider<StorageSnapshot>((ref) async {
  final service = await ref.watch(storageGovernanceServiceProvider.future);
  return service.scan();
});

final class RepositoryStorageReferenceSource implements StorageReferenceSource {
  final CharacterRepository characters;
  final ChatRepository chats;
  final GroupRepository groups;
  final PersonaRepository personas;
  final DataBankRepository dataBank;

  const RepositoryStorageReferenceSource({
    required this.characters,
    required this.chats,
    required this.groups,
    required this.personas,
    required this.dataBank,
  });

  @override
  Future<StorageReferenceSet> loadReferences() async {
    final characterList = await characters.getAllCharacters();
    final chatList = await chats.getAllChats();
    final messagesByChat =
        await Future.wait(chatList.map((chat) => chats.getMessages(chat.id)));
    final groupList = await groups.getAllGroups();
    final personaList = await personas.getAllPersonas();
    final documentList = await dataBank.listDocuments();
    final filePaths = <String>{};

    for (final character in characterList) {
      final assets = character.assets;
      _addPath(filePaths, assets?.avatarPath);
      for (final expressionPath
          in assets?.expressionPack?.values ?? const <String>[]) {
        _addPath(filePaths, expressionPath);
      }
      final live2d = assets?.live2d;
      if (live2d?.source == Live2DModelSource.appData) {
        _addPath(filePaths, live2d?.modelDirectory);
      }
    }
    for (final group in groupList) {
      _addPath(filePaths, group.avatarPath);
    }
    for (final persona in personaList) {
      _addPath(filePaths, persona.avatarPath);
    }
    for (final messages in messagesByChat) {
      for (final message in messages) {
        for (final attachment in message.attachments) {
          _addPath(filePaths, attachment.path);
        }
      }
    }

    return StorageReferenceSet(
      filePaths: filePaths,
      dataBankDocumentIds: {
        for (final document in documentList) document.id,
      },
    );
  }
}

void _addPath(Set<String> paths, String? value) {
  if (value != null && value.trim().isNotEmpty) paths.add(value);
}
