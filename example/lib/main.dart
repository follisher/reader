import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reader/reader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReaderDemo());
}

class ReaderDemo extends StatefulWidget {
  const ReaderDemo({super.key});
  @override
  State<ReaderDemo> createState() => _ReaderDemoState();
}

class _ReaderDemoState extends State<ReaderDemo> {
  LocalBookshelfRepository? _repository;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    LocalBookshelfRepository? repo;
    try {
      repo = await LocalBookshelfRepository.create();
      if (!mounted) {
        await repo.close();
        return;
      }
      setState(() {
        _repository = repo;
        _error = null;
      });
    } catch (e) {
      await repo?.close();
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = _repository;
    final app = MaterialApp(
      title: '离线阅读',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      locale: const Locale('zh', 'CN'),
      theme: ReaderPalette.lightTheme(),
      home: repo == null
          ? Scaffold(
              body: Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('书架初始化失败，请重试'),
                          TextButton(
                            onPressed: _initialize,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
              ),
            )
          : Builder(
              builder: (context) => BookshelfView(
                onBookTap: (book) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderView(book: book),
                  ),
                ),
              ),
            ),
    );
    return repo == null
        ? app
        : ProviderScope(
            overrides: [bookshelfRepositoryProvider.overrideWithValue(repo)],
            child: app,
          );
  }
}
