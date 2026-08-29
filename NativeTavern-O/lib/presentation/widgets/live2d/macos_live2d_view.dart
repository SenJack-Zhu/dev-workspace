import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_live2d/flutter_live2d.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class MacOSLive2DViewController extends ValueNotifier<Live2DViewState> {
  static const _channel = MethodChannel('native_tavern_live2d_macos');
  static final Map<String, Future<String>> _assetDirectories = {};

  int? _textureId;
  int? _textureWidth;
  int? _textureHeight;
  int _attachmentGeneration = 0;
  bool _isDisposed = false;
  Completer<void>? _attachedCompleter;

  MacOSLive2DViewController() : super(const Live2DViewState());

  Future<void> get whenAttached {
    if (_isDisposed) {
      return Future.error(
        Live2DException(
          'CONTROLLER_DISPOSED',
          'Controller has been disposed.',
        ),
      );
    }
    if (value.isAttached) return Future.value();
    return (_attachedCompleter ??= Completer<void>()).future;
  }

  void detach() {
    final textureId = _textureId;
    if (textureId == null) return;
    _textureId = null;
    _textureWidth = null;
    _textureHeight = null;
    unawaited(
      _channel.invokeMethod<void>(
          'disposeTexture', {'textureId': textureId}).catchError((_) {}),
    );
    final generation = ++_attachmentGeneration;
    scheduleMicrotask(() {
      if (_isDisposed ||
          _textureId != null ||
          generation != _attachmentGeneration) {
        return;
      }
      value = value.copyWith(
        lifecycle: Live2DLifecycle.detached,
        isLoadingModel: false,
        loadedModel: null,
        isRenderingPaused: false,
      );
    });
  }

  int get _id {
    if (_isDisposed) {
      throw Live2DException(
        'CONTROLLER_DISPOSED',
        'Controller has been disposed.',
      );
    }
    final id = _textureId;
    if (id == null) {
      throw Live2DException(
        'TEXTURE_NOT_ATTACHED',
        'The macOS Live2D texture is not attached.',
      );
    }
    return id;
  }

  Future<int> ensureTexture({
    required int width,
    required int height,
  }) async {
    if (_isDisposed) {
      throw Live2DException(
        'CONTROLLER_DISPOSED',
        'Controller has been disposed.',
      );
    }

    final currentId = _textureId;
    if (currentId != null) {
      if (_textureWidth != width || _textureHeight != height) {
        await _invoke('resizeTexture', {'width': width, 'height': height});
        _textureWidth = width;
        _textureHeight = height;
      }
      return currentId;
    }

    try {
      final textureId = await _wrap(() async {
        final id = await _channel.invokeMethod<int>('createTexture', {
          'width': width,
          'height': height,
        });
        if (id == null || id == 0) {
          throw Live2DException(
            'TEXTURE_CREATE_FAILED',
            'Native macOS did not return a valid texture id.',
          );
        }
        return id;
      });
      if (_isDisposed) {
        unawaited(
          _channel.invokeMethod<void>(
            'disposeTexture',
            {'textureId': textureId},
          ),
        );
        throw Live2DException(
          'CONTROLLER_DISPOSED',
          'Controller was disposed while creating the texture.',
        );
      }

      _attachmentGeneration++;
      _textureId = textureId;
      _textureWidth = width;
      _textureHeight = height;
      value = value.copyWith(
        lifecycle: Live2DLifecycle.attached,
        lastError: null,
      );
      final completer = _attachedCompleter;
      _attachedCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
      return textureId;
    } catch (error, stackTrace) {
      final completer = _attachedCompleter;
      _attachedCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<bool> loadModel({
    required String modelDir,
    required String modelFileName,
  }) async {
    value = value.copyWith(isLoadingModel: true, lastError: null);
    try {
      final resolvedDir = await _resolveModelDirectory(modelDir);
      final loaded = await _wrap(
        () async =>
            await _channel.invokeMethod<bool>('loadModel', {
              'textureId': _id,
              'modelDir': resolvedDir,
              'modelFileName': modelFileName,
            }) ??
            false,
      );
      value = value.copyWith(
        isLoadingModel: false,
        loadedModel: loaded
            ? Live2DLoadedModel(
                modelDir: resolvedDir,
                modelFileName: modelFileName,
              )
            : null,
        lastError: loaded
            ? null
            : Live2DException(
                'LOAD_FAILED',
                'Native macOS loadModel returned false for $modelFileName.',
              ),
      );
      return loaded;
    } catch (_) {
      value = value.copyWith(isLoadingModel: false);
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    await _invoke('unloadModel');
    value = value.copyWith(loadedModel: null, lastError: null);
  }

  Future<void> setRenderingPaused(bool paused) async {
    await _invoke('setRenderingPaused', {'paused': paused});
    value = value.copyWith(isRenderingPaused: paused);
  }

  Future<void> startMotion({
    required String group,
    int index = 0,
    int priority = 2,
  }) =>
      _invoke('startMotion', {
        'group': group,
        'index': index,
        'priority': priority,
      });

  Future<void> setExpression(int index) =>
      _invoke('setExpression', {'index': index});

  Future<void> setParameter(String parameterId, double parameterValue) =>
      _invoke('setParameter', {
        'parameterId': parameterId,
        'value': parameterValue,
      });

  Future<void> setMotionSpeed(double speed) =>
      _invoke('setMotionSpeed', {'speed': speed});

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) {
    return _wrap(() async {
      await _channel.invokeMethod<void>(method, {
        'textureId': _id,
        ...?arguments,
      });
    });
  }

  Future<void> touchBegan(double x, double y) =>
      _invoke('touchBegan', {'x': x, 'y': y});

  Future<void> touchMoved(double x, double y) =>
      _invoke('touchMoved', {'x': x, 'y': y});

  Future<void> touchEnded(double x, double y) =>
      _invoke('touchEnded', {'x': x, 'y': y});

  Future<T> _wrap<T>(Future<T> Function() body) async {
    try {
      final result = await body();
      if (value.lastError != null) value = value.copyWith(lastError: null);
      return result;
    } on Live2DException catch (error) {
      value = value.copyWith(lastError: error);
      rethrow;
    } on PlatformException catch (error) {
      final mapped = Live2DException(
        error.code,
        error.message ?? 'Native macOS Live2D error',
        details: error.details,
      );
      value = value.copyWith(lastError: mapped);
      throw mapped;
    } catch (error) {
      final mapped = Live2DException('UNKNOWN', error.toString());
      value = value.copyWith(lastError: mapped);
      throw mapped;
    }
  }

  Future<String> _resolveModelDirectory(String modelDirectory) async {
    final trimmed = modelDirectory.trim();
    if (trimmed.isEmpty) {
      throw Live2DException('INVALID_ARGS', 'modelDir must not be empty.');
    }
    if (p.isAbsolute(trimmed) || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed)) {
      return _withTrailingSeparator(trimmed);
    }
    final cached = _assetDirectories[trimmed];
    if (cached != null) return cached;

    final extraction = _extractAssetDirectory(trimmed);
    _assetDirectories[trimmed] = extraction;
    try {
      return await extraction;
    } catch (_) {
      if (identical(_assetDirectories[trimmed], extraction)) {
        _assetDirectories.remove(trimmed);
      }
      rethrow;
    }
  }

  Future<String> _extractAssetDirectory(String assetDirectory) async {
    final normalized =
        assetDirectory.endsWith('/') ? assetDirectory : '$assetDirectory/';
    final tempDirectory = await getTemporaryDirectory();
    final key = base64UrlEncode(utf8.encode(normalized)).replaceAll('=', '');
    final outputDirectory = Directory(
      p.join(tempDirectory.path, 'native_tavern_live2d_models', key),
    );
    final marker = File(p.join(outputDirectory.path, '.ready'));
    if (outputDirectory.existsSync() && marker.existsSync()) {
      return _withTrailingSeparator(outputDirectory.path);
    }

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((asset) => asset.startsWith(normalized))
        .where((asset) {
      final relativePath = asset.substring(normalized.length);
      final segments = p.posix.split(relativePath);
      return !segments.any(
        (segment) => segment.startsWith('.') || segment == '__MACOSX',
      );
    }).toList();
    if (assets.isEmpty) {
      throw Live2DException(
        'INVALID_ARGS',
        'No bundled Live2D assets were found under "$assetDirectory".',
      );
    }

    if (outputDirectory.existsSync()) {
      await outputDirectory.delete(recursive: true);
    }
    await outputDirectory.create(recursive: true);
    for (final asset in assets) {
      final relativePath = asset.substring(normalized.length);
      if (relativePath.isEmpty) continue;
      final output = File(p.join(outputDirectory.path, relativePath));
      await output.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await output.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    await marker.writeAsString('ok', flush: true);
    return _withTrailingSeparator(outputDirectory.path);
  }

  String _withTrailingSeparator(String path) =>
      path.endsWith(p.separator) ? path : '$path${p.separator}';

  @override
  void dispose() {
    if (_isDisposed) return;
    final textureId = _textureId;
    _textureId = null;
    _textureWidth = null;
    _textureHeight = null;
    _isDisposed = true;
    _attachmentGeneration++;
    if (textureId != null) {
      unawaited(
        _channel.invokeMethod<void>(
            'disposeTexture', {'textureId': textureId}).catchError((_) {}),
      );
    }
    final completer = _attachedCompleter;
    _attachedCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        Live2DException(
          'CONTROLLER_DISPOSED',
          'Controller was disposed before attaching.',
        ),
      );
    }
    super.dispose();
  }
}

