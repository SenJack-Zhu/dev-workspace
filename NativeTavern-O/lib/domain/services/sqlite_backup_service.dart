import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:native_tavern/core/utils/path_utils.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:intl/intl.dart';

/// Service for SQLite-based database backup and restore
/// This is more reliable than JSON-based backup as it preserves all data types and relationships
/// Backups now include media directories (chat_images, avatars, backgrounds, sprites, attachments, moments)
class SqliteBackupService {
  static SqliteBackupService? _instance;
  static SqliteBackupService get instance => _instance ??= SqliteBackupService._();
  
  SqliteBackupService._();
  
  /// Media directories to include in backup (relative to dataPath)
  static const List<String> _mediaDirectories = [
    'chat_images',
    'avatars',
    'backgrounds',
    'sprites',
    'attachments',
    'moments',
    'database_assets',
  ];
  
  /// Get the database file path (uses PathUtils for correct data location)
  Future<File> getDatabaseFile() async {
    final dataFolder = await PathUtils.getDataPath();
    return File(p.join(dataFolder, 'database.sqlite'));
  }
  
  /// Get WAL and SHM files (SQLite journal files)
  Future<List<File>> getJournalFiles() async {
    final dbFile = await getDatabaseFile();
    final walFile = File('${dbFile.path}-wal');
    final shmFile = File('${dbFile.path}-shm');
    
    final files = <File>[];
    if (await walFile.exists()) files.add(walFile);
    if (await shmFile.exists()) files.add(shmFile);
    return files;
  }
  
  /// Recursively list all files within a directory (relative paths for archive)
  Future<List<(File file, String archivePath)>> _listMediaFiles(
    Directory mediaDir,
    String archivePrefix,
  ) async {
    final result = <(File, String)>[];
    if (!await mediaDir.exists()) return result;
    
    await for (final entity in mediaDir.list(recursive: true)) {
      if (entity is File) {
        final relative = p.relative(entity.path, from: mediaDir.parent.path);
        final archiveEntry = archivePrefix.isEmpty
            ? relative
            : p.join(archivePrefix, relative);
        result.add((entity, archiveEntry));
      }
    }
    return result;
  }
  
  /// Create a backup of the SQLite database + all media directories
  /// Returns a zip file (.ntbackup) containing db, journals, metadata, and media files
  Future<File> createBackup({String? customName}) async {
    final dbFile = await getDatabaseFile();
    if (!await dbFile.exists()) {
      throw Exception('Database file not found');
    }
    
    // Create backup directory in temp
    final cacheDir = await getTemporaryDirectory();
    final backupDir = Directory(p.join(cacheDir.path, 'backups'));
    await backupDir.create(recursive: true);
    
    // Generate backup filename
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final backupName = customName ?? 'NativeTavern_backup_$timestamp';
    final backupFile = File(p.join(backupDir.path, '$backupName.ntbackup'));
    
    debugPrint('[SqliteBackup] Creating backup: ${backupFile.path}');
    
    // Read database file
    final dbBytes = await dbFile.readAsBytes();
    
    // Create archive
    final archive = Archive();
    
    // Add database file (at root for easy access)
    archive.addFile(ArchiveFile('database.sqlite', dbBytes.length, dbBytes));
    
    // Add WAL and SHM files if they exist
    final journalFiles = await getJournalFiles();
    for (final jFile in journalFiles) {
      final bytes = await jFile.readAsBytes();
      final name = p.basename(jFile.path);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
      debugPrint('[SqliteBackup] Added journal file: $name');
    }
    
    // Add all media directories (chat_images, avatars, backgrounds, sprites, attachments, moments...)
    final dataPath = await PathUtils.getDataPath();
    int mediaFilesAdded = 0;
    for (final dirName in _mediaDirectories) {
      final mediaDir = Directory(p.join(dataPath, dirName));
      final files = await _listMediaFiles(mediaDir, dirName);
      for (final (file, archivePath) in files) {
        try {
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile(archivePath, bytes.length, bytes));
          mediaFilesAdded++;
        } catch (e) {
          debugPrint('[SqliteBackup] Skipped media file $archivePath: $e');
        }
      }
    }
    debugPrint('[SqliteBackup] Added $mediaFilesAdded media files from data directory');
    
    // Add metadata
    final metadata = {
      'version': 2, // bumped: v2 includes media files
      'created_at': DateTime.now().toIso8601String(),
      'app_version': '1.0.0',
      'schema_version': 12,
      'includes_media': true,
      'media_count': mediaFilesAdded,
      'media_directories': _mediaDirectories,
    };
    final metadataJson = metadata.toString();
    archive.addFile(ArchiveFile('metadata.json', metadataJson.length, metadataJson.codeUnits));
    
