part of 'live2d_character_view.dart';

class _SpineCharacterView extends StatefulWidget {
  final Live2DConfig config;
  final bool isSpeaking;
  final String responseText;
  final TTSPlaybackState? ttsPlayback;
  final Live2DCharacterController? controller;
  final Widget? fallback;
  final bool showStatus;
  final bool interactive;
  final bool resetOnDoubleTap;
  final VoidCallback? onReady;
  final ValueChanged<Live2DStageTransform>? onTransformChanged;

  const _SpineCharacterView({
    super.key,
    required this.config,
    required this.isSpeaking,
    required this.responseText,
    required this.ttsPlayback,
    required this.controller,
    required this.fallback,
    required this.showStatus,
    required this.interactive,
    required this.resetOnDoubleTap,
    required this.onReady,
    required this.onTransformChanged,
  });

  @override
  State<_SpineCharacterView> createState() => _SpineCharacterViewState();
}

class _SpineCharacterViewState extends State<_SpineCharacterView>
    with WidgetsBindingObserver {
  late final spine.SpineWidgetController _controller;
  late final Live2DRenderingLifecycle _renderingLifecycle;
  late Live2DActionOrchestrator _orchestrator;
  final Live2DTTSPlaybackCoordinator _ttsPlaybackCoordinator =
      Live2DTTSPlaybackCoordinator();
  final Live2DSentenceBoundaryTracker _sentenceTracker =
      Live2DSentenceBoundaryTracker();
  final EmotionDetectionService _emotionDetectionService =
      EmotionDetectionService();

  spine.SkeletonDrawable? _drawable;
  String? _loadError;
  String? _idleAnimation;
  int _loadGeneration = 0;
  bool _drawableOwnedByWidget = false;
  bool _isAttached = false;
  bool _isReady = false;
  double _stageScale = 1;
  double _offsetX = 0;
  double _offsetY = 0;
  Live2DStageTransform? _gestureStartTransform;
  Offset? _gestureStartFocalPoint;
  bool _transformDirty = false;
  Timer? _scrollSaveTimer;
  Future<void> _actionWrites = Future<void>.value();

  bool get isAttached => _isAttached;
  bool get isReady => _isReady;
  bool get isRenderingPaused => _renderingLifecycle.desiredPaused;

  @override
  void initState() {
    super.initState();
    _controller = spine.SpineWidgetController(
      onInitialized: _handleInitialized,
    );
    final appLifecycleState = WidgetsBinding.instance.lifecycleState;
    _renderingLifecycle = Live2DRenderingLifecycle(
      applyPaused: (paused) async {
        if (paused) {
          _controller.pause();
        } else {
          _controller.resume();
        }
      },
      initialPaused: appLifecycleState != null &&
          appLifecycleState != AppLifecycleState.resumed,
    );
    _orchestrator = _createOrchestrator();
    _applyConfigTransform(widget.config);
    _sentenceTracker.reset(text: widget.responseText);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadModel());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final isVisible = (route?.isCurrent ?? true) && TickerMode.of(context);
    unawaited(
      _renderingLifecycle.setViewVisible(isVisible).catchError((_) {}),
    );
  }

  @override
  void didUpdateWidget(_SpineCharacterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldConfig = oldWidget.config;
    final config = widget.config;
    if (oldConfig.scale != config.scale ||
        oldConfig.offsetX != config.offsetX ||
        oldConfig.offsetY != config.offsetY) {
      _applyConfigTransform(config);
    }
    if (oldConfig.motionSpeed != config.motionSpeed && _isReady) {
      _controller.animationState.setTimeScale(config.motionSpeed);
    }
    final playback = widget.ttsPlayback;
    if (playback != null) {
      if (oldWidget.ttsPlayback?.sequence != playback.sequence) {
        _handleTTSPlaybackChanged(oldWidget.ttsPlayback, playback);
      }
    } else if (oldWidget.isSpeaking != widget.isSpeaking) {
      _handleSpeakingChanged();
    } else if (widget.isSpeaking &&
        oldWidget.responseText != widget.responseText) {
      _handleResponseTextChanged();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(
      _renderingLifecycle
          .setAppActive(state == AppLifecycleState.resumed)
          .catchError((_) {}),
    );
  }

  Future<void> _loadModel() async {
    final generation = ++_loadGeneration;
    setState(() => _loadError = null);
    try {
      await SpineRuntimeService.ensureInitialized();
      final directory = await _resolveModelDirectory();
      final atlasFileName = widget.config.atlasFileName;
      if (atlasFileName == null || atlasFileName.isEmpty) {
        throw const FormatException(
            'The Spine model is missing its atlas file.');
      }
      final drawable = await spine.SkeletonDrawable.fromFile(
        '$directory/$atlasFileName',
        '$directory/${widget.config.modelFileName}',
      );
      if (!mounted || generation != _loadGeneration) {
        drawable.dispose();
        return;
      }
      setState(() => _drawable = drawable);
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadError = error.toString());
      }
    }
  }

  Future<String> _resolveModelDirectory() async {
    if (widget.config.source != Live2DModelSource.appData) {
      return widget.config.modelDirectory;
    }
    final dataPath = await PathUtils.getDataPath();
    return '$dataPath/${widget.config.modelDirectory}';
  }

  void _handleInitialized(spine.SpineWidgetController controller) {
    if (!mounted) return;
    _isAttached = true;
    _isReady = true;
    controller.animationState.setTimeScale(widget.config.motionSpeed);
    final animations = controller.skeletonData.getAnimations();
    final motions = [
      for (var index = 0; index < animations.length; index++)
        Live2DMotionRef(
          group: animations[index].getName(),
          index: index,
          file: '',
          name: animations[index].getName(),
          durationSeconds: animations[index].getDuration(),
        ),
    ];
    _orchestrator.dispose();
    _orchestrator = _createOrchestrator(tapMotions: motions);
    _idleAnimation = widget.config.idleMotion?.group;
    if (_idleAnimation == null && animations.isNotEmpty) {
      _idleAnimation = animations.first.getName();
    }
    if (_idleAnimation case final animation?) {
      controller.animationState.setAnimationByName(0, animation, true);
    }
    unawaited(_renderingLifecycle.setAttached(true).catchError((_) {}));
    widget.controller?._attachSpine(
      this,
      widget.config.modelId,
      _orchestrator,
      _handleTapAt,
    );
    _notifyReady();
    final playback = widget.ttsPlayback;
    if (playback?.phase == TTSPlaybackPhase.playing ||
        (playback == null && widget.isSpeaking)) {
      unawaited(_orchestrator.onMessageStarted());
    }
  }

  Future<bool> playMotion(
    Live2DMotionRef? motion, {
    int priority = 2,
  }) async {
    if (!_isReady || motion == null) return false;
    final animation = motion.group.isNotEmpty ? motion.group : motion.name;
    if (animation.isEmpty) return false;
    try {
      _controller.animationState.setAnimationByName(0, animation, false);
      final idle = _idleAnimation;
      if (idle != null && idle != animation) {
        _controller.animationState.addAnimationByName(0, idle, true, 0);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Live2DActionOrchestrator _createOrchestrator({
    Iterable<Live2DMotionRef> tapMotions = const [],
  }) {
    return Live2DActionOrchestrator(
      resolver: Live2DActionResolver(
        widget.config,
        tapMotions: tapMotions,
      ),
      replayIdleAtMotionBoundary: false,
      player: (motion, priority) => playMotion(
        motion,
        priority: priority,
      ),
    );
  }

  Future<bool> _handleTapAt(Offset _) =>
      _orchestrator.onTap(Live2DHitResult.body);

  void _handleSpeakingChanged() {
    if (widget.isSpeaking) {
      _sentenceTracker.reset(text: widget.responseText);
      unawaited(_orchestrator.onMessageStarted());
      return;
    }
    final emotion = _emotionDetectionService.detectEmotion(widget.responseText);
    unawaited(_orchestrator.onResponseCompleted(emotion: emotion.id));
  }

  void _handleResponseTextChanged() {
    final count = _sentenceTracker.takeNewBoundaries(widget.responseText);
    for (var index = 0; index < count; index++) {
      unawaited(_orchestrator.onSentenceBoundary());
    }
  }

  void _handleTTSPlaybackChanged(
    TTSPlaybackState? previous,
    TTSPlaybackState next,
  ) {
    final update = _ttsPlaybackCoordinator.evaluate(previous, next);
    _actionWrites = _actionWrites.then((_) async {
      switch (update.lifecycle) {
        case Live2DTTSLifecycleEvent.none:
          break;
        case Live2DTTSLifecycleEvent.started:
          await _orchestrator.onMessageStarted();
        case Live2DTTSLifecycleEvent.paused:
          await _orchestrator.onPlaybackPaused();
        case Live2DTTSLifecycleEvent.completed:
          final emotion = _emotionDetectionService.detectEmotion(next.text);
          await _orchestrator.onResponseCompleted(emotion: emotion.id);
        case Live2DTTSLifecycleEvent.stopped:
          await _orchestrator.onPlaybackStopped();
      }
      for (var index = 0; index < update.sentenceBoundaries; index++) {
        await _orchestrator.onSentenceBoundary();
      }
    }).catchError((_) {});
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _scrollSaveTimer?.cancel();
    _gestureStartTransform = _currentTransform;
    _gestureStartFocalPoint = details.localFocalPoint;
    _transformDirty = false;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final size = context.size;
    final startTransform = _gestureStartTransform;
    final startFocalPoint = _gestureStartFocalPoint;
    if (!widget.interactive ||
        size == null ||
        size.isEmpty ||
        startTransform == null ||
        startFocalPoint == null) {
      return;
    }
    final next = Live2DStageTransform.applyGesture(
      start: startTransform,
      startFocalPoint: startFocalPoint,
      currentFocalPoint: details.localFocalPoint,
      scaleDelta: details.scale,
      size: size,
    );
    setState(() {
      _stageScale = next.scale;
      _offsetX = next.offsetX;
      _offsetY = next.offsetY;
      _transformDirty = true;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _gestureStartTransform = null;
    _gestureStartFocalPoint = null;
    if (_transformDirty) _notifyTransformChanged();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.interactive || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scrollEvent = event as PointerScrollEvent;
      final size = context.size;
      if (size == null || size.isEmpty) return;
      final scaleFactor = math.exp(-scrollEvent.scrollDelta.dy * 0.0015);
      final next = Live2DStageTransform.applyGesture(
        start: _currentTransform,
        startFocalPoint: scrollEvent.localPosition,
        currentFocalPoint: scrollEvent.localPosition,
        scaleDelta: (_stageScale * scaleFactor).clamp(
              Live2DStageTransform.minScale,
              Live2DStageTransform.maxScale,
            ) /
            _stageScale,
        size: size,
      );
      setState(() {
        _stageScale = next.scale;
        _offsetX = next.offsetX;
        _offsetY = next.offsetY;
      });
      _scrollSaveTimer?.cancel();
      _scrollSaveTimer = Timer(
        const Duration(milliseconds: 250),
        _notifyTransformChanged,
      );
    });
  }

  Live2DStageTransform get _currentTransform =>
      Live2DStageTransform.constrained(
        scale: _stageScale,
        offsetX: _offsetX,
        offsetY: _offsetY,
      );

  void _applyConfigTransform(Live2DConfig config) {
    final transform = Live2DStageTransform.constrained(
      scale: config.scale,
      offsetX: config.offsetX,
      offsetY: config.offsetY,
    );
    _stageScale = transform.scale;
    _offsetX = transform.offsetX;
    _offsetY = transform.offsetY;
  }

  void _resetTransform() {
    _scrollSaveTimer?.cancel();
    setState(() {
      _stageScale = 1;
      _offsetX = 0;
      _offsetY = 0;
    });
    _notifyTransformChanged();
  }

  void _notifyReady() {
    final callback = widget.onReady;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  void _notifyTransformChanged() {
    _transformDirty = false;
    widget.onTransformChanged?.call(
      Live2DStageTransform(
        scale: _stageScale,
        offsetX: _offsetX,
        offsetY: _offsetY,
      ),
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _scrollSaveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._detachSpine(this);
    _orchestrator.dispose();
    try {
      _controller.pause();
    } catch (_) {}
    unawaited(_renderingLifecycle.pauseForTeardown());
    _renderingLifecycle.dispose();
    if (!_drawableOwnedByWidget) _drawable?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _loadError;
    if (error != null) {
      return widget.fallback ??
          _StatusMessage(
            icon: Icons.broken_image_outlined,
            message: error,
            visible: widget.showStatus,
          );
    }
    final drawable = _drawable;
    if (drawable == null) {
      return widget.showStatus
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    _drawableOwnedByWidget = true;
    Widget view = spine.SpineWidget.fromDrawable(
      drawable,
      _controller,
      fit: BoxFit.contain,
    );
    final opacity = widget.config.opacity.clamp(0.0, 1.0);
    if (opacity < 1) view = Opacity(opacity: opacity, child: view);
    return ClipRect(
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => unawaited(_handleTapAt(Offset.zero)),
          onDoubleTap: widget.interactive && widget.resetOnDoubleTap
              ? _resetTransform
              : null,
          onScaleStart: widget.interactive ? _handleScaleStart : null,
          onScaleUpdate: widget.interactive ? _handleScaleUpdate : null,
          onScaleEnd: widget.interactive ? _handleScaleEnd : null,
          child: FractionalTranslation(
            translation: Offset(_offsetX, _offsetY),
            child: Transform.scale(
              scale: _stageScale,
              child: view,
            ),
          ),
        ),
      ),
    );
  }
}
