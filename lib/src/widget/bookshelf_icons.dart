import 'package:forui_lucide/forui_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../models.dart';

/// Uses the same Lucide symbols as the host's chart mode selector.
abstract final class BookshelfIcons {
  static IconData collection(BookCollection collection) => switch (collection) {
    BookCollection.ancient => FLucideIcons.scrollText,
    BookCollection.contemporary => FLucideIcons.bookOpen,
    BookCollection.personal => FLucideIcons.bookHeart,
  };

  static IconData category(String name) {
    final label = name.trim().replaceAll('門', '门').replaceAll('風', '风');
    if (label.contains('八字') || label.contains('四柱') || label.contains('命理')) {
      return FLucideIcons.columns4;
    }
    if (label.contains('紫微')) return FLucideIcons.waypoints;
    if (label.contains('七政')) return FLucideIcons.disc2;
    if (label.contains('奇门')) return FLucideIcons.grid3x3;
    if (label.contains('六爻')) return FLucideIcons.coins;
    if (label.contains('六壬')) return Icons.schedule;
    if (label.contains('太乙')) return FLucideIcons.orbit;
    if (label.contains('风水')) return FLucideIcons.compass;
    if (label.contains('梅花')) return FLucideIcons.flower2;
    if (label.contains('相法')) return FLucideIcons.scanFace;
    return switch (label) {
      '全部' => FLucideIcons.layoutGrid,
      '古籍' || '经典' || '經典' || '经部' || '經部' => FLucideIcons.scrollText,
      '当代' || '當代' || '文学' || '文學' || '小说' || '小說' => FLucideIcons.bookOpen,
      '私藏' => FLucideIcons.bookHeart,
      '继续导入' || '其它分类' || '其他分类' => FLucideIcons.folderPlus,
      _ => FLucideIcons.folderOpen,
    };
  }
}

class BookshelfCategoryHeading extends StatelessWidget {
  const BookshelfCategoryHeading({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ExcludeSemantics(child: Icon(BookshelfIcons.category(label), size: 18)),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}