class MacOSLive2DView extends StatefulWidget {
  final MacOSLive2DViewController controller;

  const MacOSLive2DView({
    super.key,
    required this.controller,
  });

  @override
  State<MacOSLive2DView> createState() => _MacOSLive2DViewState();
}

class _MacOSLive2DViewState extends State<MacOSLive2DView> {
  static const double _maxTextureDimension = 2048;

  int? _textureId;
  Size? _logicalSize;
  Size? _pixelSize;
  ({int width, int height})? _pendingSize;
  ({int width, int height})? _appliedSize;
  bool _processingSize = false;

  void _queueTextureSize(Size logicalSize, double devicePixelRatio) {
    if (logicalSize.isEmpty || !logicalSize.isFinite) return;
    var width = math.max(1, (logicalSize.width * devicePixelRatio).ceil());
    var height = math.max(1, (logicalSize.height * devicePixelRatio).ceil());
    final longestSide = math.max(width, height);
    if (longestSide > _maxTextureDimension) {
      final scale = _maxTextureDimension / longestSide;
      width = math.max(1, (width * scale).round());
      height = math.max(1, (height * scale).round());
    }

    _logicalSize = logicalSize;
    _pixelSize = Size(width.toDouble(), height.toDouble());
    final request = (width: width, height: height);
    if (_appliedSize == request || _pendingSize == request) return;
    _pendingSize = request;
    if (_processingSize) return;
    _processingSize = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _processTextureSizes());
  }

  Future<void> _processTextureSizes() async {
    while (mounted) {
      final request = _pendingSize;
      _pendingSize = null;
      if (request == null) break;
      try {
        final textureId = await widget.controller.ensureTexture(
          width: request.width,
          height: request.height,
        );
        if (!mounted) return;
        _appliedSize = request;
        if (_textureId != textureId) {
          setState(() => _textureId = textureId);
        }
      } catch (_) {
        if (!mounted) return;
        break;
      }
    }
    _processingSize = false;
    if (mounted && _pendingSize != null) {
      _processingSize = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _processTextureSizes());
    }
  }

  Offset _toTextureCoordinates(Offset localPosition) {
    final logicalSize = _logicalSize;
    final pixelSize = _pixelSize;
    if (logicalSize == null || pixelSize == null || logicalSize.isEmpty) {
      return Offset.zero;
    }
    return Offset(
      localPosition.dx * pixelSize.width / logicalSize.width,
      localPosition.dy * pixelSize.height / logicalSize.height,
    );
  }

  void _sendPointer(
    Future<void> Function(double x, double y) callback,
    Offset localPosition,
  ) {
    final point = _toTextureCoordinates(localPosition);
    unawaited(callback(point.dx, point.dy).catchError((_) {}));
  }

  @override
  void dispose() {
    widget.controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _queueTextureSize(size, View.of(context).devicePixelRatio);
        final textureId = _textureId;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _sendPointer(
            widget.controller.touchBegan,
            event.localPosition,
          ),
          onPointerMove: (event) => _sendPointer(
            widget.controller.touchMoved,
            event.localPosition,
          ),
          onPointerUp: (event) => _sendPointer(
            widget.controller.touchEnded,
            event.localPosition,
          ),
          onPointerCancel: (event) => _sendPointer(
            widget.controller.touchEnded,
            event.localPosition,
          ),
          child: textureId == null
              ? const SizedBox.expand()
              : Texture(
                  textureId: textureId,
                  filterQuality: FilterQuality.medium,
                ),
        );
      },
    );
  }
}
