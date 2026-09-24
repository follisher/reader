import 'package:flutter/material.dart';

/// 阅读主题：纸张背景色 + 正文文字色 + 面板/强调等派生色。
///
/// 6 套主题：黑白灰基础方案，外加暖色纸张、护眼绿色和夜间模式。
class ReaderTheme {
  const ReaderTheme({
    required this.alias,
    required this.name,
    required this.paperColor,
    required this.textColor,
    this.accentColor = const Color(0xFF000000),
    Color? panelColor,
    Color? segActiveColor,
    Color? selectionColor,
  })  : _panelColor = panelColor,
        _segActiveColor = segActiveColor,
        _selectionColor = selectionColor;

  final String alias;
  final String name;

  /// 阅读纸张背景颜色
  final Color paperColor;

  /// 正文文字颜色
  final Color textColor;

  /// 强调色（进度条、选中态、目录高亮等），支持白标定制
  final Color accentColor;

  final Color? _panelColor;
  final Color? _segActiveColor;
  final Color? _selectionColor;

  /// 菜单栏 / 设置面板背景色（较纸张略有区分）；未提供时回退纸张色。
  Color get panelColor => _panelColor ?? paperColor;

  /// 分段控件选中项底色（略亮的一档）；未提供时按主题明暗派生。
  Color get segActiveColor =>
      _segActiveColor ??
      (isDark
          ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), panelColor)
          : Color.alphaBlend(Colors.white.withValues(alpha: 0.6), paperColor));

  Color get subTextColor => textColor.withValues(alpha: 0.55);

  /// 细分隔线
  Color get dividerColor => textColor.withValues(alpha: 0.09);

  /// 滑块轨道底色
  Color get trackColor => textColor.withValues(alpha: 0.14);

  /// 描边色
  Color get borderColor => textColor.withValues(alpha: 0.16);

  /// 选中文字的高亮底色（不透明铺在文字后，正文仍清晰可读）。
  /// 各预设按其纸张背景显式配色（见下方 presets）；未提供时按纸张派生。
  Color get selectionColor {
    if (_selectionColor != null) return _selectionColor;
    if (isDark) {
      final HSLColor h = HSLColor.fromColor(paperColor);
      return h.withLightness((h.lightness + 0.16).clamp(0.0, 1.0)).toColor();
    }
    final Color warmed = Color.alphaBlend(
      accentColor.withValues(alpha: 0.14),
      paperColor,
    );
    final HSLColor h = HSLColor.fromColor(warmed);
    return h.withLightness((h.lightness + 0.04).clamp(0.0, 1.0)).toColor();
  }

  /// 复制并覆盖部分字段，便于业务方基于预设微调。
  ReaderTheme copyWith({
    String? alias,
    String? name,
    Color? paperColor,
    Color? textColor,
    Color? accentColor,
    Color? panelColor,
    Color? segActiveColor,
    Color? selectionColor,
  }) {
    return ReaderTheme(
      alias: alias ?? this.alias,
      name: name ?? this.name,
      paperColor: paperColor ?? this.paperColor,
      textColor: textColor ?? this.textColor,
      accentColor: accentColor ?? this.accentColor,
      panelColor: panelColor ?? _panelColor,
      segActiveColor: segActiveColor ?? _segActiveColor,
      selectionColor: selectionColor ?? _selectionColor,
    );
  }

  bool get isDark => paperColor.computeLuminance() < 0.3;

  static const ReaderTheme white = ReaderTheme(
    alias: 'white',
    name: '白',
    paperColor: Color(0xFFFFFFFF),
    textColor: Color(0xFF2B2B2B),
    panelColor: Color(0xFFF7F6F4),
    segActiveColor: Color(0xFFFFFFFF),
    selectionColor: Color(0xFFE0E0E0),
  );

  static const ReaderTheme grey = ReaderTheme(
    alias: 'grey',
    name: '灰',
    paperColor: Color(0xFFE8E8E8),
    textColor: Color(0xFF222222),
    panelColor: Color(0xFFF0F0F0),
    segActiveColor: Color(0xFFFAFAFA),
    selectionColor: Color(0xFFD0D0D0),
  );

  static const ReaderTheme yellow = ReaderTheme(
    alias: 'yellow',
    name: '暖纸',
    paperColor: Color(0xFFF4EBDD),
    textColor: Color(0xFF2F2A24),
    panelColor: Color(0xFFEEE3D2),
    segActiveColor: Color(0xFFFFF9EF),
    selectionColor: Color(0xFFE8D4AD),
  );

  static const ReaderTheme green = ReaderTheme(
    alias: 'green',
    name: '护眼绿',
    paperColor: Color(0xFFE1EAE3),
    textColor: Color(0xFF27332B),
    panelColor: Color(0xFFD6E2D9),
    segActiveColor: Color(0xFFF3F8F4),
    selectionColor: Color(0xFFBFD1C3),
  );

  static const ReaderTheme blue = ReaderTheme(
    alias: 'blue',
    name: '蓝',
    paperColor: Color(0xFFE1E1E1),
    textColor: Color(0xFF222222),
    panelColor: Color(0xFFD7D7D7),
    segActiveColor: Color(0xFFF0F0F0),
    selectionColor: Color(0xFFBDBDBD),
  );

  static const ReaderTheme night = ReaderTheme(
    alias: 'night',
    name: '夜',
    paperColor: Color(0xFF121212),
    textColor: Color(0xFFE0E0E0),
    panelColor: Color(0xFF1F1F1F),
    segActiveColor: Color(0xFF303030),
    selectionColor: Color(0xFF4A4A4A),
    accentColor: Color(0xFFF5F5F5),
  );

  static const List<ReaderTheme> presets = <ReaderTheme>[
    white,
    grey,
    yellow,
    green,
    blue,
    night,
  ];

  static ReaderTheme fromAlias(String? alias) {
    return presets.firstWhere(
      (ReaderTheme t) => t.alias == alias,
      orElse: () => yellow,
    );
  }
}
