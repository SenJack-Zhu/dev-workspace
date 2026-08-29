import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/vector_storage.dart';
import 'package:native_tavern/domain/services/embedding_service.dart';

void main() {
  group('EmbeddingService effectiveEndpoint', () {
    final service = EmbeddingService();

    test('adds /v1 to an OpenAI-compatible root URL', () {
      const settings = VectorStorageSettings(
        embeddingProvider: EmbeddingProvider.custom,
        embeddingEndpoint: ' https://embedding.example.com/ ',
      );

      expect(service.effectiveEndpoint(settings),
          'https://embedding.example.com/v1');
    });

    test('preserves a custom versioned path', () {
      const settings = VectorStorageSettings(
        embeddingProvider: EmbeddingProvider.custom,
        embeddingEndpoint: 'https://openrouter.ai/api/v1/',
      );

      expect(
          service.effectiveEndpoint(settings), 'https://openrouter.ai/api/v1');
    });

    test('accepts a full embeddings endpoint', () {
      const settings = VectorStorageSettings(
        embeddingProvider: EmbeddingProvider.openai,
        embeddingEndpoint: 'https://api.example.com/v1/embeddings',
      );

      expect(service.effectiveEndpoint(settings), 'https://api.example.com/v1');
    });
  });
}
