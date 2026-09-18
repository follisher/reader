import 'package:flutter/material.dart';
import 'package:flutter_book_reader/flutter_book_reader.dart' as engine;

class ReaderCommentInput extends StatefulWidget {
  const ReaderCommentInput({
    super.key,
    required this.quote,
    required this.onSave,
  });
  final String quote;
  final Future<void> Function(String) onSave;
  @override
  State<ReaderCommentInput> createState() => _ReaderCommentInputState();
}

class _ReaderCommentInputState extends State<ReaderCommentInput> {
  final _text = TextEditingController();
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving || _text.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_text.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试';
        });
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('写评论', style: TextStyle(fontSize: 18)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(widget.quote, maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                autofocus: true,
                enabled: !_saving,
                minLines: 3,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '写下你的想法',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving || _text.text.trim().isEmpty
                      ? null
                      : _save,
                  icon: const Icon(Icons.send),
                  label: Text(_saving ? '保存中' : '保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ReaderParagraphComments extends StatefulWidget {
  const ReaderParagraphComments({
    super.key,
    required this.comments,
    required this.onDelete,
  });
  final List<engine.Comment> comments;
  final Future<void> Function(engine.Comment) onDelete;
  @override
  State<ReaderParagraphComments> createState() =>
      _ReaderParagraphCommentsState();
}

class _ReaderParagraphCommentsState extends State<ReaderParagraphComments> {
  late final _comments = List<engine.Comment>.of(widget.comments)
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  bool _busy = false;
  String? _error;
  Future<void> _delete(engine.Comment comment) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onDelete(comment);
      if (mounted) {
        setState(() => _comments.removeWhere((c) => c.key == comment.key));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          ListTile(
            title: Text('${_comments.length} 条段评'),
            trailing: IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: _comments.isEmpty
                ? const Center(child: Text('暂无评论'))
                : ListView.separated(
                    itemCount: _comments.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final c = _comments[index];
                      return ListTile(
                        title: Text(c.text),
                        subtitle: Text(
                          '原文：${c.quote}\n${DateTime.fromMillisecondsSinceEpoch(c.createdAt).toLocal()}',
                        ),
                        trailing: IconButton(
                          tooltip: '删除评论',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _busy ? null : () => _delete(c),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
