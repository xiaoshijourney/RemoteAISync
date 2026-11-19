import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../application/demo_controller.dart';
import '../../domain/models.dart';
import '../../domain/text_question_parser.dart';
import '../components/chat_components.dart';
import '../components/agent_brand_mark.dart';
import '../components/agent_interactions.dart';
import '../components/glass_surface.dart';
import '../components/session_scope_selector.dart';
import '../shad_theme.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({required this.controller, super.key});

  final DemoController controller;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final Map<String, XFile> _localFiles = {};
  final Set<String> _sendingSessionIds = <String>{};
  String? _activeAgentId;
  bool _creatingAgent = false;
  bool _refreshingSessions = false;
  final Set<String> _withdrawingQueuedIds = {};
  final Set<String> _answeredTextQuestionIds = {};
  final Set<String> _dismissedTextQuestionIds = {};
  final Set<String> _submittingTextQuestionIds = {};
  final Set<String> _openTextQuestionIds = {};
  String? _observedQuestionSessionId;
  String? _observedQuestionMessageId;
  String? _controlsSessionId;
  CodexControls? _controls;
  String? _controlsRequestSessionId;
  Future<CodexControls>? _controlsRequest;
  int _controlsGeneration = 0;
  String? _openCodeModel;
  String? _openCodeVariant;
  Timer? _controlsRefreshDebounce;
  Timer? _runningPoll;
  DateTime? _lastControlsRefresh;
  String? _observedFormId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_watchTextQuestion);
    _runningPoll = Timer.periodic(const Duration(seconds: 5), (_) {
      final sessionId = widget.controller.selectedSessionId;
      if (!mounted ||
          sessionId == null ||
          !widget.controller.isLive ||
          (_controls?.running != true &&
              widget.controller.selectedSessionState !=
                  SessionRunState.running)) {
        return;
      }
      if (widget.controller.sessions.any((item) => item.id == sessionId)) {
        _loadControls(sessionId, forceRefresh: true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _watchTextQuestion();
    });
  }

  @override
  void didUpdateWidget(covariant SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_watchTextQuestion);
    widget.controller.addListener(_watchTextQuestion);
    _observedQuestionSessionId = null;
    _observedQuestionMessageId = null;
    _controlsSessionId = null;
    _controls = null;
    _controlsRequestSessionId = null;
    _controlsRequest = null;
    _controlsGeneration++;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_watchTextQuestion);
    _runningPoll?.cancel();
    _controlsRefreshDebounce?.cancel();
    super.dispose();
  }

  TextChoiceQuestion? _currentTextQuestion() {
    final sessionId = widget.controller.selectedSessionId;
    if (!widget.controller.isLive ||
        sessionId == null ||
        (_activeAgentId != null &&
            !widget.controller.sessions.any(
              (session) =>
                  session.id == sessionId && session.agentId == _activeAgentId,
            )) ||
        widget.controller.forms.isNotEmpty) {
      return null;
    }
    final messages = widget.controller.messages;
    if (messages.isEmpty) return null;
    final question = parseTextChoiceQuestion(messages.last);
    if (question == null ||
        _answeredTextQuestionIds.contains('$sessionId:${question.messageId}') ||
        _dismissedTextQuestionIds.contains(
          '$sessionId:${question.messageId}',
        )) {
      return null;
    }
    return question;
  }

  void _watchTextQuestion() {
    final sessionId = widget.controller.selectedSessionId;
    if (sessionId != _controlsSessionId) {
      _controlsSessionId = sessionId;
      _controls = null;
      _openCodeModel = null;
      _openCodeVariant = null;
      final session = widget.controller.sessions.where(
        (item) => item.id == sessionId,
      );
      if (session.isNotEmpty &&
          (session.first.agentId == 'codex' ||
              session.first.agentId == 'opencode' ||
              session.first.agentId == 'claude')) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.controller.selectedSessionId == sessionId) {
            _loadControls(sessionId!);
          }
        });
      }
    } else if (sessionId != null &&
        widget.controller.sessions.any(
          (item) =>
              item.id == sessionId &&
              (item.agentId == 'opencode' ||
                  item.agentId == 'codex' ||
                  item.agentId == 'claude'),
        )) {
      final now = DateTime.now();
      if (_lastControlsRefresh == null ||
          now.difference(_lastControlsRefresh!) > const Duration(seconds: 1)) {
        _controlsRefreshDebounce?.cancel();
        _controlsRefreshDebounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted && widget.controller.selectedSessionId == sessionId) {
            _loadControls(sessionId);
          }
        });
      }
    }
    final pendingForm = widget.controller.forms.firstOrNull;
    if (pendingForm != null && pendingForm.id != _observedFormId) {
      _observedFormId = pendingForm.id;
      if ((MediaQuery.maybeOf(context)?.size.width ?? 1000) < 600) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.controller.forms.any(
                (item) => item.id == pendingForm.id,
              )) {
            _showAgentForm(pendingForm);
          }
        });
      }
    } else if (pendingForm == null) {
      _observedFormId = null;
    }
    final question = _currentTextQuestion();
    if (sessionId != _observedQuestionSessionId) {
      _observedQuestionSessionId = sessionId;
      _observedQuestionMessageId = question?.messageId;
      return;
    }
    if (question == null || question.messageId == _observedQuestionMessageId) {
      return;
    }
    _observedQuestionMessageId = question.messageId;
    if ((MediaQuery.maybeOf(context)?.size.width ?? 1000) >= 600) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.controller.selectedSessionId == sessionId &&
          _currentTextQuestion()?.messageId == question.messageId) {
        _showTextQuestion(question);
      }
    });
  }

  Future<void> _showAgentForm(AgentForm form) async {
    if (widget.controller.forms.every((item) => item.id != form.id)) return;
    await showShadDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        return ShadDialog(
          title: Text(form.title),
          description: const Text('请选择或填写后提交给 Agent。'),
          constraints: BoxConstraints(
            maxWidth: size.width < 520 ? size.width - 24 : 480,
            minWidth: 0,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * .68),
            child: SingleChildScrollView(
              child: AgentFormCard(
                form: form,
                onSubmit: (item, answer) async {
                  await widget.controller.replyToForm(item, answer);
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadControls(
    String sessionId, {
    bool forceRefresh = false,
  }) async {
    final controller = widget.controller;
    final generation = _controlsGeneration;
    try {
      final controls = await _requestControls(
        sessionId,
        forceRefresh: forceRefresh,
      );
      if (mounted &&
          generation == _controlsGeneration &&
          identical(controller, widget.controller) &&
          controller.selectedSessionId == sessionId) {
        _lastControlsRefresh = DateTime.now();
        setState(() {
          _controls = controls;
          final session = controller.sessions.firstWhere(
            (item) => item.id == sessionId,
          );
          if (session.agentId == 'opencode') {
            if (_openCodeModel == null ||
                !controls.models.any((model) => model.id == _openCodeModel)) {
              _openCodeModel = controls.model;
              _openCodeVariant = controls.effort;
            }
          }
        });
      }
    } catch (_) {
      // The conversation remains usable when catalog loading fails.
    }
  }

  Future<CodexControls> _requestControls(
    String sessionId, {
    bool forceRefresh = false,
  }) {
    if (_controlsSessionId == sessionId &&
        !forceRefresh &&
        _controls?.models.isNotEmpty == true) {
      return Future.value(_controls!);
    }
    if (_controlsRequestSessionId == sessionId && _controlsRequest != null) {
      return _controlsRequest!;
    }
    final request = widget.controller.loadCodexControls();
    _controlsRequestSessionId = sessionId;
    _controlsRequest = request;
    return request.whenComplete(() {
      if (identical(_controlsRequest, request)) {
        _controlsRequest = null;
        _controlsRequestSessionId = null;
      }
    });
  }

  Future<void> _showModelDialog() async {
    final targetSessionId = widget.controller.selectedSessionId;
    if (targetSessionId == null) return;
    CodexControls controls;
    try {
      controls = await _requestControls(targetSessionId);
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
      return;
    }
    if (!mounted || controls.models.isEmpty) return;
    final activeSession = widget.controller.sessions.firstWhere(
      (session) => session.id == targetSessionId,
    );
    final isClaude = activeSession.agentId == 'claude';
    final claudeModelController = TextEditingController(
      text: isClaude ? controls.model ?? '' : '',
    );
    final preferredModel = activeSession.agentId == 'opencode'
        ? _openCodeModel ?? controls.model
        : controls.model;
    final preferredEffort = activeSession.agentId == 'opencode'
        ? _openCodeVariant ?? controls.effort
        : controls.effort;
    var modelId = controls.models.any((model) => model.id == preferredModel)
        ? preferredModel!
        : controls.models.first.id;
    CodexModelOption chosenModel() =>
        controls.models.firstWhere((model) => model.id == modelId);
    String pickEffort(CodexModelOption model) {
      if (model.efforts.contains(preferredEffort)) return preferredEffort!;
      if (model.efforts.contains(model.defaultEffort)) {
        return model.defaultEffort!;
      }
      return model.efforts.isEmpty ? '' : model.efforts.first;
    }

    var effort = pickEffort(chosenModel());
    var saving = false;
    String? error;
    await showShadDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final viewportWidth = MediaQuery.sizeOf(dialogContext).width;
          return ShadDialog(
            title: const Text('模型与思考强度'),
            description: const Text('设置会应用到此会话的后续回复。'),
            constraints: BoxConstraints(
              maxWidth: viewportWidth < 512 ? viewportWidth - 32 : 480,
              minWidth: viewportWidth < 400 ? 0 : 320,
            ),
            actions: [
              ShadButton.outline(
                onPressed: saving
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              ShadButton(
                key: const Key('save-codex-settings'),
                onPressed:
                    saving ||
                        (chosenModel().efforts.isNotEmpty && effort.isEmpty)
                    ? null
                    : () async {
                        setDialogState(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          if (widget.controller.selectedSessionId !=
                              targetSessionId) {
                            throw StateError('会话已切换，请重新打开模型设置。');
                          }
                          final active = widget.controller.sessions.firstWhere(
                            (session) => session.id == targetSessionId,
                          );
                          if (active.agentId == 'codex') {
                            await widget.controller.updateCodexSettings(
                              model: modelId,
                              effort: effort,
                            );
                          } else if (active.agentId == 'opencode') {
                            setState(() {
                              _openCodeModel = modelId;
                              _openCodeVariant = effort.isEmpty ? null : effort;
                              _controls = CodexControls(
                                models: controls.models,
                                skills: controls.skills,
                                model: modelId,
                                effort: effort.isEmpty ? null : effort,
                                running: controls.running,
                              );
                            });
                          } else if (active.agentId == 'claude') {
                            await widget.controller.updateClaudeSettings(
                              model: claudeModelController.text.trim(),
                              effort: effort,
                            );
                          }
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          if (widget.controller.selectedSessionId ==
                                  targetSessionId &&
                              (active.agentId == 'codex' ||
                                  active.agentId == 'claude')) {
                            _loadControls(targetSessionId);
                          }
                        } catch (exception) {
                          if (dialogContext.mounted) {
                            setDialogState(() => error = '$exception');
                          }
                        } finally {
                          if (dialogContext.mounted) {
                            setDialogState(() => saving = false);
                          }
                        }
                      },
                child: const Text('保存'),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('模型', style: Theme.of(dialogContext).textTheme.labelLarge),
                const SizedBox(height: 6),
                if (isClaude)
                  ShadInput(
                    key: const Key('claude-model-input'),
                    controller: claudeModelController,
                    placeholder: const Text('沿用默认模型，或输入 sonnet / opus / 模型 ID'),
                    autocorrect: false,
                  )
                else
                  ShadSelect<String>(
                    key: const Key('codex-model-select'),
                    initialValue: modelId,
                    minWidth: 0,
                    options: [
                      for (final model in controls.models)
                        ShadOption(value: model.id, child: Text(model.name)),
                    ],
                    selectedOptionBuilder: (_, value) => Text(
                      controls.models
                          .firstWhere((model) => model.id == value)
                          .name,
                    ),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        modelId = value;
                        effort = pickEffort(chosenModel());
                      });
                    },
                  ),
                const SizedBox(height: 12),
                const SizedBox(height: 14),
                Text(
                  '思考强度',
                  style: Theme.of(dialogContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                if (chosenModel().efforts.isEmpty)
                  const Text(
                    '该模型没有提供可选的思考强度。',
                    style: TextStyle(color: shadMuted, fontSize: 12),
                  )
                else
                  ShadSelect<String>(
                    key: ValueKey('codex-effort-select-$modelId'),
                    initialValue: effort.isEmpty ? null : effort,
                    minWidth: 0,
                    options: [
                      for (final value in chosenModel().efforts)
                        ShadOption(value: value, child: Text(value)),
                    ],
                    selectedOptionBuilder: (_, value) => Text(value),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => effort = value);
                    },
                  ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: shadError)),
                ],
              ],
            ),
          );
        },
      ),
    );
    claudeModelController.dispose();
  }

  Future<void> _interruptSelectedSession() async {
    try {
      await widget.controller.interruptSelectedSession();
      if (mounted) {
        ShadToaster.of(context).show(const ShadToast(title: Text('已请求停止当前生成')));
      }
      final sessionId = widget.controller.selectedSessionId;
      if (sessionId != null && sessionId.startsWith('codex:')) {
        _loadControls(sessionId, forceRefresh: true);
      }
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    }
  }

  Future<void> _runCodexAction(String action) async {
    try {
      await widget.controller.runCodexAction(action);
      if (mounted) {
        ShadToaster.of(context).show(
          ShadToast(
            title: Text(action == 'compact' ? '已开始整理上下文' : '已开始审查当前改动'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    }
  }

  Future<void> _showTextQuestion(TextChoiceQuestion question) async {
    final sessionId = widget.controller.selectedSessionId;
    if (sessionId == null) return;
    final key = '$sessionId:${question.messageId}';
    if (!_openTextQuestionIds.add(key)) return;
    try {
      await showShadDialog<void>(
        context: context,
        builder: (dialogContext) => ShadDialog(
          title: const Text('识别到文字选择题'),
          description: const Text('请选择答案并提交给当前 Agent。'),
          constraints: const BoxConstraints(maxWidth: 560),
          child: AgentQuestionnaire(
            title: '选择答案',
            prompt: question.prompt,
            options: [
              for (final option in question.options)
                AgentQuestionOption(value: option.reply, label: option.reply),
            ],
            onSubmit: (value) async {
              final sent = await _replyToTextQuestion(question, value);
              if (sent && dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
          ),
        ),
      );
    } finally {
      _openTextQuestionIds.remove(key);
    }
  }

  Future<bool> _replyToTextQuestion(
    TextChoiceQuestion question,
    String answer,
  ) async {
    final sessionId = widget.controller.selectedSessionId;
    if (sessionId == null ||
        _currentTextQuestion()?.messageId != question.messageId) {
      return false;
    }
    final key = '$sessionId:${question.messageId}';
    if (!_submittingTextQuestionIds.add(key)) return false;
    if (mounted) {
      setState(() {
        _answeredTextQuestionIds.add(key);
        _dismissedTextQuestionIds.add(key);
      });
    }
    try {
      final error = await _sendMessage(answer, const []);
      if (error != null) {
        if (mounted) {
          setState(() {
            _answeredTextQuestionIds.remove(key);
            _dismissedTextQuestionIds.remove(key);
          });
          ShadToaster.of(context).show(ShadToast(title: Text(error)));
        }
        return false;
      }
      return true;
    } finally {
      _submittingTextQuestionIds.remove(key);
    }
  }

  Future<void> _refreshSessions() async {
    if (_refreshingSessions) return;
    setState(() => _refreshingSessions = true);
    try {
      await widget.controller.refreshSessions();
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _refreshingSessions = false);
    }
  }

  Future<void> _refreshSelectedSession() async {
    try {
      await widget.controller.refreshSelectedSession();
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    }
  }

  Future<void> _createAgentSession(String agentId) async {
    await _createAgentSessionAtDirectory(
      agentId,
      directory: widget.controller.workspaceDirectory,
    );
  }

  Future<void> _createCodexDefaultSession() =>
      _createAgentSessionAtDirectory('codex', useDefaultDirectory: true);

  Future<void> _createAgentSessionAtDirectory(
    String agentId, {
    String? directory,
    bool useDefaultDirectory = false,
  }) async {
    if (_creatingAgent) return;
    setState(() {
      _activeAgentId = agentId;
      _creatingAgent = true;
    });
    try {
      await widget.controller.createAgentSession(
        agentId,
        directory: directory,
        useDefaultDirectory: useDefaultDirectory,
      );
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _creatingAgent = false);
    }
  }

  void _selectAgent(String agentId) {
    if (!widget.controller.isLive) return;
    setState(() => _activeAgentId = agentId);
    final sessions = widget.controller.sessions
        .where((session) => session.agentId == agentId)
        .toList(growable: false);
    if (sessions.isEmpty) return;
    final current = sessions.where(
      (session) => session.id == widget.controller.selectedSessionId,
    );
    final target = current.isEmpty ? sessions.first : current.first;
    if (target.id != widget.controller.selectedSessionId) {
      unawaited(widget.controller.selectSession(target).catchError((_) {}));
    }
  }

  List<Widget> _buildMessageTimeline(
    List<AgentMessage> messages, {
    required String? sessionId,
  }) {
    final widgets = <Widget>[];
    final groupedToolIndexes = <int>{};
    var index = 0;
    while (index < messages.length) {
      if (groupedToolIndexes.contains(index)) {
        index++;
        continue;
      }
      final message = messages[index];
      if (message.author == MessageAuthor.tool) {
        final groupId = message.groupId;
        final group = <AgentMessage>[];
        if (groupId != null && groupId.isNotEmpty) {
          for (
            var candidate = index;
            candidate < messages.length;
            candidate++
          ) {
            final item = messages[candidate];
            if (item.author == MessageAuthor.tool && item.groupId == groupId) {
              group.add(item);
              if (candidate != index) groupedToolIndexes.add(candidate);
            }
          }
          index++;
        } else {
          while (index < messages.length &&
              messages[index].author == MessageAuthor.tool &&
              messages[index].groupId == null) {
            group.add(messages[index]);
            index++;
          }
        }
        widgets.add(
          AgentToolCallGroup(
            key: ValueKey('tool-group-$sessionId-${group.first.id}'),
            messages: group,
          ),
        );
        if (widget.controller.isDemo && group.any((item) => item.id == 'm2')) {
          widgets.add(const SizedBox(height: 5));
          widgets.add(
            _ApprovalPanel(
              approval: widget.controller.approval,
              onAllow: () => widget.controller.resolveApproval(allow: true),
              onDeny: () => widget.controller.resolveApproval(allow: false),
            ),
          );
          widgets.add(const SizedBox(height: 14));
        }
        continue;
      }
      widgets.add(
        AgentMessageTile(
          key: ValueKey('$sessionId-${message.id}'),
          message: message,
          agentId: _activeAgentId ?? 'opencode',
          onOpenAttachment: _openAttachment,
        ),
      );
      index++;
    }
    return widgets;
  }

  void _selectHistorySession(HostSession session) {
    setState(() => _activeAgentId = session.agentId);
    unawaited(widget.controller.selectSession(session).catchError((_) {}));
  }

  Future<void> _withdrawQueuedMessage(AgentQueuedMessage queued) async {
    if (!_withdrawingQueuedIds.add(queued.id)) return;
    final sessionId = widget.controller.selectedSessionId;
    setState(() {});
    try {
      await widget.controller.withdrawQueuedMessage(
        queued,
        expectedSessionId: sessionId,
      );
      if (mounted) {
        ShadToaster.of(context).show(const ShadToast(title: Text('已撤回排队消息')));
      }
    } catch (error) {
      if (mounted) {
        ShadToaster.of(context).show(ShadToast(title: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _withdrawingQueuedIds.remove(queued.id));
    }
  }

  Future<String?> _sendMessage(
    String text,
    List<_SelectedAttachment> selected,
  ) async {
    final sessionId = widget.controller.selectedSessionId;
    if (sessionId != null && widget.controller.isLive) {
      setState(() => _sendingSessionIds.add(sessionId));
    }
    try {
      final queueToDesktop = widget.controller.sessions.any(
        (session) =>
            session.id == widget.controller.selectedSessionId &&
            session.agentId == 'codex' &&
            !session.remoteManaged,
      );
      final error = await widget.controller.sendReply(
        text,
        attachments: selected.map((item) => item.attachment).toList(),
        files: selected.map((item) => item.file).toList(),
        model:
            widget.controller.sessions.any(
              (session) =>
                  session.id == widget.controller.selectedSessionId &&
                  session.agentId == 'opencode',
            )
            ? _openCodeModel
            : null,
        effort:
            widget.controller.sessions.any(
              (session) =>
                  session.id == widget.controller.selectedSessionId &&
                  session.agentId == 'opencode',
            )
            ? _openCodeVariant
            : null,
      );
      if (error != null) return error;
      for (final item in selected) {
        _localFiles[item.attachment.id] = item.file;
      }
      if (queueToDesktop && mounted) {
        ShadToaster.of(context).show(
          ShadToast(
            title: Text(
              widget.controller.lastReplyWasQueued
                  ? '已排队到 Codex 桌面会话'
                  : '已发送到 Codex 桌面会话',
            ),
            description: Text(
              widget.controller.lastReplyWasQueued
                  ? 'Codex 桌面会话当前由另一进程控制，空闲后会处理此消息。'
                  : 'Codex 已接收这条消息。',
            ),
          ),
        );
      }
      return null;
    } finally {
      if (mounted && sessionId != null) {
        setState(() => _sendingSessionIds.remove(sessionId));
      }
    }
  }

  void _openAttachment(AgentAttachment attachment) {
    final file = _localFiles[attachment.id];
    if (file == null || !isAgentAttachmentPreviewable(attachment.name)) return;
    _showAttachmentPreview(context, attachment, file);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final selected = widget.controller.sessions.where(
          (session) => session.id == widget.controller.selectedSessionId,
        );
        final selectedSession = selected.isEmpty ? null : selected.first;
        final activeAgentId =
            _activeAgentId ??
            selectedSession?.agentId ??
            (widget.controller.codexVersion != null ? 'codex' : 'opencode');
        final activeSession = selectedSession?.agentId == activeAgentId
            ? selectedSession
            : null;
        final selectedAgent = _agentName(activeAgentId);
        final otherPending = widget.controller.sessions
            .where(
              (session) =>
                  session.id != widget.controller.selectedSessionId &&
                  session.pendingCount > 0,
            )
            .fold<int>(0, (total, session) => total + session.pendingCount);
        final isDemo = widget.controller.isDemo;
        final isLive = widget.controller.isLive;
        final isDesktopCodex =
            isLive &&
            activeSession?.agentId == 'codex' &&
            !activeSession!.remoteManaged;
        final isManagedCodex =
            isLive &&
            activeSession?.agentId == 'codex' &&
            activeSession!.remoteManaged;
        final capabilities = activeSession == null
            ? null
            : AgentCapabilityProfile.forSession(activeSession);
        final canReply = capabilities?.canReply ?? false;
        final canInterrupt = capabilities?.canInterrupt ?? false;
        final canChangeModel = capabilities?.canChangeSettings ?? false;
        final isThinking =
            _sendingSessionIds.contains(activeSession?.id) ||
            _controls?.running == true ||
            widget.controller.selectedSessionState == SessionRunState.running;
        final visibleMessages = isLive && activeSession == null
            ? const <AgentMessage>[]
            : widget.controller.messages;
        final textQuestion = _currentTextQuestion();
        return Column(
          children: [
            _AgentSessionHeader(
              controller: widget.controller,
              activeAgentId: activeAgentId,
              selectedSessionId: activeSession?.id,
              isRefreshing: _refreshingSessions,
              isCreating: _creatingAgent,
              onAgentSelected: _selectAgent,
              onHistorySelected: _selectHistorySession,
              onRefresh: _refreshSessions,
              onCreate: _createAgentSession,
              onCreateCodexDefaultDirectory: _createCodexDefaultSession,
            ),
            Expanded(
              child: AgentMessageScroller(
                sessionKey: activeSession?.id,
                messageCount:
                    visibleMessages.length +
                    widget.controller.forms.length +
                    widget.controller.permissions.length +
                    widget.controller.queuedMessages.length,
                children: [
                  if (!isLive && isDemo) ...[
                    const _DemoNotice(),
                  ] else if (!isLive) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                        child: Text(
                          widget.controller.connectionError ?? '尚未连接主机',
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: shadMuted),
                        ),
                      ),
                    ),
                  ] else if (activeSession == null) ...[
                    AgentEmptyState(
                      mark: _agentMark(activeAgentId),
                      title: _agentUnavailableTitle(
                        activeAgentId,
                        widget.controller,
                      ),
                      description: _agentUnavailableDescription(
                        activeAgentId,
                        widget.controller,
                      ),
                    ),
                  ],
                  if (isLive &&
                      activeSession != null &&
                      MediaQuery.sizeOf(context).width >= 600) ...[
                    _SessionSummary(
                      title: activeSession.title,
                      subtitle:
                          '$selectedAgent ${_agentVersion(activeAgentId, widget.controller)}',
                      isLive: true,
                    ),
                    const SizedBox(height: 14),
                  ] else if (isDemo) ...[
                    const _SessionSummary(
                      title: 'OpenCode',
                      subtitle: 'remotaisync-demo · 本地样例会话',
                      isLive: false,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (isLive && otherPending > 0) ...[
                    ShadAlert(
                      icon: const Icon(LucideIcons.bellRing),
                      title: const Text('其他会话有待处理请求'),
                      description: Text(
                        '共 $otherPending 项提问或审批等待处理。请从上方历史会话切换。',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ..._buildMessageTimeline(
                    visibleMessages,
                    sessionId: activeSession?.id,
                  ),
                  if (activeSession?.agentId == 'codex' &&
                      widget.controller.queueWarning != null) ...[
                    ShadAlert(
                      icon: const Icon(LucideIcons.triangleAlert),
                      title: const Text('Codex 队列状态暂不可确认'),
                      description: Text(
                        '下方队列可能不是最新结果：${widget.controller.queueWarning}',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (activeSession?.agentId == 'codex')
                    for (final queued in widget.controller.queuedMessages) ...[
                      ShadAlert(
                        key: ValueKey('queued-message-${queued.id}'),
                        icon: const Icon(LucideIcons.clock3),
                        title: const Text('等待 Codex 桌面端消费'),
                        description: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              queued.imageCount == 0
                                  ? queued.text
                                  : '${queued.text}\n附带 ${queued.imageCount} 张图片',
                            ),
                            const SizedBox(height: 8),
                            ShadButton.outline(
                              key: Key('refresh-queued-${queued.id}'),
                              onPressed: _refreshSelectedSession,
                              leading: const Icon(
                                LucideIcons.refreshCw,
                                size: 16,
                              ),
                              child: const Text('刷新状态'),
                            ),
                            const SizedBox(height: 8),
                            ShadButton.outline(
                              key: Key('withdraw-queued-${queued.id}'),
                              onPressed:
                                  _withdrawingQueuedIds.contains(queued.id)
                                  ? null
                                  : () => _withdrawQueuedMessage(queued),
                              leading: const Icon(LucideIcons.undo2, size: 16),
                              child: const Text('撤回'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  if (widget.controller.isLive &&
                      activeSession != null &&
                      widget.controller.forms.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final form in widget.controller.forms) ...[
                      AgentFormCard(
                        key: ValueKey('live-form-${form.id}'),
                        form: form,
                        onSubmit: widget.controller.replyToForm,
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                  if (widget.controller.isLive &&
                      activeSession != null &&
                      widget.controller.permissions.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    for (final permission in widget.controller.permissions) ...[
                      AgentPermissionCard(
                        key: ValueKey('live-permission-${permission.id}'),
                        permission: permission,
                        onResolve: (item, allow) => widget.controller
                            .replyToPermission(item, allow: allow),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                  if (textQuestion != null) ...[
                    ShadAlert(
                      icon: const Icon(LucideIcons.listChecks),
                      title: const Text('Agent 正在等待选择'),
                      description: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(textQuestion.prompt),
                          const SizedBox(height: 8),
                          ShadButton.outline(
                            key: Key(
                              'open-text-question-${textQuestion.messageId}',
                            ),
                            onPressed: () => _showTextQuestion(textQuestion),
                            leading: const Icon(
                              LucideIcons.listChecks,
                              size: 16,
                            ),
                            child: const Text('选择答案'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (widget.controller.isLive &&
                      activeSession != null &&
                      visibleMessages.isEmpty) ...[
                    if (widget.controller.sessionLoaded)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Text(
                            isDesktopCodex
                                ? '会话还没有消息 · 在下方输入即可发送'
                                : '会话还没有消息 · 在下方输入即可开始',
                            textAlign: TextAlign.center,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: shadMuted),
                          ),
                        ),
                      )
                    else
                      const _LoadingMessages(),
                  ],
                  if (widget.controller.isDemo &&
                      widget.controller.selectedPort == null) ...[
                    const SizedBox(height: 2),
                    AgentQuestionnaire(
                      title: '选项确认',
                      prompt: '请选择本地预览服务使用的端口。',
                      options: const [
                        AgentQuestionOption(value: '4173', label: '使用 4173'),
                        AgentQuestionOption(value: '3000', label: '使用 3000'),
                      ],
                      customPlaceholder: '其他端口',
                      customValidator: (value) {
                        final port = int.tryParse(value);
                        return port == null || port < 1 || port > 65535
                            ? '端口需为 1–65535'
                            : null;
                      },
                      onSubmit: widget.controller.choosePort,
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _MessageComposer(
              onSend: _sendMessage,
              onModelCommand: _showModelDialog,
              onStopCommand: _interruptSelectedSession,
              onActionCommand: (action) => unawaited(_runCodexAction(action)),
              skills: _controls?.skills ?? const [],
              codexControlsEnabled: isManagedCodex,
              modelControlsEnabled: canChangeModel,
              canInterrupt: canInterrupt,
              thinking: isThinking,
              modelLabel: _controls?.model == null
                  ? '模型 / 思考'
                  : '${_controls!.model} · ${_controls!.effort ?? '默认'}',
              placeholder: isDesktopCodex
                  ? '发送到 Codex 桌面会话…'
                  : activeSession != null && !canReply
                  ? '此历史会话只支持查看…'
                  : activeSession == null
                  ? '先选择或新建一个会话…'
                  : '回复 $selectedAgent…',
              queueMode: isDesktopCodex,
              enabled:
                  (isDemo && activeAgentId == 'opencode') ||
                  (isLive && activeSession != null && canReply),
            ),
          ],
        );
      },
    );
  }
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice();

  @override
  Widget build(BuildContext context) {
    return const ShadAlert(
      icon: Icon(LucideIcons.info),
      title: Text('本地演示'),
      description: Text('尚未连接电脑。回复和审批只更新本地界面。'),
    );
  }
}

String _agentName(String id) => switch (id) {
  'codex' => 'Codex',
  'opencode' => 'OpenCode',
  'claude' => 'Claude Code',
  _ => id,
};

String _agentVersion(String id, DemoController controller) => switch (id) {
  'codex' => controller.codexVersion ?? '',
  'opencode' => controller.hostVersion ?? '',
  'claude' => controller.agentStatus('claude')?.version ?? '',
  _ => '',
};

Widget _agentMark(String id) {
  return AgentBrandMark(
    key: Key('agent-empty-mark-$id'),
    agentId: id,
    size: 22,
  );
}

String _agentUnavailableTitle(String id, DemoController controller) {
  if (!controller.isLive) return '选择或新建一个会话';
  final status = controller.agentStatus(id);
  if (status?.availability == AgentAvailability.unsupported) {
    return '${_agentName(id)} 尚未接入';
  }
  if (status?.availability == AgentAvailability.degraded) {
    return '${_agentName(id)} 连接异常';
  }
  if (status?.availability == AgentAvailability.notInstalled) {
    return '${_agentName(id)} 未安装';
  }
  if (status?.availability == AgentAvailability.unavailable ||
      (status == null && _agentVersion(id, controller).isEmpty)) {
    return '主机未检测到 ${_agentName(id)}';
  }
  if (status?.availability == AgentAvailability.unknown) {
    return '${_agentName(id)} 状态未知';
  }
  if (controller.sessions.any((session) => session.agentId == id)) {
    return '选择一条历史会话';
  }
  return '暂无历史会话';
}

String _agentUnavailableDescription(String id, DemoController controller) {
  if (!controller.isLive) return '连接电脑主机后即可读取历史会话或开始新对话。';
  final status = controller.agentStatus(id);
  if (status?.detail?.isNotEmpty == true) return status!.detail!;
  if (status?.availability == AgentAvailability.unsupported) {
    return '${_agentName(id)} 当前尚未接入 RemoteAISync。';
  }
  if (status?.availability == AgentAvailability.notInstalled) {
    return '电脑主机没有安装 ${_agentName(id)}，可在主机模式的“Agent 状态”页打开官方安装页面。';
  }
  if (status?.availability == AgentAvailability.unavailable ||
      (status == null && _agentVersion(id, controller).isEmpty)) {
    return '检查电脑端 ${_agentName(id)} 是否已启动，然后刷新主机状态。';
  }
  if (status?.availability == AgentAvailability.unknown) {
    return '主机没有提供此 Agent 的状态，请重启电脑端服务后刷新。';
  }
  if (controller.sessions.any((session) => session.agentId == id)) {
    return '从上方历史会话中选择一条，消息内容会显示在这里。';
  }
  return '点击上方“新建”开始一个远程会话。';
}

class _AgentSessionHeader extends StatefulWidget {
  const _AgentSessionHeader({
    required this.controller,
    required this.activeAgentId,
    required this.selectedSessionId,
    required this.isRefreshing,
    required this.isCreating,
    required this.onAgentSelected,
    required this.onHistorySelected,
    required this.onRefresh,
    required this.onCreate,
    required this.onCreateCodexDefaultDirectory,
  });

  final DemoController controller;
  final String activeAgentId;
  final String? selectedSessionId;
  final bool isRefreshing;
  final bool isCreating;
  final ValueChanged<String> onAgentSelected;
  final ValueChanged<HostSession> onHistorySelected;
  final VoidCallback onRefresh;
  final ValueChanged<String> onCreate;
  final VoidCallback onCreateCodexDefaultDirectory;

  @override
  State<_AgentSessionHeader> createState() => _AgentSessionHeaderState();
}

class _AgentSessionHeaderState extends State<_AgentSessionHeader>
    with SingleTickerProviderStateMixin {
  static const _agents = <_AgentChoice>[
    _AgentChoice(id: 'codex', label: 'Codex', background: shadMutedBackground),
    _AgentChoice(
      id: 'opencode',
      label: 'OpenCode',
      background: shadMutedBackground,
    ),
    _AgentChoice(
      id: 'claude',
      label: 'Claude Code',
      background: shadMutedBackground,
    ),
  ];

  bool _controlsExpanded = false;
  bool _controlsInitialized = false;
  late final AnimationController _controlsAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controlsInitialized) return;
    _controlsExpanded = MediaQuery.sizeOf(context).width >= 440;
    _controlsAnimation.value = _controlsExpanded ? 1 : 0;
    _controlsInitialized = true;
  }

  @override
  void dispose() {
    _controlsAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final activeAgentId = widget.activeAgentId;
    final selectedSessionId = widget.selectedSessionId;
    final isRefreshing = widget.isRefreshing;
    final isCreating = widget.isCreating;
    final onAgentSelected = widget.onAgentSelected;
    final onHistorySelected = widget.onHistorySelected;
    final onRefresh = widget.onRefresh;
    final onCreate = widget.onCreate;
    final onCreateCodexDefaultDirectory = widget.onCreateCodexDefaultDirectory;
    final compact = MediaQuery.sizeOf(context).width < 440;
    final showSessionControls = _controlsExpanded;
    final sessions = controller.sessions
        .where(
          (session) =>
              session.agentId == activeAgentId &&
              (controller.allSessionsScope ||
                  session.directory == null ||
                  session.directory == controller.workspaceDirectory),
        )
        .toList(growable: false);
    final runtimeStatus = controller.agentStatus(activeAgentId);
    final isAvailable =
        controller.isLive &&
        (runtimeStatus?.isAvailable ??
            _agentVersion(activeAgentId, controller).isNotEmpty);
    final canCreate = isAvailable;
    final serviceLabel = switch (controller.connectionStatus) {
      HostConnectionStatus.connected => '主机在线',
      HostConnectionStatus.connecting => '正在连接',
      HostConnectionStatus.error => '连接异常',
      HostConnectionStatus.disconnected => controller.isDemo ? '本地演示' : '未连接',
    };
    final serviceColor = switch (controller.connectionStatus) {
      HostConnectionStatus.connected => shadSuccess,
      HostConnectionStatus.connecting => shadWarning,
      HostConnectionStatus.error => shadError,
      HostConnectionStatus.disconnected => shadMuted,
    };
    final serviceBackground = switch (controller.connectionStatus) {
      HostConnectionStatus.connected => const Color(0xFFEAF7EF),
      HostConnectionStatus.connecting => const Color(0xFFFFF7E6),
      HostConnectionStatus.error => const Color(0xFFFEF0EF),
      HostConnectionStatus.disconnected => shadMutedBackground,
    };
    final sessionState = controller.selectedSessionState;
    final sessionStateLabel = switch (sessionState) {
      SessionRunState.loading => '正在读取',
      SessionRunState.running => '生成中',
      SessionRunState.waitingInput => '等待回答',
      SessionRunState.waitingApproval => '等待审批',
      SessionRunState.queued => '消息排队中',
      SessionRunState.failed => '执行失败',
      SessionRunState.stopped => '已停止',
      SessionRunState.stale => '状态过期',
      SessionRunState.idle => null,
    };

    return GlassSurface(
      radius: 20,
      blur: 14,
      margin: EdgeInsets.fromLTRB(8, compact ? 2 : 6, 8, 0),
      padding: EdgeInsets.fromLTRB(8, compact ? 4 : 8, 8, compact ? 5 : 8),
      shadow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('会话', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                ShadBadge(
                  backgroundColor: serviceBackground,
                  foregroundColor: serviceColor,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        controller.isLive
                            ? LucideIcons.circleCheck
                            : LucideIcons.circle,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      Text(serviceLabel),
                    ],
                  ),
                ),
                if (selectedSessionId != null && sessionStateLabel != null) ...[
                  const SizedBox(width: 6),
                  ShadBadge.secondary(child: Text(sessionStateLabel)),
                ],
              ],
            ),
          if (!compact) const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 440;
              final tileGap = compact ? 5.0 : 8.0;
              final tileWidth = compact
                  ? ((constraints.maxWidth - tileGap * (_agents.length - 1)) /
                            _agents.length)
                        .clamp(0.0, double.infinity)
                  : 158.0;
              if (tileWidth <= 0) return const SizedBox(height: 52);
              return Row(
                key: const Key('agent-picker-scroll'),
                children: [
                  for (var index = 0; index < _agents.length; index++) ...[
                    if (index > 0) SizedBox(width: tileGap),
                    SizedBox(
                      width: tileWidth,
                      child: Builder(
                        builder: (context) {
                          final agent = _agents[index];
                          final version = _agentVersion(agent.id, controller);
                          final count = controller.sessions
                              .where((session) => session.agentId == agent.id)
                              .length;
                          final runtime = controller.agentStatus(agent.id);
                          final ready =
                              controller.isLive &&
                              (runtime?.isAvailable ?? version.isNotEmpty);
                          final status = !controller.isLive
                              ? controller.isDemo && agent.id == 'opencode'
                                    ? '演示'
                                    : '未连接'
                              : switch (runtime?.availability) {
                                  AgentAvailability.available => '在线 · $count',
                                  AgentAvailability.degraded => '连接异常',
                                  AgentAvailability.notInstalled => '未安装',
                                  AgentAvailability.unavailable => '探测不到',
                                  AgentAvailability.unsupported => '未接入',
                                  AgentAvailability.unknown => '状态未知',
                                  null => ready ? '在线 · $count' : '未发现',
                                };
                          return _AgentChoiceTile(
                            agent: agent,
                            width: tileWidth,
                            compact: compact,
                            stacked: compact && tileWidth < 104,
                            selected: activeAgentId == agent.id,
                            enabled: controller.isLive,
                            status: status,
                            available: ready,
                            onTap: () => onAgentSelected(agent.id),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          if (compact)
            Center(
              child: ShadButton.ghost(
                key: const Key('toggle-session-controls'),
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: () => setState(() {
                  _controlsExpanded = !_controlsExpanded;
                  if (_controlsExpanded) {
                    _controlsAnimation.forward();
                  } else {
                    _controlsAnimation.reverse();
                  }
                }),
                leading: AnimatedRotation(
                  turns: showSessionControls ? .5 : 0,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: const Icon(LucideIcons.chevronDown, size: 15),
                ),
                child: Text(showSessionControls ? '收起会话工具' : '历史会话与工具'),
              ),
            ),
          AnimatedBuilder(
            key: const Key('session-controls-region'),
            animation: _controlsAnimation,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: sessions.isEmpty
                          ? Container(
                              height: 40,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                              ),
                              decoration: BoxDecoration(
                                color: shadMutedBackground,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: shadLine),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    LucideIcons.history,
                                    size: 15,
                                    color: shadMuted,
                                  ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      !controller.isLive
                                          ? '连接主机后查看历史'
                                          : activeAgentId == 'claude' &&
                                                !isAvailable
                                          ? 'Claude Code 不可用'
                                          : '暂无历史会话',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : KeyedSubtree(
                              key: ValueKey('history-$activeAgentId'),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 420,
                                  ),
                                  child: _SessionPicker(
                                    sessions: sessions,
                                    selectedId: selectedSessionId,
                                    onSelected: onHistorySelected,
                                  ),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 5),
                    Tooltip(
                      message: '刷新历史会话',
                      child: ShadIconButton.ghost(
                        key: const Key('refresh-sessions'),
                        onPressed: controller.isLive && !isRefreshing
                            ? onRefresh
                            : null,
                        icon: isRefreshing
                            ? const SizedBox(
                                width: 18,
                                child: ShadProgress(minHeight: 2),
                              )
                            : const Icon(LucideIcons.refreshCw),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Tooltip(
                      message: activeAgentId == 'claude'
                          ? '新建 Claude Code 对话'
                          : !controller.isLive
                          ? '先连接电脑主机'
                          : '新建${_agentName(activeAgentId)}对话',
                      child: ShadButton(
                        key: Key('create-$activeAgentId-session'),
                        onPressed: canCreate && !isCreating
                            ? () => onCreate(activeAgentId)
                            : null,
                        leading: isCreating
                            ? const SizedBox(
                                width: 16,
                                child: ShadProgress(minHeight: 2),
                              )
                            : const Icon(LucideIcons.plus, size: 16),
                        child: const Text('新建'),
                      ),
                    ),
                    if (activeAgentId == 'codex') ...[
                      const SizedBox(width: 3),
                      Tooltip(
                        message: 'Codex 默认目录新建',
                        child: ShadIconButton.ghost(
                          key: const Key(
                            'create-codex-default-directory-session',
                          ),
                          onPressed: canCreate && !isCreating
                              ? onCreateCodexDefaultDirectory
                              : null,
                          icon: const Icon(LucideIcons.folderOpen, size: 17),
                        ),
                      ),
                    ],
                  ],
                ),
                if (controller.workspaceDirectory case final directory?
                    when !compact) ...[
                  const SizedBox(height: 6),
                  Tooltip(
                    message: '新建 Agent 会话会使用此工作目录',
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.folderOpen,
                          size: 13,
                          color: shadMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '新建会话目录',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            directory,
                            key: const Key('workspace-directory'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (controller.isLive &&
                    controller.workspaceDirectory != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        LucideIcons.listFilter,
                        size: 14,
                        color: shadMuted,
                      ),
                      const SizedBox(width: 7),
                      const Text('会话范围'),
                      const Spacer(),
                      SessionScopeSelector(
                        value: controller.allSessionsScope,
                        onChanged: (value) => unawaited(
                          controller.selectWorkspace(
                            controller.workspaceDirectory!,
                            allSessions: value,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            builder: (context, child) => ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: MediaQuery.disableAnimationsOf(context)
                    ? (showSessionControls ? 1 : 0)
                    : Curves.easeInOutCubic.transform(_controlsAnimation.value),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentChoice {
  const _AgentChoice({
    required this.id,
    required this.label,
    required this.background,
  });

  final String id;
  final String label;
  final Color background;
}

class _AgentChoiceTile extends StatelessWidget {
  const _AgentChoiceTile({
    required this.agent,
    required this.selected,
    required this.enabled,
    required this.status,
    required this.available,
    required this.width,
    required this.compact,
    required this.stacked,
    required this.onTap,
  });

  final _AgentChoice agent;
  final bool selected;
  final bool enabled;
  final String status;
  final bool available;
  final double width;
  final bool compact;
  final bool stacked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusColor = available ? shadSuccess : shadMuted;
    return Tooltip(
      message: '${agent.label} · $status',
      child: Semantics(
        label: '${agent.label}, $status',
        button: true,
        selected: selected,
        child: ShadButton.raw(
          key: Key('agent-choice-${agent.id}'),
          variant: selected
              ? ShadButtonVariant.secondary
              : ShadButtonVariant.outline,
          width: width,
          height: stacked
              ? 58
              : compact
              ? 44
              : 52,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 9,
            vertical: compact ? 4 : 6,
          ),
          enabled: enabled,
          onPressed: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled || selected ? 1 : .72,
            child: SizedBox(
              width: (width - (compact ? 16 : 26)).clamp(1.0, double.infinity),
              child: stacked
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: agent.background,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.all(4),
                              child: AgentBrandMark(
                                agentId: agent.id,
                                size: 16,
                                backgroundColor: agent.background,
                              ),
                            ),
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                key: Key('agent-status-${agent.id}'),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: shadGlass,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          agent.label,
                          key: Key('agent-label-${agent.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: shadInk, fontSize: 11),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Container(
                          width: compact ? 24 : 32,
                          height: compact ? 24 : 32,
                          decoration: BoxDecoration(
                            color: agent.background,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          padding: EdgeInsets.all(compact ? 5 : 7),
                          child: AgentBrandMark(
                            agentId: agent.id,
                            size: compact ? 14 : 32,
                            backgroundColor: agent.background,
                          ),
                        ),
                        SizedBox(width: compact ? 5 : 7),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                agent.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: shadInk,
                                      fontSize: compact ? 11 : 12,
                                    ),
                              ),
                              if (!compact) ...[
                                const SizedBox(height: 3),
                                Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: shadMuted,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionPicker extends StatelessWidget {
  const _SessionPicker({
    required this.sessions,
    required this.selectedId,
    required this.onSelected,
  });

  final List<HostSession> sessions;
  final String? selectedId;
  final ValueChanged<HostSession> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedExists = sessions.any((session) => session.id == selectedId);
    return SizedBox(
      width: double.infinity,
      child: ShadSelect<String>(
        key: const Key('host-session-picker'),
        initialValue: selectedExists ? selectedId : null,
        placeholder: const Text('选择 Agent 会话'),
        minWidth: 0,
        options: [
          for (final session in sessions)
            ShadOption(
              value: session.id,
              child: Text(
                '${session.agentId == 'codex'
                    ? session.remoteManaged
                          ? 'Codex · RemoteAISync 新建'
                          : 'Codex · 本机历史'
                    : session.agentId == 'claude'
                    ? 'Claude Code'
                    : 'OpenCode'} · ${session.title}${session.directory == null ? '' : ' · ${session.directory}'}${session.pendingCount > 0 ? ' · 待处理 ${session.pendingCount}' : ''}',
              ),
            ),
        ],
        selectedOptionBuilder: (context, id) => Text(
          sessions.firstWhere((session) => session.id == id).title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onChanged: (id) {
          if (id == null) return;
          for (final session in sessions) {
            if (session.id == id) {
              onSelected(session);
              break;
            }
          }
        },
      ),
    );
  }
}

class _LoadingMessages extends StatelessWidget {
  const _LoadingMessages();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(
      child: Text('正在读取会话…', style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary({
    required this.title,
    required this.subtitle,
    required this.isLive,
  });

  final String title;
  final String subtitle;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    return ShadCard(
      padding: const EdgeInsets.all(13),
      leading: DecoratedBox(
        decoration: BoxDecoration(
          color: shadMutedBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(
            isLive ? LucideIcons.messagesSquare : LucideIcons.terminal,
            color: shadPrimary,
            size: 18,
          ),
        ),
      ),
      title: Text(title),
      description: Text(subtitle),
      trailing: Icon(
        isLive ? LucideIcons.monitor : LucideIcons.cloudOff,
        color: shadMuted,
        size: 17,
      ),
    );
  }
}

class _ApprovalPanel extends StatelessWidget {
  const _ApprovalPanel({
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final ToolApproval approval;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final pending = approval.status == ApprovalStatus.pending;
    final statusText = switch (approval.status) {
      ApprovalStatus.pending => '等待人工审批',
      ApprovalStatus.approved => '已允许（本地演示）',
      ApprovalStatus.rejected => '已拒绝（本地演示）',
    };

    return ShadCard(
      padding: const EdgeInsets.all(13),
      title: Row(
        children: [
          Icon(
            pending ? LucideIcons.shieldAlert : LucideIcons.shieldCheck,
            size: 17,
            color: pending ? shadWarning : shadSuccess,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(statusText)),
          ShadBadge.outline(child: Text(approval.toolName)),
        ],
      ),
      description: Text(approval.summary),
      footer: pending
          ? Row(
              children: [
                Expanded(
                  child: ShadButton.outline(
                    key: const Key('deny-approval-approval-1'),
                    onPressed: onDeny,
                    leading: const Icon(LucideIcons.x, size: 16),
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: ShadButton(
                    key: const Key('approve-approval-1'),
                    onPressed: onAllow,
                    leading: const Icon(LucideIcons.check, size: 16),
                    child: const Text('允许执行'),
                  ),
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentCodeBlock(code: approval.command, language: 'shell'),
          const SizedBox(height: 7),
          Text(approval.target, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _MessageComposer extends StatefulWidget {
  const _MessageComposer({
    required this.onSend,
    required this.enabled,
    required this.placeholder,
    required this.onModelCommand,
    required this.onStopCommand,
    required this.onActionCommand,
    required this.skills,
    required this.codexControlsEnabled,
    required this.modelControlsEnabled,
    required this.canInterrupt,
    required this.thinking,
    required this.modelLabel,
    this.queueMode = false,
  });

  final Future<String?> Function(
    String text,
    List<_SelectedAttachment> attachments,
  )
  onSend;
  final bool enabled;
  final String placeholder;
  final bool queueMode;
  final VoidCallback onModelCommand;
  final VoidCallback onStopCommand;
  final void Function(String action) onActionCommand;
  final List<String> skills;
  final bool codexControlsEnabled;
  final bool modelControlsEnabled;
  final bool canInterrupt;
  final bool thinking;
  final String modelLabel;

  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _textController = TextEditingController();
  late final _composerFocusNode = FocusNode(
    onKeyEvent: _handleComposerKeyEvent,
  );
  final List<_SelectedAttachment> _attachments = [];
  bool _isPicking = false;
  bool _isSending = false;
  bool _composerFocused = false;
  double _composerTextareaHeight = 42;
  int _nextAttachmentId = 0;

  @override
  void initState() {
    super.initState();
    _composerFocusNode.addListener(_handleFocusChanged);
  }

  void _handleFocusChanged() {
    if (mounted && _composerFocused != _composerFocusNode.hasFocus) {
      setState(() => _composerFocused = _composerFocusNode.hasFocus);
    }
  }

  void _updateComposerHeight(int lineCount) {
    final nextHeight = (lineCount * 20.0).clamp(42.0, 116.0).toDouble();
    if (mounted && nextHeight != _composerTextareaHeight) {
      setState(() => _composerTextareaHeight = nextHeight);
    }
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed ||
        !_textController.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _composerFocusNode.removeListener(_handleFocusChanged);
    _textController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    setState(() => _isPicking = true);
    try {
      final files = await openFiles();
      if (!mounted || files.isEmpty) return;
      final selected = <_SelectedAttachment>[];
      for (final file in files) {
        selected.add(
          _SelectedAttachment(
            attachment: AgentAttachment(
              id: 'local-${DateTime.now().microsecondsSinceEpoch}-${_nextAttachmentId++}',
              name: file.name,
              sizeBytes: await file.length(),
              mimeType: file.mimeType,
            ),
            file: file,
          ),
        );
      }
      setState(() => _attachments.addAll(selected));
    } catch (_) {
      if (mounted) {
        ShadToaster.of(
          context,
        ).show(const ShadToast(title: Text('无法读取所选文件，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _send() async {
    if (!widget.enabled || _isSending) return;
    final value = _textController.text;
    if (value.trim().isEmpty && _attachments.isEmpty) return;
    if (value.trimLeft().startsWith('/')) {
      final parts = value.trim().split(RegExp(r'\s+'));
      if (_attachments.isNotEmpty || parts.length > 1) {
        ShadToaster.of(
          context,
        ).show(const ShadToast(title: Text('斜杠命令目前不能附带参数或文件。')));
        return;
      }
      final command = parts.first;
      switch (command) {
        case '/model':
          if (!widget.modelControlsEnabled) {
            ShadToaster.of(
              context,
            ).show(const ShadToast(title: Text('此会话不支持从手机切换模型。')));
            return;
          }
          widget.onModelCommand();
          break;
        case '/stop':
          if (!widget.canInterrupt) {
            ShadToaster.of(
              context,
            ).show(const ShadToast(title: Text('此会话需要在电脑端停止。')));
            return;
          }
          widget.onStopCommand();
          break;
        case '/compact':
        case '/review':
          if (!widget.codexControlsEnabled) {
            ShadToaster.of(context).show(
              const ShadToast(
                title: Text('此命令仅适用于 RemoteAISync 控制的 Codex 会话。'),
              ),
            );
            return;
          }
          widget.onActionCommand(command.substring(1));
          break;
        case '/skills':
          _textController.text = r'$';
          _textController.selection = const TextSelection.collapsed(offset: 1);
          return;
        default:
          ShadToaster.of(
            context,
          ).show(const ShadToast(title: Text('不支持此斜杠命令。请从联想列表选择。')));
          return;
      }
      _textController.clear();
      return;
    }
    setState(() => _isSending = true);
    final error = await widget.onSend(value, List.of(_attachments));
    if (!mounted) return;
    setState(() => _isSending = false);
    if (error != null) {
      ShadToaster.of(context).show(ShadToast(title: Text(error)));
      return;
    }
    _textController.clear();
    setState(_attachments.clear);
    FocusScope.of(context).unfocus();
  }

  Widget _buildSuggestions() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _textController,
    builder: (context, value, _) {
      final typed = value.text.trim();
      final isSlash = typed.startsWith('/') && !typed.contains(' ');
      final isSkill = typed.startsWith(r'$') && !typed.contains(' ');
      final suggestions =
          <String>[
                if (isSlash) ...[
                  if (widget.codexControlsEnabled) ...['/compact', '/review'],
                  if (widget.modelControlsEnabled) '/model',
                  if (widget.canInterrupt) '/stop',
                  '/skills',
                ],
                if (isSkill)
                  for (final skill in widget.skills) '\$$skill',
              ]
              .where(
                (item) => item.toLowerCase().startsWith(typed.toLowerCase()),
              )
              .take(8)
              .toList();
      if (suggestions.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final suggestion in suggestions)
                ShadButton.ghost(
                  key: Key('composer-suggestion-$suggestion'),
                  onPressed: () {
                    if (suggestion == '/model') {
                      _textController.clear();
                      widget.onModelCommand();
                    } else if (suggestion == '/stop') {
                      _textController.clear();
                      widget.onStopCommand();
                    } else if (suggestion == '/compact' ||
                        suggestion == '/review') {
                      _textController.clear();
                      widget.onActionCommand(suggestion.substring(1));
                    } else if (suggestion == '/skills') {
                      _textController.text = r'$';
                      _textController.selection = const TextSelection.collapsed(
                        offset: 1,
                      );
                    } else if (suggestion.startsWith(r'$')) {
                      _textController.text = '$suggestion ';
                      _textController.selection = TextSelection.collapsed(
                        offset: _textController.text.length,
                      );
                    }
                  },
                  child: Text(suggestion),
                ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 7),
      radius: 20,
      blur: 12,
      borderColor: _composerFocused
          ? shadPrimary.withValues(alpha: .42)
          : shadGlassBorder,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSuggestions(),
          if (_attachments.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (context, index) {
                  final selected = _attachments[index];
                  return _PendingAttachmentTile(
                    selected: selected,
                    onRemove: _isSending
                        ? null
                        : () => setState(() => _attachments.removeAt(index)),
                    onPreview: () {
                      if (isAgentAttachmentPreviewable(
                        selected.attachment.name,
                      )) {
                        _showAttachmentPreview(
                          context,
                          selected.attachment,
                          selected.file,
                        );
                      }
                    },
                  );
                },
              ),
            ),
          if (widget.thinking) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 7),
                child: AgentThinkingMarker(),
              ),
            ),
          ],
          if (widget.modelControlsEnabled) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: '设置模型与思考强度',
                child: ShadButton.ghost(
                  key: const Key('codex-model-settings'),
                  onPressed: widget.enabled ? widget.onModelCommand : null,
                  leading: const Icon(LucideIcons.settings2, size: 15),
                  child: SizedBox(
                    width: 96,
                    child: Text(
                      widget.modelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            // Keep the fixed-size controls attached to the bottom edge while
            // the textarea grows for multiline messages.
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Tooltip(
                message: '添加任意格式附件',
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: ShadIconButton.outline(
                    key: const Key('add-attachment'),
                    onPressed: _isPicking || _isSending || !widget.enabled
                        ? null
                        : _pickFiles,
                    icon: _isPicking
                        ? const SizedBox(
                            width: 18,
                            child: ShadProgress(minHeight: 2),
                          )
                        : const Icon(LucideIcons.paperclip),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShadTextarea(
                  key: const Key('message-composer'),
                  controller: _textController,
                  focusNode: _composerFocusNode,
                  enabled: widget.enabled && !_isSending,
                  minHeight: _composerTextareaHeight,
                  maxHeight: _composerTextareaHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  placeholderAlignment: Alignment.centerLeft,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  resizable: false,
                  onLineCountChange: _updateComposerHeight,
                  onSubmitted: (_) {
                    if (!HardwareKeyboard.instance.isShiftPressed) _send();
                  },
                  onChanged: (value) {
                    _updateComposerHeight(value.split('\n').length);
                  },
                  placeholder: Text(
                    widget.placeholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: widget.thinking
                    ? '停止当前生成'
                    : _isSending
                    ? '正在发送'
                    : widget.queueMode
                    ? '发送到桌面会话'
                    : '发送消息',
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: ShadIconButton(
                    key: const Key('send-reply'),
                    onPressed: widget.thinking
                        ? widget.canInterrupt && widget.enabled
                              ? widget.onStopCommand
                              : null
                        : widget.enabled && !_isSending
                        ? _send
                        : null,
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 170),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: widget.thinking
                          ? const Icon(
                              LucideIcons.square,
                              key: ValueKey('stop'),
                            )
                          : _isSending
                          ? const SizedBox(
                              key: ValueKey('sending'),
                              width: 18,
                              child: ShadProgress(minHeight: 2),
                            )
                          : const Icon(
                              LucideIcons.arrowUp,
                              key: ValueKey('send'),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedAttachment {
  const _SelectedAttachment({required this.attachment, required this.file});

  final AgentAttachment attachment;
  final XFile file;
}

class _PendingAttachmentTile extends StatelessWidget {
  const _PendingAttachmentTile({
    required this.selected,
    required this.onRemove,
    required this.onPreview,
  });

  final _SelectedAttachment selected;
  final VoidCallback? onRemove;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final attachment = selected.attachment;
    return ShadCard(
      width: 205,
      height: 56,
      padding: const EdgeInsets.only(left: 9, right: 4),
      child: Row(
        children: [
          Icon(attachmentIcon(attachment.name), color: shadPrimary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: isAgentAttachmentPreviewable(attachment.name)
                  ? onPreview
                  : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    formatAttachmentSize(attachment.sizeBytes),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
          Tooltip(
            message: '移除附件',
            child: ShadIconButton.ghost(
              onPressed: onRemove,
              icon: const Icon(LucideIcons.x, size: 15),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showAttachmentPreview(
  BuildContext context,
  AgentAttachment attachment,
  XFile file,
) {
  return showShadDialog<void>(
    context: context,
    builder: (context) {
      final viewport = MediaQuery.sizeOf(context);
      final dialogWidth = viewport.width < 784 ? viewport.width - 24 : 760.0;
      final contentWidth = viewport.width < 776 ? viewport.width - 56 : 720.0;
      return ShadDialog(
        title: Text(attachment.name),
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: viewport.height * .82,
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
        child: SizedBox(
          width: contentWidth,
          height: viewport.height * .58,
          child: Column(
            children: [
              const ShadSeparator.horizontal(),
              Expanded(
                child: _isPdf(attachment.name)
                    ? (kIsWeb
                          ? PdfViewer.uri(Uri.parse(file.path))
                          : PdfViewer.file(file.path))
                    : _ImageAttachmentPreview(file: file),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ImageAttachmentPreview extends StatelessWidget {
  const _ImageAttachmentPreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Image.network(
        file.path,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const _PreviewError(),
      );
    }
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _PreviewError();
        if (!snapshot.hasData) {
          return const Center(
            child: SizedBox(width: 140, child: ShadProgress()),
          );
        }
        return Image.memory(snapshot.data!, fit: BoxFit.contain);
      },
    );
  }
}

class _PreviewError extends StatelessWidget {
  const _PreviewError();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('无法预览此文件。文件仍可作为附件发送。'));
}

bool _isPdf(String name) => name.toLowerCase().endsWith('.pdf');
