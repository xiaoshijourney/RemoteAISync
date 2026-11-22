import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() => runApp(const ReleasePortalApp());

class ReleasePortalApp extends StatelessWidget {
  const ReleasePortalApp({super.key});

  @override
  Widget build(BuildContext context) => ShadApp(
    title: 'RAS Releases',
    theme: ShadThemeData(
      brightness: Brightness.light,
      colorScheme: const ShadZincColorScheme.light(),
      radius: BorderRadius.circular(12),
      cardTheme: const ShadCardTheme(
        padding: EdgeInsets.all(20),
        radius: BorderRadius.all(Radius.circular(18)),
      ),
    ),
    home: const ReleaseHome(),
  );
}

class ReleaseHome extends StatefulWidget {
  const ReleaseHome({super.key});

  @override
  State<ReleaseHome> createState() => _ReleaseHomeState();
}

class _ReleaseHomeState extends State<ReleaseHome> {
  final _client = BrowserClient()..withCredentials = true;
  final _password = TextEditingController();
  final _version = TextEditingController();
  final _build = TextEditingController();
  final _notes = TextEditingController();
  String _product = 'client';
  String _target = 'android';
  String? _csrf;
  String? _message;
  bool _busy = false;
  bool _mandatory = false;
  double? _progress;
  XFile? _selectedFile;
  int? _selectedSize;
  List<Map<String, dynamic>> _releases = const [];
  List<Map<String, dynamic>> _audit = const [];
  Map<String, dynamic>? _disk;

  Uri _uri(String path) => Uri.base.resolve(path);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  Future<void> _restoreSession() async {
    try {
      final response = await _client.get(_uri('/api/admin/session'));
      if (response.statusCode != 200) return;
      _csrf =
          (jsonDecode(response.body) as Map<String, dynamic>)['csrfToken']
              as String?;
      await _loadReleases();
    } catch (_) {
      // The login form remains available if the session has expired.
    }
  }

