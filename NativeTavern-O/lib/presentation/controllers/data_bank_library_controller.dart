import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_ingestion_service.dart';
import 'package:native_tavern/domain/services/data_bank_library_service.dart';

class DataBankLibraryController extends ChangeNotifier {
  final DataBankLibraryOperations operations;

  DataBankLibraryController(this.operations);

  List<DataBankLibraryEntry> _documents = const [];
  List<DataBankSearchResult> _searchResults = const [];
  bool _loading = false;
  bool _working = false;
  Object? _error;
  DataBankIngestionProgress? _progress;
  String _searchQuery = '';

  List<DataBankLibraryEntry> get documents => _documents;
  List<DataBankSearchResult> get searchResults => _searchResults;
  bool get loading => _loading;
  bool get working => _working;
  Object? get error => _error;
  DataBankIngestionProgress? get progress => _progress;
  String get searchQuery => _searchQuery;
  bool get showingSearch => _searchQuery.trim().isNotEmpty;

  double? get overallProgress {
    final current = _progress;
    if (current == null) return null;
    final phase = switch (current.phase) {
      DataBankIngestionPhase.staging => 0,
      DataBankIngestionPhase.parsing => 1,
      DataBankIngestionPhase.chunking => 2,
      DataBankIngestionPhase.completed => 3,
    };
    return ((phase + current.fraction) / 4).clamp(0, 1).toDouble();
  }

  Future<void> initialize() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await operations.recoverInterruptedImports();
      _documents = await operations.listDocuments();
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _documents = await operations.listDocuments();
      if (showingSearch) await _runSearch();
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> importDocument(File source) async {
    await _run(() async {
      await operations.importDocument(
        source,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
      );
    });
  }

  Future<void> retryDocument(String documentId) async {
    await _run(() async {
      await operations.retryDocument(
        documentId,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
      );
    });
  }

  Future<void> setDocumentEnabled(String documentId, bool enabled) {
    return _run(() => operations.setDocumentEnabled(documentId, enabled));
  }

  Future<void> rebuildSearchIndex() {
    return _run(operations.rebuildSearchIndex);
  }

  Future<void> search(String query) async {
    _searchQuery = query;
    _error = null;
    if (!showingSearch) {
      _searchResults = const [];
      notifyListeners();
      return;
    }
    _working = true;
    notifyListeners();
    try {
      await _runSearch();
    } catch (error) {
      _error = error;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> _runSearch() async {
    _searchResults = await operations.search(_searchQuery, topK: 50);
  }

  Future<DataBankDocumentPreview> previewDocument(String documentId) {
    return operations.previewDocument(documentId);
  }

  Future<DataBankDeletionPreview> previewDeletion(String documentId) {
    return operations.previewDeletion(documentId);
  }

  Future<void> deleteDocument(String documentId) {
    return _run(() => operations.deleteDocument(documentId));
  }

  Future<void> saveBinding({
    required String documentId,
    required DataBankBindingScope scope,
    String? targetId,
  }) {
    return _run(
      () => operations.saveBinding(
        documentId: documentId,
        scope: scope,
        targetId: targetId,
      ),
    );
  }

  Future<void> removeBinding(String bindingId) {
    return _run(() => operations.removeBinding(bindingId));
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working) return;
    _working = true;
    _error = null;
    _progress = null;
    notifyListeners();
    try {
      await operation();
      _documents = await operations.listDocuments();
      if (showingSearch) await _runSearch();
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _working = false;
      _progress = null;
      notifyListeners();
    }
  }
}
