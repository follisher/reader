import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' as mq show Orientation;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'flutter_readium.dart';
import 'reader_channel.dart';
import 'reader_pointer_session.dart';

const _viewType = 'dk.nota.flutter_readium/ReadiumReaderWidget';

/// A ReadiumReaderWidget wraps a native Kotlin/Swift Readium navigator widget.
class ReadiumReaderWidget extends StatefulWidget {
  const ReadiumReaderWidget({
    required this.publication,
    this.loadingWidget,
    this.initialLocator,
    this.shouldShowControls,
    this.onExternalLinkActivated,
    this.onTextSelected,
    this.onReaderChannelReady,
    this.onReaderReady,
    this.onSelectionAction,
    this.onDecorationInteraction,
    this.onImageTapped,
    this.selectionActions = const [],
    this.suppressNativeSelectionMenu = false,
    this.selectionHandleColor,
    this.initialPreferences,
    this.fontFamilyDeclarations = const [],
    this.allowedDefaultActions,
    this.goBackwardSemanticLabel = 'Go Backward',
    this.goForwardSemanticLabel = 'Go Forward',
    this.toggleShowControlsSemanticLabel = 'Toggle show controls',
    this.preloadPreviousPositionCount = 2,
    this.preloadNextPositionCount = 6,
    super.key,
  });

  /// The publication to display, obtained from [FlutterReadium.openPublication].
  final Publication publication;

  /// Optional widget to show while the reader is loading, e.g. a spinner.
  /// It will be shown until the native reader reports that its initial content
  /// is visually ready.
  /// It should typically be a full-screen widget, since it will be stacked on top of the reader widget.
  final Widget? loadingWidget;

  /// Optional locator to restore a previously saved reading position. `null` starts from the beginning.
  final Locator? initialLocator;

  /// Notifier that tells client whether it should show controls, based on user-interaction with the native viewer.
  final ValueNotifier<bool>? shouldShowControls;

  /// Callback invoked when the reader activates an external (non-publication) link.
  final Function(String)? onExternalLinkActivated;

  /// Callback invoked when the user selects text in the reader.
  final ValueChanged<TextSelectionEvent>? onTextSelected;
  final ValueChanged<ReadiumReaderChannel>? onReaderChannelReady;

  /// Called whenever a newly-created native navigator has rendered content.
  final VoidCallback? onReaderReady;

  /// Callback invoked when the user taps a configured editing action on selected text.
  final ValueChanged<SelectionActionEvent>? onSelectionAction;

  /// Callback invoked when the user interacts with an existing decoration (e.g. taps a highlight).
  final ValueChanged<DecorationInteractionEvent>? onDecorationInteraction;

  /// Callback invoked when the user taps an image in the EPUB.
  ///
  /// Fired on iOS and Android (when supported). On Android the kotlin-toolkit
  /// does not yet expose a target-element API, so this callback never fires
  /// there. On iOS it uses swift-toolkit's `ImageContentElement` SPI.
  final ValueChanged<ImageTapEvent>? onImageTapped;

  /// Native context menu actions shown when text is selected.
  final List<SelectionAction> selectionActions;

  /// Keep native selection handles but let Flutter render the action menu.
  final bool suppressNativeSelectionMenu;

  /// Tint used by the platform-native text selection handles.
  ///
  /// Updated independently of the navigator to preserve the loaded document.
  final Color? selectionHandleColor;

  /// Preferences supplied while constructing the native navigator so the first
  /// page is rendered in the selected reading theme.
  final EPUBPreferences? initialPreferences;

  /// Static font families whose faces are bundled as Flutter assets.
  final List<ReaderFontFamily> fontFamilyDeclarations;

  /// Controls which system-provided actions appear in the text selection menu.
  ///
  /// If `null` (the default), all platform defaults are shown (Copy, Share, etc.).
  /// If an empty set, only custom [selectionActions] are shown.
  /// Otherwise, only the specified system actions are included.
  ///
  /// Note: [DefaultSelectionAction.translate] is iOS-only; [DefaultSelectionAction.selectAll]
  /// is Android-only. Unsupported values for a platform are silently ignored.
  final Set<DefaultSelectionAction>? allowedDefaultActions;

  /// Accessibility label for the backward navigation semantic region.
  final String goBackwardSemanticLabel;

  /// Accessibility label for the forward navigation semantic region.
  final String goForwardSemanticLabel;

  /// Accessibility label for the controls toggle semantic region.
  final String toggleShowControlsSemanticLabel;

  /// Number of resource positions to preload before the current one. Default `2`.
  /// Higher values smooth out backward navigation at the cost of memory; consider
  /// increasing for local publications and lowering for remote ones.
  ///
  /// iOS only. kotlin-toolkit does not expose this on its public navigator
  /// configuration, so the value is ignored on Android.
  final int preloadPreviousPositionCount;

