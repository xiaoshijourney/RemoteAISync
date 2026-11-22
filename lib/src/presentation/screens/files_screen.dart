import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../../platform/local_file_saver.dart';
import '../components/chat_components.dart';
import '../components/glass_surface.dart';
import '../components/session_scope_selector.dart';
import '../shad_theme.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({required this.controller, super.key});
  final DemoController controller;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen>
    with AutomaticKeepAliveClientMixin<FilesScreen> {
  final _search = TextEditingController();
  String? _path;
  String _query = '';
  List<HostFileEntry> _entries = const [];
  bool _loading = false;
  String? _loadError;
  int _loadGeneration = 0;
  bool _selectionMode = false;
  bool _operating = false;
  bool _loadRequested = false;
  final Set<String> _selectedPaths = <String>{};
  bool _wasConnected = false;
  String? _observedWorkspaceDirectory;
  bool _observedAllSessionsScope = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.controller.isLive;
    _observedWorkspaceDirectory = widget.controller.workspaceDirectory;
    _observedAllSessionsScope = widget.controller.allSessionsScope;
    widget.controller.addListener(_onControllerChanged);
    if (_wasConnected) {
      _scheduleInitialLoad();
    }
  }

  @override
  void didUpdateWidget(covariant FilesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;

    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _loadGeneration++;
    _wasConnected = widget.controller.isLive;
    _observedWorkspaceDirectory = widget.controller.workspaceDirectory;
    _observedAllSessionsScope = widget.controller.allSessionsScope;
    _path = null;
    _entries = const [];
    _loading = false;
    _loadError = null;
    _loadRequested = false;
    _selectionMode = false;
    _selectedPaths.clear();
    if (_wasConnected) _scheduleInitialLoad();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _search.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final connected = widget.controller.isLive;
    if (connected && !_wasConnected) {
      _wasConnected = true;
      _loadRequested = false;
      setState(() {
        _loadError = null;
      });
      _scheduleInitialLoad();
    } else if (!connected && _wasConnected) {
      _wasConnected = false;
      _loadGeneration++;
      setState(() {
        _path = null;
        _entries = const [];
        _loadError = null;
        _loading = false;
        _loadRequested = false;
      });
    } else {
      final workspaceDirectory = widget.controller.workspaceDirectory;
      final allSessionsScope = widget.controller.allSessionsScope;
      if (workspaceDirectory == _observedWorkspaceDirectory &&
          allSessionsScope == _observedAllSessionsScope) {
        return;
      }
      _observedWorkspaceDirectory = workspaceDirectory;
      _observedAllSessionsScope = allSessionsScope;
      setState(() {});
    }
  }

  void _scheduleInitialLoad() {
    if (_loadRequested) return;
    _loadRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.isLive && _entries.isEmpty) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load([String? path]) async {
    if (!widget.controller.isLive) return;
    _loadRequested = true;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.controller.listWorkspace(path);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _path = path ?? widget.controller.workspaceDirectory;
        _entries = result;
        _selectedPaths.removeWhere(
          (selected) => !_entries.any((entry) => entry.path == selected),
        );
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadError = error.toString());
        _toast(error);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _newFolder() async {
    if (_path == null || _path == '@roots') return;
    final nameController = TextEditingController();
    final name = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('新建文件夹'),
        description: const Text('在当前主机目录下创建文件夹。'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ShadButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('创建'),
          ),
        ],
        child: ShadInput(
          controller: nameController,
          placeholder: const Text('文件夹名称'),
        ),
      ),
    );
    nameController.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await widget.controller.createWorkspaceDirectory(_path!, name);
      await _load(_path);
    } catch (error) {
      if (mounted) _toast(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final compact = MediaQuery.sizeOf(context).width < 420;
    if (!widget.controller.isLive) {
      return SizedBox.expand(
        key: Key('disconnected-files-page'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '文件',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 190),
                    child: SizedBox(
                      width: double.infinity,
                      height: 176,
                      child: const AgentEmptyState(
                        icon: LucideIcons.folderX,
                        title: '尚未连接主机',
                        description: '连接电脑后查看主机文件。',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (!_loadRequested && !_loading) {
      _scheduleInitialLoad();
    }
    final query = _query.toLowerCase();
    final entries = _entries
        .where((entry) => entry.name.toLowerCase().contains(query))
        .toList();
    final horizontalPadding = compact ? 14.0 : 18.0;
    final contentPadding = EdgeInsets.fromLTRB(
      horizontalPadding,
      compact ? 14 : 22,
      horizontalPadding,
      compact ? 16 : 24,
    );
    final headerItems = <Widget>[
      Text(
        '文件',
        style: compact
            ? Theme.of(context).textTheme.titleLarge
            : Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 5),
      Text(
        '浏览主机目录、预览文本并选择会话工作目录。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      SizedBox(height: compact ? 12 : 18),
      _WorkspaceHeader(
        path: _path ?? widget.controller.workspaceDirectory,
        allSessions: widget.controller.allSessionsScope,
        onSelect: (value) async {
          final path = widget.controller.workspaceDirectory;
          if (path != null) {
            await widget.controller.selectWorkspace(path, allSessions: value);
          }
        },
      ),
      const SizedBox(height: 12),
      ShadInput(
        controller: _search,
        onChanged: (value) => setState(() => _query = value),
        placeholder: const Text('搜索文件'),
        leading: const Icon(LucideIcons.search, size: 18),
      ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.start,
        spacing: 8,
        runSpacing: 8,
        children: [
          ShadButton.outline(
            key: const Key('file-refresh-button'),
            onPressed: _operating ? null : () => _load(_path),
            leading: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: ShadProgress(minHeight: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
            child: const Text('刷新'),
          ),
          ShadButton.outline(
            onPressed: _path == null || _path == '@roots' || _operating
                ? null
                : _newFolder,
            leading: const Icon(LucideIcons.folderPlus, size: 16),
            child: const Text('新建文件夹'),
          ),
          ShadButton.outline(
            key: const Key('file-selection-toggle'),
            onPressed: _operating
                ? null
                : () => setState(() {
                    _selectionMode = !_selectionMode;
                    _selectedPaths.clear();
                  }),
            leading: Icon(
              _selectionMode ? LucideIcons.x : LucideIcons.listChecks,
              size: 16,
            ),
            child: Text(_selectionMode ? '取消选择' : '选择'),
          ),
        ],
      ),
      if (_selectionMode) ...[
        const SizedBox(height: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已选 ${_selectedPaths.length} 个文件',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 7),
            Wrap(
              alignment: WrapAlignment.start,
              spacing: 8,
              runSpacing: 8,
              children: [
                ShadButton.outline(
                  key: const Key('select-all-files'),
                  onPressed: _operating
                      ? null
                      : () => setState(() {
                          final visibleFiles = entries
                              .where((item) => !item.isDirectory)
                              .map((item) => item.path)
                              .toList();
                          if (visibleFiles.every(_selectedPaths.contains)) {
                            _selectedPaths.removeAll(visibleFiles);
                          } else {
                            _selectedPaths.addAll(visibleFiles);
                          }
                        }),
                  leading: const Icon(LucideIcons.listChecks, size: 16),
                  child: const Text('全选当前文件'),
                ),
                ShadButton.outline(
                  key: const Key('download-selected-files'),
                  onPressed: _operating || _selectedPaths.isEmpty
                      ? null
                      : _downloadSelected,
                  leading: const Icon(LucideIcons.download, size: 16),
                  child: const Text('下载'),
                ),
                ShadButton.outline(
                  key: const Key('delete-selected-files'),
                  onPressed: _operating || _selectedPaths.isEmpty
                      ? null
                      : _deleteSelected,
                  leading: const Icon(LucideIcons.trash2, size: 16),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.start,
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_path != null && _path != '@roots')
            ShadButton.outline(
              onPressed: () => _load(_parentOf(_path!)),
              leading: const Icon(LucideIcons.arrowUp, size: 16),
              child: const Text('上一级'),
            ),
          ShadButton.outline(
            key: const Key('browse-file-roots'),
            onPressed: () => _load('@roots'),
            leading: const Icon(LucideIcons.hardDrive, size: 16),
            child: const Text('磁盘根目录'),
          ),
          if (_path != null && _path != '@roots')
            ShadButton.outline(
              onPressed: () async {
                try {
                  await widget.controller.selectWorkspace(
                    _path!,
                    allSessions: widget.controller.allSessionsScope,
                  );
                } catch (error) {
                  if (mounted) _toast(error);
                }
              },
              leading: const Icon(LucideIcons.folderCheck, size: 16),
              child: const Text('设为工作目录'),
            ),
        ],
      ),
      if (_path != null) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _path!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ];
    final showEmptyState = !_loading && entries.isEmpty;
    final emptyState = _loadError != null && _path == null
        ? AgentEmptyState(
            icon: LucideIcons.folderX,
            title: '目录读取失败',
            description: _loadError!,
          )
        : _path == null
        ? AgentEmptyState(
            icon: LucideIcons.folderOpen,
            title: '选择主机工作目录',
            description: '读取目录后可浏览文件或新建文件夹。',
          )
        : const AgentEmptyState(
            icon: LucideIcons.folderOpen,
            title: '目录为空',
            description: '可以创建文件夹，或打开其他目录。',
          );
    if (showEmptyState) headerItems.add(emptyState);
    if (_loading) {
      headerItems.add(
        Padding(
          key: const Key('file-list-loading'),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              const SizedBox(width: 120, child: ShadProgress()),
              const SizedBox(width: 12),
              Text('正在读取主机目录…', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    if (_loadError != null && _path != null) {
      headerItems.addAll([
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '目录读取失败：$_loadError',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: shadError),
          ),
        ),
      ]);
    }
    final headerCount = headerItems.length;
    return ListView.builder(
      key: const Key('files-page-scroll-view'),
      padding: contentPadding,
      itemCount: headerCount + entries.length,
      itemBuilder: (context, index) {
        if (index < headerCount) return headerItems[index];
        final entryIndex = index - headerCount;
        final entry = entries[entryIndex];
        return Padding(
          key: Key('file-entry-${entry.path}'),
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entryIndex > 0) const Divider(height: 1, indent: 42),
              _FileEntryTile(
                entry: entry,
                selectable: _selectionMode && !entry.isDirectory,
                selected: _selectedPaths.contains(entry.path),
                onSelect: (selected) => setState(() {
                  if (selected) {
                    _selectedPaths.add(entry.path);
                  } else {
                    _selectedPaths.remove(entry.path);
                  }
                }),
                onOpen: () => entry.isDirectory
                    ? _load(entry.path)
                    : _selectionMode
                    ? setState(() {
                        if (!_selectedPaths.remove(entry.path)) {
                          _selectedPaths.add(entry.path);
                        }
                      })
                    : _preview(entry),
              ),
            ],
          ),
        );
      },
    );
  }

  String _parentOf(String path) {
    if (RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(path)) return '@roots';
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index <= 0 ? '@roots' : normalized.substring(0, index);
  }

  List<HostFileEntry> get _selectedFiles => _entries
      .where(
        (entry) => !entry.isDirectory && _selectedPaths.contains(entry.path),
      )
      .toList(growable: false);

  Future<void> _downloadSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;
    setState(() => _operating = true);
    var downloaded = 0;
    try {
      for (final entry in files) {
        final file = await widget.controller.downloadWorkspaceFile(entry.path);
        if (kIsWeb) {
          final clientFile = XFile.fromData(
            file.bytes,
            name: file.name,
            mimeType: _mimeTypeForFile(file.name),
          );
          await clientFile.saveTo('');
        } else if (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS) {
          final savedPath = await saveBytesToLocalFile(
            name: file.name,
            bytes: file.bytes,
          );
          if (savedPath == null) {
            throw StateError('当前设备不支持保存文件。');
          }
          if (mounted) {
            ShadToaster.of(
              context,
            ).show(ShadToast(title: Text('已保存到 $savedPath')));
          }
        } else {
          final clientFile = XFile.fromData(
            file.bytes,
            name: file.name,
            mimeType: _mimeTypeForFile(file.name),
          );
          final location = await getSaveLocation(
            suggestedName: file.name,
            confirmButtonText: '保存',
          );
          if (!mounted || location == null) break;
          await clientFile.saveTo(location.path);
        }
        if (!mounted) break;
        downloaded++;
      }
      if (mounted && downloaded > 0) {
        ShadToaster.of(
          context,
        ).show(ShadToast(title: Text('已下载 $downloaded 个文件')));
      }
    } catch (error) {
      if (mounted) _toast(error);
    } finally {
      if (mounted) setState(() => _operating = false);
    }
  }

  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;
    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('删除 ${files.length} 个文件？'),
        description: const Text('此操作会直接从电脑删除所选普通文件，无法撤销。'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.pop(context, true),
            leading: const Icon(LucideIcons.trash2, size: 16),
            child: const Text('确认删除'),
          ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            child: Text(files.map((file) => file.name).join('\n')),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _operating = true);
    var deleted = 0;
    final errors = <String>[];
    for (final file in files) {
      try {
        await widget.controller.deleteWorkspaceFile(file.path);
        deleted++;
      } catch (error) {
        errors.add('${file.name}: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedPaths.clear();
      _operating = false;
    });
    await _load(_path);
    if (!mounted) return;
    if (errors.isNotEmpty) {
      _toast(
        StateError('已删除 $deleted 个文件；失败 ${errors.length} 个。${errors.first}'),
      );
    } else {
      ShadToaster.of(context).show(ShadToast(title: Text('已删除 $deleted 个文件')));
    }
  }

  Future<void> _preview(HostFileEntry entry) async {
    try {
      final content = await widget.controller.readWorkspaceFile(entry.path);
      if (!mounted) return;
      if (content.previewKind == 'unsupported') {
        _toast(StateError('此文件类型不支持预览。'));
        return;
      }
      final editor = TextEditingController(text: content.text ?? '');
      final media =
          content.previewKind == 'pdf' || content.previewKind == 'image';
      await showShadDialog<void>(
        context: context,
        builder: (context) {
          final viewport = MediaQuery.sizeOf(context);
          final previewWidth = (viewport.width - 32)
              .clamp(0.0, 680.0)
              .toDouble();
          return ShadDialog(
            title: Text(entry.name),
            description: Text(entry.path),
            actions: [
              ShadButton.outline(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
              if (!media)
                ShadButton(
                  leading: const Icon(LucideIcons.save, size: 16),
                  onPressed: () async {
                    try {
                      await widget.controller.writeWorkspaceFile(
                        entry.path,
                        editor.text,
                      );
                      if (context.mounted) Navigator.pop(context);
                      if (mounted) {
                        ShadToaster.of(
                          this.context,
                        ).show(const ShadToast(title: Text('文件已保存到电脑')));
                      }
                    } catch (error) {
                      if (mounted) _toast(error);
                    }
                  },
                  child: const Text('保存'),
                ),
            ],
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: previewWidth,
                maxHeight: viewport.height * .62,
              ),
              child: SizedBox(
                width: previewWidth,
                height: viewport.height * .58,
                child: content.previewKind == 'pdf'
                    ? (content.bytes == null
                          ? const _FilePreviewError()
                          : PdfViewer.data(
                              content.bytes!,
                              sourceName: entry.path,
                              params: PdfViewerParams(
                                loadingBannerBuilder: (_, _, _) => const Center(
                                  child: SizedBox(
                                    width: 120,
                                    child: ShadProgress(),
                                  ),
                                ),
                                errorBannerBuilder: (_, _, _, _) =>
                                    const _FilePreviewError(),
                              ),
                            ))
                    : content.previewKind == 'image'
                    ? (content.bytes == null
                          ? const _FilePreviewError()
                          : InteractiveViewer(
                              child: Image.memory(
                                content.bytes!,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    const _FilePreviewError(),
                              ),
                            ))
                    : ShadTextarea(
                        controller: editor,
                        minHeight: viewport.height * .52,
                        maxHeight: viewport.height * .52,
                      ),
              ),
            ),
          );
        },
      );
      editor.dispose();
    } catch (error) {
      if (mounted) _toast(error);
    }
  }

  void _toast(Object error) => ShadToaster.of(context).show(
    ShadToast(
      title: const Text('操作失败'),
      description: Text(error.toString().replaceFirst('Bad state: ', '')),
    ),
  );
}

String _mimeTypeForFile(String name) =>
    switch (name.toLowerCase().split('.').last) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'txt' || 'log' || 'md' => 'text/plain',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'css' => 'text/css',
      'js' || 'mjs' => 'text/javascript',
      'xml' => 'application/xml',
      _ => 'application/octet-stream',
    };

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.path,
    required this.allSessions,
    required this.onSelect,
  });
  final String? path;
  final bool allSessions;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) => GlassSurface(
    padding: const EdgeInsets.all(14),
    radius: 20,
    blur: 10,
    shadow: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.folderOpen, color: shadPrimary, size: 21),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                path ?? '主机工作目录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SessionScopeSelector(value: allSessions, onChanged: onSelect),
      ],
    ),
  );
}

