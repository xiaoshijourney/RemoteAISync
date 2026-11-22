import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateCheckCard extends StatefulWidget {
  const UpdateCheckCard({
    required this.product,
    required this.target,
    required this.currentVersion,
    this.currentBuild = '1',
    super.key,
  });

  final String product;
  final String target;
  final String currentVersion;
  final String currentBuild;

  @override
  State<UpdateCheckCard> createState() => _UpdateCheckCardState();
}

class _UpdateCheckCardState extends State<UpdateCheckCard> {
  static final _client = http.Client();
  static final _baseUri = Uri.https('ras.xiaoshijourney.com');
  Map<String, dynamic>? _release;
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final uri = _baseUri.replace(
        path: '/api/v1/updates/${widget.product}/${widget.target}/latest',
      );
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 204) {
        setState(() => _release = null);
      } else if (response.statusCode == 200) {
        setState(
          () => _release = jsonDecode(response.body) as Map<String, dynamic>,
        );
      } else {
        throw Exception('服务器返回 ${response.statusCode}');
      }
    } catch (_) {
      setState(() => _error = '暂时无法连接更新服务。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool get _hasUpdate {
    if (_release == null) return false;
    final versionOrder = _compareVersions(
      _release!['version'] as String? ?? '0.0.0',
      widget.currentVersion,
    );
    final latestBuild = int.tryParse(_release!['build']?.toString() ?? '') ?? 0;
    final currentBuild = int.tryParse(widget.currentBuild) ?? 0;
    return versionOrder > 0 ||
        (versionOrder == 0 && latestBuild > currentBuild);
  }

  int _compareVersions(String left, String right) {
    List<int> parse(String value) => value
        .split(RegExp(r'[+-]'))
        .first
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final a = parse(left);
    final b = parse(right);
    for (var index = 0; index < 3; index++) {
      final diff =
          (index < a.length ? a[index] : 0) - (index < b.length ? b[index] : 0);
      if (diff != 0) return diff;
    }
    return 0;
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('下载 RemoteAISync ${release['version']}？'),
        content: Text('${release['notes'] ?? '此版本没有更新说明。'}\n\n文件下载后需由你确认安装。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续下载'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final path = release['downloadUrl'] as String?;
    if (path == null) return;
    final uri = _baseUri.resolve(path);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final title = _checking
        ? '正在检查更新…'
        : _error ??
              (_hasUpdate
                  ? '发现新版本 ${_release!['version']}'
                  : '已是最新版本 ${widget.currentVersion}');
    return ShadCard(
      title: const Text('软件更新'),
      description: Text(title),
      child: Row(
        children: [
          Expanded(
            child: _hasUpdate
                ? Text(
                    (_release!['notes'] as String?)?.trim().isNotEmpty == true
                        ? _release!['notes'] as String
                        : '新版本已发布。下载后请确认安装。',
                  )
                : const Text('版本检查不会自动安装更新。'),
          ),
          const SizedBox(width: 12),
          if (_hasUpdate)
            ShadButton(onPressed: _download, child: const Text('查看并下载'))
          else
            ShadButton.outline(
              onPressed: _checking ? null : _check,
              child: const Text('重新检查'),
            ),
        ],
      ),
    );
  }
}