    // Encode and write
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Failed to create backup archive');
    }
    
    await backupFile.writeAsBytes(zipBytes);
    debugPrint('[SqliteBackup] Backup created: ${backupFile.path} (${zipBytes.length} bytes, media: $mediaFilesAdded files)');
    
    return backupFile;
  }
  
  /// Restore database + media files from a backup file
  /// Mode: 'replace' = completely replace current database + media
  ///       'merge' = merge (NOT implemented yet)
  Future<void> restoreBackup({
    required File backupFile,
    String mode = 'replace',
  }) async {
    debugPrint('[SqliteBackup] Restoring from: ${backupFile.path}');
    
    // Read and decode archive
    final bytes = await backupFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    
    // Read metadata if present
    bool backupIncludesMedia = false;
    int? backupVersion;
    for (final file in archive) {
      if (file.name == 'metadata.json') {
        try {
          final metaStr = String.fromCharCodes(file.content as List<int>);
          debugPrint('[SqliteBackup] Backup metadata: $metaStr');
          backupIncludesMedia = metaStr.contains('includes_media: true') ||
              metaStr.contains('media_count');
          if (metaStr.contains('version:')) {
            final vMatch = RegExp(r'version:\s*(\d+)').firstMatch(metaStr);
            if (vMatch != null) backupVersion = int.tryParse(vMatch.group(1)!);
          }
        } catch (_) {}
        break;
      }
    }
    debugPrint('[SqliteBackup] Backup version=$backupVersion, includes_media=$backupIncludesMedia');
    
    // Extract database file
    ArchiveFile? dbArchiveFile;
    for (final file in archive) {
      if (file.name == 'database.sqlite') {
        dbArchiveFile = file;
        break;
      }
    }
    
    if (dbArchiveFile == null) {
      throw Exception('Invalid backup file: database.sqlite not found');
    }
    
    final dbFile = await getDatabaseFile();
    
    if (mode == 'replace') {
      // Create backup of current database before replacing
      final backupDir = dbFile.parent;
      final backupPath = p.join(backupDir.path, 'database_before_restore_${DateTime.now().millisecondsSinceEpoch}.sqlite');
      if (await dbFile.exists()) {
        await dbFile.copy(backupPath);
        debugPrint('[SqliteBackup] Current database backed up to: $backupPath');
      }
      
      // Delete journal files first
      final journalFiles = await getJournalFiles();
      for (final jFile in journalFiles) {
        await jFile.delete();
        debugPrint('[SqliteBackup] Deleted journal file: ${jFile.path}');
      }
      
      // Write new database file
      await dbFile.writeAsBytes(dbArchiveFile.content as List<int>);
      debugPrint('[SqliteBackup] Database restored');
      
      // Restore journal files if present in backup
      for (final file in archive) {
        if (file.name.endsWith('-wal') || file.name.endsWith('-shm')) {
          final jFile = File('${dbFile.path}${file.name.substring(file.name.lastIndexOf('-'))}');
          await jFile.writeAsBytes(file.content as List<int>);
          debugPrint('[SqliteBackup] Restored journal file: ${jFile.path}');
        }
      }
      
      // Restore media files if backup includes them (v2+)
      if (backupIncludesMedia || (backupVersion ?? 1) >= 2) {
        final dataPath = await PathUtils.getDataPath();
        int restoredMedia = 0;
        for (final file in archive) {
          // Skip root-level special files
          if (file.name == 'database.sqlite' ||
              file.name.endsWith('-wal') ||
              file.name.endsWith('-shm') ||
              file.name == 'metadata.json') {
            continue;
          }
          // Skip directories
          if (file.isFile == false) continue;
          
          try {
            final targetPath = p.join(dataPath, file.name);
            final targetFile = File(targetPath);
            await targetFile.parent.create(recursive: true);
            await targetFile.writeAsBytes(file.content as List<int>);
            restoredMedia++;
          } catch (e) {
            debugPrint('[SqliteBackup] Failed to restore media ${file.name}: $e');
          }
        }
        debugPrint('[SqliteBackup] Restored $restoredMedia media files');
      } else {
        debugPrint('[SqliteBackup] Backup is v1 (no media), skipping media restore');
      }
    } else {
      throw Exception('Merge mode not yet implemented. Please use replace mode.');
    }
  }
  
  /// Get backup file size
  int getBackupSize(File backupFile) {
    return backupFile.lengthSync();
  }
  
  /// Format file size for display
  String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