class _FilePreviewError extends StatelessWidget {
  const _FilePreviewError();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Text('无法预览此文件。文件仍可下载。', textAlign: TextAlign.center),
    ),
  );
}

class _FileEntryTile extends StatelessWidget {
  const _FileEntryTile({
    required this.entry,
    required this.onOpen,
    this.selectable = false,
    this.selected = false,
    this.onSelect,
  });
  final HostFileEntry entry;
  final VoidCallback onOpen;
  final bool selectable;
  final bool selected;
  final ValueChanged<bool>? onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ShadButton.raw(
      variant: ShadButtonVariant.ghost,
      width: constraints.maxWidth,
      height: 44,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 9),
      mainAxisAlignment: MainAxisAlignment.start,
      onPressed: onOpen,
      child: SizedBox(
        width: (constraints.maxWidth - 22).clamp(0.0, double.infinity),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (selectable) ...[
              ShadCheckbox(
                value: selected,
                label: const SizedBox.shrink(),
                onChanged: (value) => onSelect?.call(value),
              ),
              const SizedBox(width: 8),
            ],
            Icon(
              entry.isDirectory ? LucideIcons.folder : LucideIcons.fileText,
              color: shadMuted,
              size: 18,
            ),
            const SizedBox(width: 11),
            Flexible(
              fit: FlexFit.tight,
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (!entry.isDirectory && entry.sizeBytes != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  _formatSize(entry.sizeBytes!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(width: 7),
            Icon(
              entry.isDirectory ? LucideIcons.chevronRight : LucideIcons.eye,
              color: shadMuted,
              size: 16,
            ),
          ],
        ),
      ),
    ),
  );
}

String _formatSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
