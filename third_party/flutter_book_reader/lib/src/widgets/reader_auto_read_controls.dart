import 'package:flutter/material.dart';

import '../reader_labels.dart';
import '../reader_theme.dart';

/// Shared automatic-reading controls for text and EPUB surfaces.
class ReaderAutoReadBar extends StatelessWidget {
  const ReaderAutoReadBar(
      {super.key,
      required this.theme,
      required this.labels,
      required this.collapsed,
      required this.onExpand,
      required this.onSettings});
  final ReaderTheme theme;
  final ReaderLabels labels;
  final bool collapsed;
  final VoidCallback onExpand, onSettings;

  @override
  Widget build(BuildContext context) => FractionalTranslation(
        translation: const Offset(0, .5),
        child: Center(
            child: collapsed
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onExpand,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 2),
                        child: Text(labels.autoTurn,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1,
                                color: theme.subTextColor))))
                : GestureDetector(
                    key: const ValueKey('auto-read-settings-entry'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onSettings,
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 22, vertical: 10),
                        decoration: BoxDecoration(
                            color: theme.panelColor,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: theme.dividerColor),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(
                                      alpha: theme.isDark ? .35 : .1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 2))
                            ]),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.tune, size: 18, color: theme.accentColor),
                          const SizedBox(width: 7),
                          Text(labels.autoTurn,
                              style: TextStyle(
                                  fontSize: 15,
                                  height: 1,
                                  fontWeight: FontWeight.w600,
                                  color: theme.textColor)),
                        ])))),
      );
}

/// Returns false when the reader explicitly exits automatic reading. Dismissing
/// the sheet otherwise lets the caller resume after its layout has settled.
Future<bool> showReaderAutoReadSettings({
  required BuildContext context,
  required ReaderTheme theme,
  required ReaderLabels labels,
  required Duration interval,
  required ValueChanged<Duration> onIntervalChanged,
}) async {
  const slowSeconds = 40.0, fastSeconds = 15.0;
  var value = ((slowSeconds - interval.inMilliseconds / 1000) /
          (slowSeconds - fastSeconds))
      .clamp(0.0, 1.0);
  final resume = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: theme.panelColor,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (context) => SafeArea(
        top: false,
        child: StatefulBuilder(
            builder: (context, setSheet) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                      child: Row(children: [
                        Text(labels.speedSlow,
                            style: TextStyle(
                                fontSize: 14, color: theme.subTextColor)),
                        Expanded(
                            child: Slider(
                                value: value,
                                activeColor: theme.accentColor,
                                inactiveColor: theme.trackColor,
                                onChanged: (speed) {
                                  setSheet(() => value = speed);
                                  onIntervalChanged(Duration(
                                      milliseconds: ((slowSeconds -
                                                  speed *
                                                      (slowSeconds -
                                                          fastSeconds)) *
                                              1000)
                                          .round()));
                                })),
                        Text(labels.speedFast,
                            style: TextStyle(
                                fontSize: 14, color: theme.subTextColor)),
                      ])),
                  Divider(height: 1, color: theme.dividerColor),
                  InkWell(
                      onTap: () => Navigator.of(context).pop(false),
                      child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                              child: Text(labels.autoTurnExit,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: theme.textColor))))),
                ]))),
  );
  return resume != false;
}
