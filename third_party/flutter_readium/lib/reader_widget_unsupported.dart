import 'package:flutter/material.dart';
import 'flutter_readium.dart';
import 'reader_channel.dart';

class ReadiumReaderWidget extends StatelessWidget {
  const ReadiumReaderWidget({
    required this.publication,
    this.loadingWidget = const Center(child: CircularProgressIndicator()),
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
    this.allowedDefaultActions,
    this.fontFamilyDeclarations = const [],
    this.goBackwardSemanticLabel = 'Go Backward',
    this.goForwardSemanticLabel = 'Go Forward',
    this.toggleShowControlsSemanticLabel = 'Toggle show controls',
    this.verticalScroll = false,
    super.key,
  });

  final Publication publication;
  final Widget loadingWidget;
  final Locator? initialLocator;
  final ValueNotifier<bool>? shouldShowControls;
  final Function(String)? onExternalLinkActivated;
  final ValueChanged<TextSelectionEvent>? onTextSelected;
  final ValueChanged<ReadiumReaderChannel>? onReaderChannelReady;
  final VoidCallback? onReaderReady;
  final ValueChanged<SelectionActionEvent>? onSelectionAction;
  final ValueChanged<DecorationInteractionEvent>? onDecorationInteraction;
  final ValueChanged<ImageTapEvent>? onImageTapped;
  final List<SelectionAction> selectionActions;
  final bool suppressNativeSelectionMenu;
  final Color? selectionHandleColor;
  final EPUBPreferences? initialPreferences;
  final Set<DefaultSelectionAction>? allowedDefaultActions;
  final List<ReaderFontFamily> fontFamilyDeclarations;
  final String goBackwardSemanticLabel;
  final String goForwardSemanticLabel;
  final String toggleShowControlsSemanticLabel;
  final bool verticalScroll;

  @override
  Widget build(final BuildContext context) => Center(child: Text('ReaderWidget is not available on this platform.'));
}
