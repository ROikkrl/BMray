import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class JsonConfigTab {
  const JsonConfigTab(this.title, this.content);

  final String title;
  final String content;
}

/// Keeps subscription credentials on the device; copying is an explicit action.
class JsonConfigPage extends StatelessWidget {
  const JsonConfigPage({super.key, required this.title, required this.tabs});

  final String title;
  final List<JsonConfigTab> tabs;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: tabs.length,
    child: Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: TabBar(
          isScrollable: true,
          tabs: [for (final tab in tabs) Tab(text: tab.title)],
        ),
      ),
      body: TabBarView(children: [
        for (final tab in tabs)
          Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(children: [
                const Expanded(child: Text(
                  'JSON может содержать ключи и пароли. Не публикуйте его без удаления секретов.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9DAEC7)),
                )),
                IconButton(
                  tooltip: 'Копировать JSON',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: tab.content));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('JSON скопирован')),
                      );
                    }
                  },
                ),
              ]),
            ),
            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(tab.content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            )),
          ]),
      ]),
    ),
  );
}
