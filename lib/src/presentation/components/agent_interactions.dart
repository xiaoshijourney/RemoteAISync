import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../domain/models.dart';
import '../shad_theme.dart';

class AgentFormCard extends StatefulWidget {
  const AgentFormCard({required this.form, required this.onSubmit, super.key});

  final AgentForm form;
  final Future<void> Function(AgentForm form, Map<String, Object?> answer)
  onSubmit;

  @override
  State<AgentFormCard> createState() => _AgentFormCardState();
}

class _AgentFormCardState extends State<AgentFormCard> {
  final Map<String, Object?> _answers = {};
  final Map<String, String> _customAnswers = {};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, ShadRadioController<String>> _radioControllers = {};
  bool _isSubmitting = false;
  bool _submitted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.form.fields) {
      final value = field.defaultValue;
      if (value != null) _answers[field.key] = value;
      if (field.type == AgentFormFieldType.string && field.options.isNotEmpty) {
        final initialValue =
            value is String &&
                field.options.any((option) => option.value == value)
            ? value
            : null;
        _radioControllers[field.key] = ShadRadioController<String>(
          value: initialValue,
        );
      }
      if (field.type == AgentFormFieldType.string ||
          field.type == AgentFormFieldType.number ||
          field.type == AgentFormFieldType.integer ||
          field.type == AgentFormFieldType.external ||
          (field.type == AgentFormFieldType.multiselect && field.custom)) {
        _controllers[field.key] = TextEditingController(
          text: field.type == AgentFormFieldType.multiselect
              ? ''
              : field.type == AgentFormFieldType.string &&
                    field.options.any((option) => option.value == value)
              ? ''
              : value?.toString() ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final controller in _radioControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availableFields = widget.form.fields
        .where(_isVisible)
        .toList(growable: false);
    return ShadCard(
      key: Key('form-card-${widget.form.id}'),
      padding: const EdgeInsets.all(13),
      title: Row(
        children: [
          const Icon(LucideIcons.listChecks, color: shadPrimary, size: 17),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.form.title)),
          ShadBadge.secondary(child: Text(_submitted ? '已提交' : '等待回复')),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ShadButton(
            key: Key('form-submit-${widget.form.id}'),
            enabled: !_isSubmitting && !_submitted,
            onPressed: _submit,
            leading: _isSubmitting
                ? const SizedBox(width: 16, child: ShadProgress(minHeight: 2))
                : const Icon(LucideIcons.arrowUp, size: 16),
            child: Text(_submitted ? '已提交' : '发送回复'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final field in availableFields) ...[
            _buildField(field),
            if (field != availableFields.last) const SizedBox(height: 14),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            ShadAlert.destructive(
              icon: const Icon(LucideIcons.circleAlert),
              title: const Text('无法提交'),
              description: Text(_error!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildField(AgentFormField field) {
    final label = field.title?.trim().isNotEmpty == true
        ? field.title!.trim()
        : field.key;
    final children = <Widget>[
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      if (field.description?.trim().isNotEmpty == true) ...[
        const SizedBox(height: 3),
        Text(field.description!, style: Theme.of(context).textTheme.bodySmall),
      ],
      const SizedBox(height: 7),
    ];

    switch (field.type) {
      case AgentFormFieldType.string:
        if (field.options.isNotEmpty) {
          final selected = _answers[field.key] is String
              ? _answers[field.key] as String
              : null;
          children.add(
            ShadRadioGroup<String>(
              key: Key('form-choice-${widget.form.id}-${field.key}'),
              controller: _radioControllers.putIfAbsent(
                field.key,
                () => ShadRadioController<String>(value: selected),
              ),
              onChanged: _isSubmitting || _submitted
                  ? null
                  : (value) {
                      if (value == null) return;
                      _customAnswers.remove(field.key);
                      _setAnswer(field.key, value);
                      _controllers[field.key]?.clear();
                    },
              items: [
                for (final option in field.options)
                  ShadRadio<String>(
                    key: Key(
                      'form-option-${widget.form.id}-${field.key}-${option.value}',
                    ),
                    value: option.value,
                    enabled: !_isSubmitting && !_submitted,
                    label: Text(option.label),
                    sublabel: option.description == null
                        ? null
                        : Text(option.description!),
                  ),
              ],
            ),
          );
          if (field.custom) {
            children.add(const SizedBox(height: 8));
            children.add(_textInput(field, custom: true));
          }
        } else {
          children.add(_textInput(field));
        }
        break;
      case AgentFormFieldType.number:
      case AgentFormFieldType.integer:
        children.add(_textInput(field, numeric: true));
        break;
      case AgentFormFieldType.boolean:
        children.add(
          ShadRadioGroup<bool>(
            key: Key('form-boolean-${widget.form.id}-${field.key}'),
            initialValue: _answers[field.key] is bool
                ? _answers[field.key] as bool
                : null,
            onChanged: _isSubmitting || _submitted
                ? null
                : (value) {
                    if (value != null) _setAnswer(field.key, value);
                  },
            items: [
              ShadRadio<bool>(
                key: Key('form-boolean-yes-${widget.form.id}-${field.key}'),
                value: true,
                enabled: !_isSubmitting && !_submitted,
                label: const Text('是'),
              ),
              ShadRadio<bool>(
                key: Key('form-boolean-no-${widget.form.id}-${field.key}'),
                value: false,
                enabled: !_isSubmitting && !_submitted,
                label: const Text('否'),
              ),
            ],
          ),
        );
        break;
      case AgentFormFieldType.multiselect:
        final selected = _answerList(field.key);
        for (final option in field.options) {
          final checked = selected.contains(option.value);
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShadCheckbox(
                    key: Key(
                      'form-option-${widget.form.id}-${field.key}-${option.value}',
                    ),
                    value: checked,
                    enabled: !_isSubmitting && !_submitted,
                    onChanged: (value) {
                      final next = List<String>.of(selected);
                      if (value && !next.contains(option.value)) {
                        next.add(option.value);
                      } else if (!value) {
                        next.remove(option.value);
                      }
                      _setAnswer(field.key, next);
                    },
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _isSubmitting || _submitted
                          ? null
                          : () {
                              final next = List<String>.of(selected);
                              if (checked) {
                                next.remove(option.value);
                              } else {
                                next.add(option.value);
                              }
                              _setAnswer(field.key, next);
                            },
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(option.label),
                            if (option.description?.isNotEmpty == true)
                              Text(
                                option.description!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (field.custom) {
          children.add(const SizedBox(height: 8));
          children.add(_textInput(field, custom: true));
        }
        break;
      case AgentFormFieldType.external:
        children.add(_textInput(field));
        if (field.url?.isNotEmpty == true) {
          children.add(const SizedBox(height: 6));
          children.add(SelectableText(field.url!));
        }
        break;
      case AgentFormFieldType.unsupported:
        children.add(const Text('此 OpenCode 字段类型暂不支持，无法提交该请求。'));
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _textInput(
    AgentFormField field, {
    bool numeric = false,
    bool custom = false,
  }) {
    final controller = _controllers.putIfAbsent(
      field.key,
      () => TextEditingController(),
    );
    return ShadInput(
      key: Key('form-field-${widget.form.id}-${field.key}'),
      controller: controller,
      enabled: !_isSubmitting && !_submitted,
      keyboardType: numeric
          ? TextInputType.numberWithOptions(
              decimal: field.type == AgentFormFieldType.number,
              signed: true,
            )
          : field.format == 'email'
          ? TextInputType.emailAddress
          : field.format == 'uri'
          ? TextInputType.url
          : field.format == 'date' || field.format == 'date-time'
          ? TextInputType.datetime
          : TextInputType.text,
      maxLength: field.maxLength,
      placeholder: Text(
        field.placeholder ??
            (custom ? '输入其他选项' : '填写${field.title ?? field.key}'),
      ),
      onChanged: (value) {
        if (numeric) {
          _setAnswer(field.key, value);
        } else if (field.type == AgentFormFieldType.multiselect) {
          setState(() {
            _customAnswers[field.key] = value;
            _error = null;
          });
        } else {
          if (field.type == AgentFormFieldType.string &&
              field.options.isNotEmpty &&
              field.custom) {
            _radioControllers[field.key]?.value = null;
          }
          _setAnswer(field.key, value);
        }
      },
    );
  }

  bool _isVisible(AgentFormField field) {
    for (final condition in field.conditions) {
      final source = _answers[condition.key];
      final matches = source is List
          ? source.map((value) => value.toString()).contains(condition.value) ||
                _customAnswers[condition.key]?.trim() == condition.value
          : source?.toString() == condition.value;
      if (condition.operator == 'neq' ? matches : !matches) return false;
    }
    return true;
  }

  List<String> _answerList(String key) {
    final value = _answers[key];
    if (value is List) return value.map((entry) => entry.toString()).toList();
    return [];
  }

  void _setAnswer(String key, Object? value) {
    setState(() {
      _answers[key] = value;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting || _submitted) return;
    final answer = <String, Object?>{};
    for (final field in widget.form.fields.where(_isVisible)) {
      final raw = _answers[field.key];
      if (field.type == AgentFormFieldType.external) {
        final value = raw?.toString().trim() ?? '';
        if (value.isNotEmpty) answer[field.key] = value;
        continue;
      }
      if (field.type == AgentFormFieldType.unsupported) {
        setState(() => _error = '有不支持的字段，无法安全提交。');
        return;
      }
      if (field.type == AgentFormFieldType.multiselect) {
        final values = _answerList(
          field.key,
        ).where((value) => value.isNotEmpty).toList();
        final customValue = _customAnswers[field.key]?.trim();
        if (customValue != null &&
            customValue.isNotEmpty &&
            !values.contains(customValue)) {
          values.add(customValue);
        }
        if (field.required && values.isEmpty) {
          setState(() => _error = '请至少选择一项：${field.title ?? field.key}');
          return;
        }
        if (field.minItems != null && values.length < field.minItems!) {
          setState(
            () =>
                _error = '${field.title ?? field.key}至少选择 ${field.minItems} 项。',
          );
          return;
        }
        if (field.maxItems != null && values.length > field.maxItems!) {
          setState(
            () =>
                _error = '${field.title ?? field.key}最多选择 ${field.maxItems} 项。',
          );
          return;
        }
        if (values.isNotEmpty) answer[field.key] = values;
        continue;
      }
      if (field.type == AgentFormFieldType.boolean) {
        if (raw is bool) {
          answer[field.key] = raw;
        } else if (field.required) {
          setState(() => _error = '请选择是或否：${field.title ?? field.key}');
          return;
        }
        continue;
      }
      final value = raw?.toString().trim() ?? '';
      if (value.isEmpty) {
        if (field.required) {
          setState(() => _error = '请填写：${field.title ?? field.key}');
          return;
        }
        continue;
      }
      if (field.minLength != null && value.length < field.minLength!) {
        setState(
          () => _error =
              '${field.title ?? field.key}至少需要 ${field.minLength} 个字符。',
        );
        return;
      }
      if (field.maxLength != null && value.length > field.maxLength!) {
        setState(
          () =>
              _error = '${field.title ?? field.key}最多 ${field.maxLength} 个字符。',
        );
        return;
      }
      final textError = _validateTextValue(field, value);
      if (textError != null) {
        setState(() => _error = textError);
        return;
      }
      if (field.type == AgentFormFieldType.number ||
          field.type == AgentFormFieldType.integer) {
        final number = num.tryParse(value);
        if (number == null ||
            (field.type == AgentFormFieldType.integer && number % 1 != 0)) {
          setState(() => _error = '请输入有效数字：${field.title ?? field.key}');
          return;
        }
        if (field.minimum != null && number < field.minimum!) {
          setState(
            () => _error = '${field.title ?? field.key}不能小于 ${field.minimum}。',
          );
          return;
        }
        if (field.maximum != null && number > field.maximum!) {
          setState(
            () => _error = '${field.title ?? field.key}不能大于 ${field.maximum}。',
          );
          return;
        }
        answer[field.key] = number;
      } else {
        answer[field.key] = value;
      }
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(widget.form, answer);
      if (mounted) setState(() => _submitted = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String? _validateTextValue(AgentFormField field, String value) {
    final label = field.title?.trim().isNotEmpty == true
        ? field.title!.trim()
        : field.key;
    if (field.pattern case final pattern? when pattern.isNotEmpty) {
      try {
        if (!RegExp(pattern).hasMatch(value)) return '$label格式不正确。';
      } on FormatException {
        return '$label使用了不支持的校验规则，无法提交。';
      }
    }
    switch (field.format) {
      case 'email':
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
          return '请输入有效的邮箱地址：$label';
        }
      case 'uri':
        final uri = Uri.tryParse(value);
        if (uri == null ||
            !uri.hasScheme ||
            ((uri.scheme == 'http' || uri.scheme == 'https') &&
                uri.host.isEmpty)) {
          return '请输入有效的网址：$label';
        }
      case 'date':
        final date = DateTime.tryParse(value);
        if (date == null ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
            date.toIso8601String().substring(0, 10) != value) {
          return '日期格式应为 YYYY-MM-DD：$label';
        }
      case 'date-time':
        if (!RegExp(
              r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
              caseSensitive: false,
            ).hasMatch(value) ||
            DateTime.tryParse(value) == null) {
          return '请输入有效的日期和时间：$label';
        }
    }
    return null;
  }
}

class AgentPermissionCard extends StatefulWidget {
  const AgentPermissionCard({
    required this.permission,
    required this.onResolve,
    super.key,
  });

  final AgentPermission permission;
  final Future<void> Function(AgentPermission permission, bool allow) onResolve;

  @override
  State<AgentPermissionCard> createState() => _AgentPermissionCardState();
}

class _AgentPermissionCardState extends State<AgentPermissionCard> {
  bool _isSubmitting = false;
  bool? _allow;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final resolved = _allow != null;
    return ShadCard(
      key: Key('permission-card-${widget.permission.id}'),
      padding: const EdgeInsets.all(13),
      title: Row(
        children: [
          Icon(
            resolved ? LucideIcons.shieldCheck : LucideIcons.shieldAlert,
            size: 17,
            color: resolved ? shadSuccess : shadWarning,
          ),
          const SizedBox(width: 8),
          const Expanded(child: Text('需要人工审批')),
          ShadBadge.outline(child: Text(widget.permission.action)),
        ],
      ),
      description: Text(
        resolved
            ? (_allow! ? '已允许执行一次' : '已拒绝执行')
            : (widget.permission.message ?? 'OpenCode 正在等待此工具调用的决定。'),
      ),
      footer: resolved
          ? null
          : Row(
              children: [
                Expanded(
                  child: ShadButton.outline(
                    key: Key('permission-reject-${widget.permission.id}'),
                    enabled: !_isSubmitting,
                    onPressed: () => _resolve(false),
                    leading: const Icon(LucideIcons.x, size: 16),
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: ShadButton(
                    key: Key('permission-allow-${widget.permission.id}'),
                    enabled: !_isSubmitting,
                    onPressed: () => _resolve(true),
                    leading: _isSubmitting
                        ? const SizedBox(
                            width: 16,
                            child: ShadProgress(minHeight: 2),
                          )
                        : const Icon(LucideIcons.check, size: 16),
                    child: const Text('允许一次'),
                  ),
                ),
              ],
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.permission.toolId?.isNotEmpty == true) ...[
            Text('工具 ${widget.permission.toolId}'),
            const SizedBox(height: 7),
          ],
          for (final resource in widget.permission.resources) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: shadMutedBackground,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: shadLine),
              ),
              child: SelectableText(
                resource,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 7),
          ],
          if (_error != null) ...[
            ShadAlert.destructive(
              icon: const Icon(LucideIcons.circleAlert),
              title: const Text('审批未提交'),
              description: Text(_error!),
            ),
            const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }

  Future<void> _resolve(bool allow) async {
    if (_isSubmitting || _allow != null) return;
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onResolve(widget.permission, allow);
      if (mounted) setState(() => _allow = allow);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