  /// Number of resource positions to preload after the current one. Default `6`.
  /// See [preloadPreviousPositionCount] for tradeoffs and platform support.
  final int preloadNextPositionCount;

  @override
  State<StatefulWidget> createState() => _ReadiumReaderWidgetState();
}

class _ReadiumReaderWidgetState extends State<ReadiumReaderWidget> implements ReadiumReaderWidgetInterface {
  static final _log = ReadiumLog.tag('ReaderWidget');
  static const _wakelockTimerDuration = Duration(minutes: 30);

  Timer? _wakelockTimer;
  ReadiumReaderChannel? _channel;
  EPUBPreferences? _latestEPUBPreferences;
  PDFPreferences? _latestPDFPreferences;
  final Map<String, List<ReaderDecoration>> _latestDecorationGroups =
      <String, List<ReaderDecoration>>{};
  bool wasDestroyed = false;
  bool isReady = false;

  final _readium = FlutterReadiumPlatform.instance;

  mq.Orientation? _lastOrientation;
  late Widget _readerWidget;

  EPUBPreferences? get _defaultPreferences => _readium.defaultPreferences;

  bool _scrollMode = false;
  final _pointerSession = ReaderPointerSession();

  /// Last time that the controls were hidden due to a touch, used to guess whether a tap was caused
  /// by such a touch.
  DateTime? _lastTouchHideControls;

  @override
  void initState() {
    super.initState();
    _log.d('ReadiumReaderWidget init');

    _latestEPUBPreferences = widget.initialPreferences ?? _defaultPreferences;
    _readerWidget = _buildNativeReader();
    _enableWakelock();
    _setCurrentWidgetInterface();
    _scrollMode = _latestEPUBPreferences?.scroll ?? false;
  }

  @override
  void didUpdateWidget(covariant ReadiumReaderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the current preferences available for channel initialization.
    if (widget.initialPreferences != null) {
      _latestEPUBPreferences = widget.initialPreferences;
    }
    if (oldWidget.selectionHandleColor != widget.selectionHandleColor) {
      unawaited(_updateSelectionHandleColor());
    }
  }

