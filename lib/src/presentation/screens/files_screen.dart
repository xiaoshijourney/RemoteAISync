import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../theme.dart';

const _demoFiles = [
  DemoFile(
    name: 'README.md',
    path: 'remotaisync-demo/README.md',
    size: '1.2 KB',
    kind: 'Markdown',
    content:
        '# Demo project\n\nA local sample workspace shown in the RemoteAISync prototype.\n\n- Agent: OpenCode\n- Status: waiting for approval\n',
  ),
  DemoFile(
    name: 'main.py',
    path: 'remotaisync-demo/src/main.py',
    size: '842 B',
    kind: 'Python',
    content:
        'from http.server import BaseHTTPRequestHandler, HTTPServer\n\nclass Handler(BaseHTTPRequestHandler):\n    def do_GET(self):\n        self.send_response(200)\n        self.end_headers()\n        self.wfile.write(b"RemoteAISync demo")\n\nHTTPServer(("127.0.0.1", 4173), Handler).serve_forever()\n',
  ),
  DemoFile(
    name: 'app.config.json',
    path: 'remotaisync-demo/config/app.config.json',
    size: '316 B',
    kind: 'JSON',
    content:
        '{\n  "name": "demo-app",\n  "previewPort": 4173,\n  "approvalRequired": true\n}\n',
  ),
  DemoFile(
    name: 'preview.exe',
    path: 'remotaisync-demo/dist/preview.exe',
    size: '2.8 MB',
    kind: 'Windows 程序',
    launchable: true,
    content:
        '程序文件不会在手机端执行。\n连接 Windows 主机后，可请求主机按白名单启动此程序。\n\n当前为演示条目，未连接实际电脑。',
  ),
];

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = _demoFiles
        .where((file) => file.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 24),
      children: [
        Text('文件', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 5),
        Text(
          '浏览项目产物，预览源码或请求电脑打开程序。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        const _WorkspaceHeader(),
        const SizedBox(height: 14),
        TextField(
          controller: _searchController,
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            hintText: '搜索文件',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          '${files.length} 个样例文件',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 3),
        if (files.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: Text('没有匹配的文件')),
          )
        else
          for (final file in files) _FileRow(file: file),
        const SizedBox(height: 16),
        const _LocalOnlyNote(),
      ],
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appLine),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open_outlined, color: appGreen, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'remotaisync-demo',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                Text('本地样例工作区', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Icon(Icons.cloud_off_outlined, color: appMuted, size: 18),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final DemoFile file;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPreview(context, file),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        constraints: const BoxConstraints(minHeight: 65),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: appLine)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: file.launchable
                    ? const Color(0xFFFFF0DD)
                    : const Color(0xFFEAF0F5),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                file.launchable
                    ? Icons.widgets_outlined
                    : Icons.description_outlined,
                color: file.launchable ? appAmber : const Color(0xFF386A8C),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${file.kind}  ·  ${file.size}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (file.launchable)
              IconButton(
                tooltip: '请求电脑打开程序',
                onPressed: () => _showLaunchNotice(context),
                icon: const Icon(Icons.open_in_new, size: 20),
              )
            else
              const Icon(Icons.chevron_right, color: appMuted, size: 20),
          ],
        ),
      ),
    );
  }

  void _showPreview(BuildContext context, DemoFile file) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          file.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭预览',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(file.path, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: appLine),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        file.content,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.55,
                          color: appInk,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showLaunchNotice(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('尚未连接 Windows 主机，程序启动请求没有发送。'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _LocalOnlyNote extends StatelessWidget {
  const _LocalOnlyNote();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: appMuted, size: 17),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '当前列表为演示数据；手机不会执行 EXE，也未读取电脑文件。',
            style: TextStyle(color: appMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}