  @override
  void dispose() {
    _client.close();
    _password.dispose();
    _version.dispose();
    _build.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      final response = await _client.post(
        _uri('/api/admin/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'password': _password.text}),
      );
      if (response.statusCode != 200) {
        throw Exception(
          response.statusCode == 429 ? '尝试次数过多，请稍后再试。' : '管理员密码不正确。',
        );
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      _csrf = body['csrfToken'] as String?;
      await _loadReleases();
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  Future<void> _loadReleases() async {
    final response = await _client.get(_uri('/api/admin/releases'));
    if (response.statusCode == 401) {
      setState(() => _csrf = null);
      throw Exception('登录已过期，请重新登录。');
    }
    if (response.statusCode != 200) {
      throw Exception('读取版本列表失败（${response.statusCode}）。');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    setState(() {
      _releases = (body['releases'] as List).cast<Map<String, dynamic>>();
      _disk = body['disk'] as Map<String, dynamic>?;
    });
    final auditResponse = await _client.get(_uri('/api/admin/audit'));
    if (auditResponse.statusCode == 200) {
      final auditBody = jsonDecode(auditResponse.body) as Map<String, dynamic>;
      setState(
        () =>
            _audit = (auditBody['events'] as List).cast<Map<String, dynamic>>(),
      );
    }
  }

  Future<void> _selectFile() async {
    final file = await openFile();
    if (file != null) {
      final size = await file.length();
      setState(() {
        _selectedFile = file;
        _selectedSize = size;
      });
    }
  }

  Future<void> _upload() async {
    final file = _selectedFile;
    final csrf = _csrf;
    if (file == null || csrf == null) return;
    final size = await file.length();
    if (size <= 0 || size > 2 * 1024 * 1024 * 1024) {
      setState(() => _message = '文件必须大于 0 且不超过 2 GiB。');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _message = null;
    });
    final metadata = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'product': _product,
          'target': _target,
          'version': _version.text.trim(),
          'build': _build.text.trim(),
          'notes': _notes.text.trim(),
          'filename': file.name,
          'mandatory': _mandatory,
        }),
      ),
    );
    try {
      final request = http.StreamedRequest('POST', _uri('/api/admin/releases'))
        ..contentLength = size
        ..headers.addAll({
          'x-csrf-token': csrf,
          'x-release-metadata': metadata,
          'content-type': 'application/octet-stream',
        });
      var sent = 0;
      var lastReportedProgress = 0.0;
      final upload = request.sink
          .addStream(
            file.openRead().map((chunk) {
              sent += chunk.length;
              final progress = sent / size;
              if (progress - lastReportedProgress >= 0.01 || sent == size) {
                lastReportedProgress = progress;
                if (mounted) setState(() => _progress = progress);
              }
              return chunk;
            }),
          )
          .then((_) => request.sink.close());
      final responseFuture = _client.send(request);
      await upload;
      final response = await responseFuture;
      final body =
          jsonDecode(await response.stream.bytesToString())
              as Map<String, dynamic>;
      if (response.statusCode != 201) {
        throw Exception(_apiError(body, response.statusCode));
      }
      setState(() {
        _message = '上传并校验完成，已保存为草稿。检查版本与变更说明后再发布。';
        _selectedFile = null;
        _selectedSize = null;
      });
      await _loadReleases();
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  String _apiError(Map<String, dynamic> body, int status) =>
      switch (body['error']) {
        'target_product_mismatch' => '产品与平台组合不匹配。',
        'invalid_release_metadata' => '版本信息不完整或格式不正确。',
        'artifact_size_invalid' => '文件大小无效。',
        'csrf_rejected' => '安全校验失败，请刷新后重新登录。',
        _ => '操作失败（$status）。',
      };

  Future<void> _action(String id, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action == 'publish' ? '发布此版本？' : '撤回此版本？'),
        content: Text(
          action == 'publish'
              ? '发布后，匹配平台的客户端和运行端会将它识别为最新版本。'
              : '撤回后，客户端和运行端将不再收到此版本。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action == 'publish' ? '确认发布' : '确认撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final response = await _client.post(
        _uri('/api/admin/releases/$id/$action'),
        headers: {'x-csrf-token': _csrf!},
      );
      if (response.statusCode != 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        throw Exception(_apiError(body, response.statusCode));
      }
      await _loadReleases();
      setState(() => _message = action == 'publish' ? '版本已发布。' : '版本已撤回。');
    } catch (error) {
      setState(() => _message = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff7f7f8),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: _csrf == null ? _loginView() : _dashboard(),
        ),
      ),
    ),
  );

  Widget _loginView() => Padding(
    padding: const EdgeInsets.all(24),
    child: SizedBox(
      width: 420,
      child: ShadCard(
        title: const Text('RAS 版本管理'),
        description: const Text('管理员登录后上传、校验并手动发布各平台版本。'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadInput(
              controller: _password,
              obscureText: true,
              placeholder: const Text('管理员密码'),
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 14),
            ShadButton(
              onPressed: _busy ? null : _login,
              child: Text(_busy ? '正在登录…' : '登录'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Color(0xffa65f5f))),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _dashboard() => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '版本发布',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text('校验完成后手动发布；客户端和运行端只读取已发布版本。'),
                  ],
                ),
              ),
              ShadButton.ghost(
                onPressed: _busy ? null : _loadReleases,
                child: const Icon(LucideIcons.refreshCw, size: 17),
              ),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: _uploadCard(),
        ),
      ),
      if (_message != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(_message!),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '版本历史',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                ),
              ),
              if (_disk != null)
                Text(
                  '存储 ${((_disk!['artifactBytes'] as num) / 1024 / 1024).toStringAsFixed(1)} MiB',
                  style: const TextStyle(color: Color(0xff71717a)),
                ),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: ShadCard(
            title: const Text('最近操作'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _audit.isEmpty
                  ? const [Text('暂无操作记录。')]
                  : _audit.reversed
                        .take(8)
                        .map(
                          (event) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '${event['at']} · ${event['action']} · ${event['product']}/${event['target']}',
                            ),
                          ),
                        )
                        .toList(),
            ),
          ),
        ),
      ),
      if (_releases.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('暂无版本，上传文件创建第一个草稿。'),
          ),
        ),
      SliverList.builder(
        itemCount: _releases.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
          child: _releaseCard(_releases[index]),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 30)),
    ],
  );

  Widget _uploadCard() => ShadCard(
    title: const Text('上传新版本'),
    description: const Text('文件会先保存为草稿并计算 SHA-256。确认目标平台和版本后再发布。'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: _product,
                decoration: const InputDecoration(labelText: '产品'),
                items: const [
                  DropdownMenuItem(value: 'client', child: Text('客户端')),
                  DropdownMenuItem(value: 'host', child: Text('主机运行端')),
                  DropdownMenuItem(value: 'relay', child: Text('Relay 运行端')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _product = v!;
                        _target = _product == 'client' ? 'android' : 'windows';
                      }),
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: _target,
                decoration: const InputDecoration(labelText: '平台'),
                items:
                    (_product == 'client'
                            ? const ['android', 'web']
                            : const ['windows', 'ubuntu'])
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                onChanged: _busy ? null : (v) => setState(() => _target = v!),
              ),
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _version,
                decoration: const InputDecoration(
                  labelText: '版本',
                  hintText: '1.2.0',
                ),
              ),
            ),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _build,
                decoration: const InputDecoration(labelText: '构建号'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '更新说明'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ShadButton.outline(
              onPressed: _busy ? null : _selectFile,
              child: Text(_selectedFile?.name ?? '选择安装包或运行文件'),
            ),
            ShadButton(
              onPressed: _busy || _selectedFile == null ? null : _upload,
              child: Text(_busy ? '处理中…' : '上传为草稿'),
            ),
            if (_selectedSize != null)
              Text('${(_selectedSize! / 1024 / 1024).toStringAsFixed(1)} MiB'),
          ],
        ),
        if (_progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: LinearProgressIndicator(value: _progress),
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _mandatory,
          onChanged: _busy
              ? null
              : (value) => setState(() => _mandatory = value ?? false),
          title: const Text('标记为建议尽快更新'),
          subtitle: const Text('不会自动下载或安装，客户端仍由用户确认。'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
      ],
    ),
  );

  Widget _releaseCard(Map<String, dynamic> release) {
    final published = release['state'] == 'published';
    final id = release['id'] as String;
    return ShadCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${release['product']} · ${release['target']} · ${release['version']}+${release['build']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '${release['filename']} · ${((release['size'] as num) / 1024 / 1024).toStringAsFixed(1)} MiB · ${release['state']}',
                ),
                const SizedBox(height: 4),
                SelectableText(
                  'SHA-256  ${release['sha256']}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff71717a),
                  ),
                ),
                if ((release['notes'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(release['notes'] as String),
                  ),
              ],
            ),
          ),
          if (_busy)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (published)
            ShadButton.destructive(
              onPressed: () => _action(id, 'withdraw'),
              child: const Text('撤回'),
            )
          else if (release['state'] == 'draft' ||
              release['state'] == 'withdrawn')
            ShadButton(
              onPressed: () => _action(id, 'publish'),
              child: const Text('发布'),
            ),
        ],
      ),
    );
  }
}