  Future<void> _updateSelectionHandleColor() async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.invokeMethod<void>(
        'setSelectionHandleColor', widget.selectionHandleColor?.toARGB32(),
      );
    } on Object catch (error) {
      _log.w('Could not update selection handle tint: $error');
    }
  }

  @override
  void dispose() {
    _log.d('ReadiumReaderWidget dispose');
    _cleanup();
    _channel?.dispose();
    _channel = null;
    _lastOrientation = null;

    _disableWakelock();
    wasDestroyed = true;

    super.dispose();
  }

  @override
  Widget build(final BuildContext context) {
    _onOrientationChangeWorkaround(MediaQuery.orientationOf(context));

    final readingProgression = widget.publication.metadata.readingProgression;
    // TODO: this presumes that ReadingProgression value btt or vertical scroll using btt is not ever used
    final leftUpLabel = readingProgression == ReadingProgression.rtl && !_scrollMode
        ? widget.goForwardSemanticLabel
        : widget.goBackwardSemanticLabel;
    final rightDownLabel = readingProgression == ReadingProgression.rtl && !_scrollMode
        ? widget.goBackwardSemanticLabel
        : widget.goForwardSemanticLabel;

    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: _scrollMode ? null : 70,
          height: _scrollMode ? 100 : null,
          right: _scrollMode ? 0 : null,
          bottom: _scrollMode ? null : 0,
          child: _buildSemanticsPrevNextPage(
            label: leftUpLabel,
            toNextPage: false,
          ),
        ),
        // TODO: This presumes there is only one semantic label, for when the different toggles
        Positioned.fill(
          child: _buildSemanticsToggleFullScreen(
            label: widget.toggleShowControlsSemanticLabel,
          ),
        ),
        Positioned(
          top: _scrollMode ? null : 0,
          right: 0,
          width: _scrollMode ? null : 70,
          height: _scrollMode ? 100 : null,
          left: _scrollMode ? 0 : null,
          bottom: 0,
          child: _buildSemanticsPrevNextPage(
            label: rightDownLabel,
            toNextPage: true,
          ),
        ),
        ExcludeSemantics(
          child: Listener(
            onPointerDown: (final event) {
              _pointerSession.start(event.timeStamp, event.position);
              _enableWakelock();
            },
            onPointerMove: (final event) {
              if (_pointerSession.move(event.position)) {
                _onInteraction();
              }
            },
            onPointerCancel: (_) => _pointerSession.cancel(),
            onPointerUp: (final event) {
              if (_pointerSession.finish(event.timeStamp) == ReaderPointerResult.tap) {
                final dx = event.position.dx;

                if (dx < 70.0 || ((context.size?.width ?? 0) - dx) < 70.0) {
                  // edge tap
                  _onInteraction();
                } else {
                  // center tap
                  _toggleControls();
                }
              }

            },

            child: _readerWidget,
          ),
        ),
        if (!isReady && widget.loadingWidget != null) Positioned.fill(child: widget.loadingWidget!),
      ],
    );
  }

  @override
  Future<void> go(
    final Locator locator, {
    required final bool isAudioBookWithText,
    final bool animated = false,
  }) async {
    _log.d(() => 'Go to $locator');

    await _channel?.go(
      locator,
      animated: animated,
      isAudioBookWithText: isAudioBookWithText,
    );

    _log.d('Go to locator completed');
  }

  @override
  Future<void> goBackward({final bool animated = true}) async => _channel?.goBackward();

  @override
  Future<void> goForward({final bool animated = true}) async => _channel?.goForward();

  @override
  Future<void> setEPUBPreferences(EPUBPreferences preferences) async {
    _latestEPUBPreferences = preferences;
    final channel = _channel;
    if (channel != null) await channel.setEPUBPreferences(preferences);

    if (mounted) {
      setState(() => _scrollMode = preferences.scroll ?? false);
    }
  }

  @override
  Future<void> setPDFPreferences(PDFPreferences preferences) async {
    _latestPDFPreferences = preferences;
    final channel = _channel;
    if (channel != null) await channel.setPDFPreferences(preferences);
  }

  @override
  Future<void> applyDecorations(
    String id,
    List<ReaderDecoration> decorations,
  ) async {
    // Retain empty lists too: they represent an intentional group clear and
    // must win over an older non-empty snapshot after a channel replacement.
    _latestDecorationGroups[id] = List<ReaderDecoration>.unmodifiable(
      decorations,
    );
    final channel = _channel;
    if (channel != null) await channel.applyDecorations(id, decorations);
  }

  Widget _buildNativeReader() {
    final publication = widget.publication;

    _log.d(publication.identifier);

    final defaultPreferences = _latestEPUBPreferences?.toJson();

    final selectionHandleColor = widget.selectionHandleColor?.toARGB32();
    final creationParams = <String, dynamic>{
      'pubIdentifier': publication.identifier,
      'preferences': defaultPreferences,
      'initialLocator': (_currentLocator ?? widget.initialLocator) == null
          ? null
          : json.encode(_currentLocator ?? widget.initialLocator),
      'selectionHandleColor': selectionHandleColor,
      'preloadPreviousPositionCount': widget.preloadPreviousPositionCount,
      'preloadNextPositionCount': widget.preloadNextPositionCount,
      'fontFamilyDeclarations': widget.fontFamilyDeclarations.map((font) => font.toMap()).toList(),
      if (widget.selectionActions.isNotEmpty)
        'selectionActions': widget.selectionActions.map((a) => a.toJson()).toList(),
      'suppressNativeSelectionMenu': widget.suppressNativeSelectionMenu,
      if (widget.allowedDefaultActions != null)
        'allowedDefaultActions': widget.allowedDefaultActions!.map((a) => a.serialized).toList(),
    };

    _log.d('creationParams=$creationParams');

    if (Platform.isAndroid) {
      return PlatformViewLink(
        viewType: _viewType,
        surfaceFactory: (final context, final controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const {},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        onCreatePlatformView: (final params) =>
            PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: _viewType,
                layoutDirection: TextDirection.ltr,
                creationParams: creationParams,
                creationParamsCodec: const StandardMessageCodec(),
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
              ..create(),
      );
    } else if (Platform.isIOS) {
      return UiKitView(
        viewType: _viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    return ColoredBox(
      color: const Color(0xffff00ff),
      child: Center(
        child: Text(
          'TODO — Implement ReadiumReaderWidget on ${Platform.operatingSystem}.',
        ),
      ),
    );
  }

  Future<void> _enableWakelock() async {
    _log.d('Ensure wakelock /w timer');

    WakelockPlus.enable();

    // Disable wakelock after 30 minutes of inactivity (no interaction with reader).
    _wakelockTimer?.cancel();
    _wakelockTimer = Timer(_wakelockTimerDuration, _disableWakelock);
  }

  void _disableWakelock() {
    _log.d('Disable wakelock');

    WakelockPlus.disable();
    _wakelockTimer?.cancel();
  }

  void _setCurrentWidgetInterface() {
    _log.d('Set current reader in plugin');
    // ignore: invalid_use_of_protected_member
    _readium.currentReaderWidget = this;
  }

  void _cleanup() {
    _log.d('cleanup ${_channel?.name}!');
    // ignore: invalid_use_of_protected_member
    _readium.currentReaderWidget = null;
  }

  Locator? _currentLocator;

  void _onPlatformViewCreated(final int id) {
    _channel = ReadiumReaderChannel(
      '$_viewType:$id',
      onReaderReady: _markReady,
      onPageChanged: (final locator) {
        _log.d(() => 'onPageChanged: ${locator.toJson()}');
        _currentLocator = locator;

        _markReady();
      },
      onTextSelected: (event) {
        _pointerSession.selected();
        widget.shouldShowControls?.value = false;
        widget.onTextSelected?.call(event);
      },
      onSelectionAction: widget.onSelectionAction,
      onDecorationInteraction: widget.onDecorationInteraction,
      onImageTapped: widget.onImageTapped,
    );

    if (widget.selectionActions.isNotEmpty) {
      _channel!.configureSelectionActions(widget.selectionActions);
    }
    unawaited(_updateSelectionHandleColor());
    unawaited(_replayNativeState(_channel!));
    widget.onReaderChannelReady?.call(_channel!);

    _log.d('New widget is: ${_channel?.name}');
  }

  Future<void> _replayNativeState(ReadiumReaderChannel channel) async {
    try {
      final epubPreferences = _latestEPUBPreferences;
      if (epubPreferences != null) {
        await channel.setEPUBPreferences(epubPreferences);
      }
      final pdfPreferences = _latestPDFPreferences;
      if (pdfPreferences != null) {
        await channel.setPDFPreferences(pdfPreferences);
      }
      for (final entry in _latestDecorationGroups.entries) {
        await channel.applyDecorations(entry.key, entry.value);
      }
    } on Object catch (error) {
      // A second rapid theme switch may dispose this channel while replaying.
      // The snapshots remain stored and will be replayed into the next channel.
      _log.w('Could not replay reader state on ${channel.name}: $error');
    }
  }

  void _markReady() {
    if (!mounted || isReady) {
      return;
    }

    setState(() {
      isReady = true;
    });
    widget.onReaderReady?.call();
  }

  /// TODO: Remove this workaround, if the underlying issue is completely fixed in Readium.
  ///
  /// If orientation changes, fix page alignment, so it doesn't stay on a weird-looking page 5½.
  void _onOrientationChangeWorkaround(final mq.Orientation orientation) async {
    if (_lastOrientation == null) {
      _lastOrientation = orientation;

      return;
    }

    if (!isReady) {
      return;
    }

    if (orientation != _lastOrientation) {
      // Remove domRange/cssSelector, so it navigates to a progression, which will always
      // trigger scrolling to the nearest page.
      if (_lastOrientation != null && _currentLocator != null) {
        Future.delayed(const Duration(milliseconds: 500)).then((final value) {
          _log
            ..d(
              'Orientation changed. Re-navigating to current locator to re-align page.',
            )
            ..d('locator = $_currentLocator');
          _channel?.go(
            _currentLocator!,
            animated: false,
            isAudioBookWithText: false, // TODO: isAudioBookWithText - we don't know atm.
          );
        });
      }

      _lastOrientation = orientation;
    }
  }

  void _toggleControls() {
    if (widget.shouldShowControls == null) return;

    final last = _lastTouchHideControls;
    final delta = last != null ? DateTime.now().difference(last) : null;
    // If we recently hid the controls due to a touch, assume that the tap is due to that same
    // touch, so don't re-show the controls.
    if (delta == null || delta > const Duration(milliseconds: 400)) {
      widget.shouldShowControls!.value = !widget.shouldShowControls!.value;
      // Debounce taps, since Readium apparently sends a double onTap on some devices.
      _lastTouchHideControls = DateTime.now();
    }
  }

  void _onInteraction() {
    if (widget.shouldShowControls?.value == true) {
      widget.shouldShowControls?.value = false;
      _lastTouchHideControls = DateTime.now();
    }

    // A user swipe / edge-tap is the unambiguous "user took manual control"
    // signal (audio-driven page turns are programmatic and never reach this
    // Listener). The native side enters narration manual mode only if narration
    // is active, so this is a no-op during plain reading.
    _channel?.notifyUserNavigation();
  }

  Widget _buildSemanticsPrevNextPage({
    required final String label,
    required final bool toNextPage,
  }) => Semantics(
    // TODO: this is not necessarily how it should be handled needs to be evaluated more
    sortKey: OrdinalSortKey(toNextPage ? 2.0 : 0.0),
    button: true,
    container: true,
    label: label,
    onTap: () => toNextPage ? _channel?.goForward() : _channel?.goBackward(),
    child: Container(color: Colors.transparent),
  );

  Widget _buildSemanticsToggleFullScreen({required final String label}) => Semantics(
    sortKey: const OrdinalSortKey(1.0),
    button: true,
    container: true,
    label: label,
    onTap: _toggleControls,
    child: Container(color: Colors.transparent),
  );
}
