import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_ai_sync/main.dart';
import 'package:remote_ai_sync/src/application/demo_controller.dart';
import 'package:remote_ai_sync/src/domain/models.dart';
import 'package:remote_ai_sync/src/presentation/components/agent_brand_mark.dart';
import 'package:remote_ai_sync/src/presentation/components/agent_interactions.dart';
import 'package:remote_ai_sync/src/presentation/components/chat_components.dart';
import 'package:remote_ai_sync/src/presentation/components/session_scope_selector.dart';
import 'package:remote_ai_sync/src/presentation/shad_theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('agent picker fits a narrow phone viewport', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(320, 568), Size(360, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
      expect(find.byKey(const Key('agent-choice-opencode')), findsOneWidget);
      expect(find.byKey(const Key('agent-choice-claude')), findsOneWidget);
      final pickerBounds = tester.getRect(
        find.byKey(const Key('agent-picker-scroll')),
      );
      for (final id in const ['codex', 'opencode', 'claude']) {
        final bounds = tester.getRect(find.byKey(Key('agent-choice-$id')));
        expect(bounds.left, greaterThanOrEqualTo(pickerBounds.left));
        expect(bounds.right, lessThanOrEqualTo(pickerBounds.right));
        expect(bounds.height, greaterThanOrEqualTo(44));
      }
      if (size.width == 320) {
        final claudeLabel = tester.widget<Text>(
          find.byKey(const Key('agent-label-claude')),
        );
        expect(claudeLabel.style?.fontSize, greaterThanOrEqualTo(11));
      }
      expect(tester.takeException(), isNull, reason: 'viewport: $size');
    }
  });

  testWidgets('file and connection pages fit narrow phone viewports', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(320, 568), Size(360, 800), Size(900, 700)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('navigation-文件')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'files at $size');

      await tester.tap(find.byKey(const Key('navigation-连接')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'connection at $size');
      expect(find.byKey(const Key('connection-route-tabs')), findsOneWidget);
      expect(find.byKey(const Key('connect-local-host')), findsOneWidget);
      expect(find.byKey(const Key('scan-pairing-qr')), findsOneWidget);

      await tester.tap(find.byKey(const Key('navigation-文件')));
      await tester.pumpAndSettle();
      final filePage = tester.getRect(
        find.byKey(const Key('disconnected-files-page')),
      );
      final emptyCardFinder = find
          .ancestor(of: find.text('尚未连接主机'), matching: find.byType(ShadCard))
          .first;
      final emptyCard = tester.getRect(emptyCardFinder);
      expect(emptyCard.width, greaterThanOrEqualTo(filePage.width - 28));
      expect(emptyCard.height, lessThanOrEqualTo(190));
      expect((emptyCard.center.dy - filePage.center.dy).abs(), lessThan(40));
      final titleBounds = tester.getRect(
        find.descendant(of: emptyCardFinder, matching: find.text('尚未连接主机')),
      );
      final iconBounds = tester.getRect(
        find.descendant(of: emptyCardFinder, matching: find.byType(Icon)).first,
      );
      expect((titleBounds.center.dx - emptyCard.center.dx).abs(), lessThan(1));
      expect((iconBounds.center.dx - emptyCard.center.dx).abs(), lessThan(1));
    }
  });

  testWidgets(
    'mobile session history and actions collapse under the agent row',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-session-controls')), findsOneWidget);
      expect(find.byKey(const Key('refresh-sessions')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('session-controls-region'))).height,
        0,
      );

      await tester.tap(find.byKey(const Key('toggle-session-controls')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('refresh-sessions')), findsOneWidget);
      expect(find.text('新建'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('session-controls-region'))).height,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile navigation yields space while the keyboard is open', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-会话')), findsOneWidget);

    for (final page in const ['连接', '文件', '会话']) {
      await tester.tap(find.byKey(Key('navigation-$page')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('message-composer')));
    await tester.pump();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    expect(find.byKey(const Key('navigation-会话')), findsNothing);
    expect(find.byKey(const Key('message-composer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'connection page scroll and controls stay active around IME resize',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('navigation-连接')));
      await tester.pumpAndSettle();

      final scrollable = find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('connection-page-scroll'),
            ),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.tap(find.byKey(const Key('connection-host')));
      await tester.pump();
      expect(
        find.byKey(const PageStorageKey<String>('connection-page-scroll')),
        findsOneWidget,
        reason: 'connection page before keyboard resize',
      );
      for (final inset in const [80.0, 160.0, 240.0, 320.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.byKey(const PageStorageKey<String>('connection-page-scroll')),
          findsOneWidget,
          reason: 'connection page with keyboard inset $inset',
        );
      }
      await tester.ensureVisible(find.text('自托管中继'));
      await tester.tap(find.text('自托管中继'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection-relay-url')), findsOneWidget);

      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const PageStorageKey<String>('connection-page-scroll')),
        findsOneWidget,
        reason: 'connection page after keyboard resize',
      );

      await tester.drag(
        find.byKey(const PageStorageKey<String>('connection-page-scroll')),
        const Offset(0, -420),
      );
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
      );

      await tester.drag(
        find.byKey(const PageStorageKey<String>('connection-page-scroll')),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('局域网直连'));
      await tester.tap(find.text('局域网直连'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection-host')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tool calls are grouped and collapsed by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      _componentApp(
        const AgentToolCallGroup(
          messages: [
            AgentMessage(
              id: 'tool-1',
              author: MessageAuthor.tool,
              text: 'run test one',
              time: '12:00',
            ),
            AgentMessage(
              id: 'tool-2',
              author: MessageAuthor.tool,
              text: 'run test two',
              time: '12:00',
            ),
            AgentMessage(
              id: 'tool-3',
              author: MessageAuthor.tool,
              text: 'run test three',
              time: '12:01',
            ),
          ],
        ),
      ),
    );

    expect(find.text('执行轨迹 · 3 步'), findsOneWidget);
    expect(find.text('3 步'), findsOneWidget);
    expect(find.text('run test one'), findsNothing);
    await tester.tap(find.byKey(const Key('toggle-tool-group-tool-1')));
    await tester.pumpAndSettle();
    expect(find.text('run test one'), findsOneWidget);
    expect(find.text('run test two'), findsOneWidget);
    expect(find.text('run test three'), findsOneWidget);
  });

  testWidgets('session scope uses explicit selected buttons', (tester) async {
    var selectedScope = true;
    await tester.pumpWidget(
      _componentApp(
        StatefulBuilder(
          builder: (context, setState) => SessionScopeSelector(
            value: selectedScope,
            onChanged: (value) => setState(() => selectedScope = value),
          ),
        ),
      ),
    );

    expect(find.text('全局'), findsOneWidget);
    expect(find.text('当前文件夹'), findsOneWidget);
    await tester.tap(find.text('当前文件夹'));
    await tester.pumpAndSettle();
    expect(selectedScope, isFalse);
  });

  testWidgets('fenced assistant code uses the reusable Shad code block', (
    tester,
  ) async {
    await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('null-m1')),
      180,
      scrollable: _messageScrollable(),
    );

    expect(find.byType(AgentCodeBlock), findsWidgets);
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('assistant response can be collapsed and expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _componentApp(
        const AgentMessageTile(
          message: AgentMessage(
            id: 'foldable-assistant',
            author: MessageAuthor.assistant,
            text: '**A detailed answer**\n\n```dart\nprint(1);\n```',
            time: '12:00',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('toggle-message-foldable-assistant'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.byType(AgentCodeBlock), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(AgentCodeBlock), findsWidgets);
  });

  testWidgets('assistant message avatar matches its agent', (tester) async {
    await tester.pumpWidget(
      _componentApp(
        const AgentMessageTile(
          agentId: 'codex',
          message: AgentMessage(
            id: 'codex-assistant',
            author: MessageAuthor.assistant,
            text: 'Codex response',
            time: '12:00',
          ),
        ),
      ),
    );

    final avatar = tester.widget<AgentBrandMark>(find.byType(AgentBrandMark));
    expect(avatar.agentId, 'codex');
  });

  testWidgets('switching sessions scrolls the message list to the bottom', (
    tester,
  ) async {
    var sessionKey = 'session-one';
    late StateSetter setParentState;
    Widget buildList() => SizedBox(
      height: 220,
      child: AgentMessageScroller(
        sessionKey: sessionKey,
        messageCount: 30,
        children: List.generate(
          30,
          (index) => SizedBox(height: 60, child: Text('Message $index')),
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setParentState = setState;
              return buildList();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(_messageScrollable());
    scrollable.position.jumpTo(0);
    await tester.pump();

    setParentState(() => sessionKey = 'session-two');
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);
  });

  testWidgets('composer sends on Enter and ignores Shift+Enter', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.pumpAndSettle();

    final composer = find.byKey(const Key('message-composer'));
    await tester.ensureVisible(composer);
    final composerBounds = tester.getRect(composer);
    final attachmentBounds = tester.getRect(
      find.byKey(const Key('add-attachment')),
    );
    final sendBounds = tester.getRect(find.byKey(const Key('send-reply')));
    expect(attachmentBounds.left, lessThan(composerBounds.left));
    expect(composerBounds.left, lessThan(sendBounds.left));
    expect(attachmentBounds.top, closeTo(composerBounds.top, 1));
    expect(sendBounds.top, closeTo(composerBounds.top, 1));
    expect(attachmentBounds.bottom, closeTo(composerBounds.bottom, 1));
    expect(sendBounds.bottom, closeTo(composerBounds.bottom, 1));

    await tester.tap(composer);
    await tester.enterText(composer, 'Line one\nLine two\nLine three');
    await tester.pumpAndSettle();
    final multilineBounds = tester.getRect(composer);
    final multilineAttachmentBounds = tester.getRect(
      find.byKey(const Key('add-attachment')),
    );
    final multilineSendBounds = tester.getRect(
      find.byKey(const Key('send-reply')),
    );
    expect(multilineBounds.height, greaterThan(composerBounds.height));
    expect(multilineAttachmentBounds.size, attachmentBounds.size);
    expect(multilineSendBounds.size, sendBounds.size);
    expect(
      multilineAttachmentBounds.bottom,
      closeTo(multilineBounds.bottom, 1),
    );
    expect(multilineSendBounds.bottom, closeTo(multilineBounds.bottom, 1));

    await tester.tap(composer);
    await tester.enterText(composer, 'Line one');
    await tester.pumpAndSettle();
    expect(tester.getRect(composer).height, closeTo(composerBounds.height, 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      controller.messages.any(
        (message) =>
            message.author == MessageAuthor.user && message.text == 'Line one',
      ),
      isFalse,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      controller.messages.any(
        (message) =>
            message.author == MessageAuthor.user && message.text == 'Line one',
      ),
      isTrue,
    );
  });

  testWidgets('questionnaire option is submitted to the session controller', (
    tester,
  ) async {
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.scrollUntilVisible(
      find.byKey(const Key('questionnaire-option-3000')),
      180,
      scrollable: _messageScrollable(),
    );

    final option = find.byKey(const Key('questionnaire-option-3000'));
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(controller.selectedPort, isNot('3000'));
    final submit = find.byKey(const Key('questionnaire-submit-option'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(controller.selectedPort, '3000');
    expect(find.text('预览端口使用 3000'), findsOneWidget);
  });

  testWidgets('questionnaire validates custom answers before submission', (
    tester,
  ) async {
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    final customAnswer = find.byKey(const Key('questionnaire-custom-answer'));
    await tester.scrollUntilVisible(
      customAnswer,
      160,
      scrollable: _messageScrollable(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: customAnswer, matching: find.byType(EditableText)),
      '70000',
    );
    final submit = find.byKey(const Key('questionnaire-submit-custom'));
    await tester.scrollUntilVisible(
      submit,
      120,
      scrollable: _messageScrollable(),
    );
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('端口需为 1–65535'), findsOneWidget);
    expect(controller.selectedPort, isNull);
  });

  testWidgets('live Agent form submits the selected option', (tester) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_live',
      sessionId: 'ses_live',
      title: 'Choose a mode',
      fields: [
        AgentFormField(
          key: 'mode',
          type: AgentFormFieldType.string,
          title: 'Mode',
          required: true,
          options: [AgentFormOption(value: 'safe', label: 'Safe')],
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('form-option-frm_live-mode-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_live')));
    await tester.pumpAndSettle();

    expect(submittedAnswer, {'mode': 'safe'});
    expect(find.text('已提交'), findsNWidgets(2));
  });

  testWidgets('live form submits custom strings and raw multiselect values', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_custom',
      sessionId: 'ses_live',
      title: 'Configure the run',
      fields: [
        AgentFormField(
          key: 'mode',
          type: AgentFormFieldType.string,
          title: 'Mode',
          required: true,
          custom: true,
          options: [
            AgentFormOption(value: 'safe', label: 'Safe'),
            AgentFormOption(value: 'fast', label: 'Fast'),
          ],
        ),
        AgentFormField(
          key: 'features',
          type: AgentFormFieldType.multiselect,
          title: 'Features',
          minItems: 2,
          maxItems: 3,
          custom: true,
          options: [
            AgentFormOption(value: 'cache', label: 'Cache'),
            AgentFormOption(value: 'logs', label: 'Logs'),
            AgentFormOption(value: 'metrics', label: 'Metrics'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('form-option-frm_custom-mode-safe')));
    await tester.pumpAndSettle();
    await _enterFormInput(tester, 'frm_custom', 'mode', 'guided');
    await tester.tap(
      find.byKey(const Key('form-option-frm_custom-features-cache')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('form-option-frm_custom-features-logs')),
    );
    await tester.pumpAndSettle();
    await _enterFormInput(tester, 'frm_custom', 'features', 'audit');
    await tester.tap(
      find.byKey(const Key('form-option-frm_custom-features-metrics')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_custom')));
    await tester.pumpAndSettle();
    expect(find.text('Features最多选择 3 项。'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('form-option-frm_custom-features-metrics')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_custom')));
    await tester.pumpAndSettle();

    expect(submittedAnswer, {
      'mode': 'guided',
      'features': ['cache', 'logs', 'audit'],
    });
  });

  testWidgets('multiselect form enforces its minimum item count', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_min_items',
      sessionId: 'ses_live',
      title: 'Select features',
      fields: [
        AgentFormField(
          key: 'features',
          type: AgentFormFieldType.multiselect,
          title: 'Features',
          required: true,
          minItems: 2,
          options: [
            AgentFormOption(value: 'cache', label: 'Cache'),
            AgentFormOption(value: 'logs', label: 'Logs'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('form-option-frm_min_items-features-cache')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_min_items')));
    await tester.pumpAndSettle();

    expect(find.text('Features至少选择 2 项。'), findsOneWidget);
    expect(submittedAnswer, isNull);
  });

  testWidgets('numeric and boolean form fields submit typed values', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_numeric',
      sessionId: 'ses_live',
      title: 'Deployment settings',
      fields: [
        AgentFormField(
          key: 'port',
          type: AgentFormFieldType.integer,
          title: 'Port',
          required: true,
          minimum: 1,
          maximum: 65535,
        ),
        AgentFormField(
          key: 'timeout',
          type: AgentFormFieldType.number,
          title: 'Timeout',
          required: true,
          minimum: 0,
          maximum: 10,
        ),
        AgentFormField(
          key: 'confirm',
          type: AgentFormFieldType.boolean,
          title: 'Confirm deploy',
          required: true,
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await _enterFormInput(tester, 'frm_numeric', 'port', '4173.5');
    await _enterFormInput(tester, 'frm_numeric', 'timeout', '1.5');
    final noOption = find.descendant(
      of: find.byKey(const Key('form-boolean-frm_numeric-confirm')),
      matching: find.text('否'),
    );
    await tester.ensureVisible(noOption);
    await tester.tap(noOption);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_numeric')));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效数字：Port'), findsOneWidget);
    expect(submittedAnswer, isNull);

    await _enterFormInput(tester, 'frm_numeric', 'port', '4173');
    await tester.tap(find.byKey(const Key('form-submit-frm_numeric')));
    await tester.pumpAndSettle();
    expect(submittedAnswer, {'port': 4173, 'timeout': 1.5, 'confirm': false});
  });

  testWidgets('choosing an option clears the custom string answer', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_custom_mode',
      sessionId: 'ses_live',
      title: 'Choose a mode',
      fields: [
        AgentFormField(
          key: 'mode',
          type: AgentFormFieldType.string,
          required: true,
          custom: true,
          options: [AgentFormOption(value: 'safe', label: 'Safe')],
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await _enterFormInput(tester, 'frm_custom_mode', 'mode', 'guided');
    await tester.tap(
      find.byKey(const Key('form-option-frm_custom_mode-mode-safe')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(_formInput(tester, 'frm_custom_mode', 'mode'))
          .controller
          .text,
      isEmpty,
    );
    await tester.tap(find.byKey(const Key('form-submit-frm_custom_mode')));
    await tester.pumpAndSettle();

    expect(submittedAnswer, {'mode': 'safe'});
  });

  testWidgets('live form applies email, pattern, and date validation', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_validation',
      sessionId: 'ses_live',
      title: 'Contact details',
      fields: [
        AgentFormField(
          key: 'email',
          type: AgentFormFieldType.string,
          title: 'Email',
          required: true,
          format: 'email',
          pattern: r'@example\.com$',
        ),
        AgentFormField(
          key: 'startDate',
          type: AgentFormFieldType.string,
          title: 'Start date',
          required: true,
          format: 'date',
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    await _enterFormInput(tester, 'frm_validation', 'email', 'bad@outside.net');
    await _enterFormInput(tester, 'frm_validation', 'startDate', '2026-02-28');
    await tester.tap(find.byKey(const Key('form-submit-frm_validation')));
    await tester.pumpAndSettle();
    expect(find.text('Email格式不正确。'), findsOneWidget);
    expect(submittedAnswer, isNull);

    await _enterFormInput(tester, 'frm_validation', 'email', 'dev@example.com');
    await _enterFormInput(tester, 'frm_validation', 'startDate', '2026-02-30');
    await tester.tap(find.byKey(const Key('form-submit-frm_validation')));
    await tester.pumpAndSettle();
    expect(find.text('日期格式应为 YYYY-MM-DD：Start date'), findsOneWidget);
    expect(submittedAnswer, isNull);

    await _enterFormInput(tester, 'frm_validation', 'startDate', '2026-02-28');
    await tester.tap(find.byKey(const Key('form-submit-frm_validation')));
    await tester.pumpAndSettle();
    expect(submittedAnswer, {
      'email': 'dev@example.com',
      'startDate': '2026-02-28',
    });
  });

  testWidgets('conditional fields hide and are omitted from the answer', (
    tester,
  ) async {
    Map<String, Object?>? submittedAnswer;
    const form = AgentForm(
      id: 'frm_conditional',
      sessionId: 'ses_live',
      title: 'Deployment settings',
      fields: [
        AgentFormField(
          key: 'mode',
          type: AgentFormFieldType.string,
          title: 'Mode',
          required: true,
          defaultValue: 'existing',
          options: [
            AgentFormOption(value: 'existing', label: 'Existing server'),
            AgentFormOption(value: 'new', label: 'New server'),
          ],
        ),
        AgentFormField(
          key: 'path',
          type: AgentFormFieldType.string,
          title: 'Deploy path',
          required: true,
          conditions: [
            AgentFormCondition(key: 'mode', operator: 'eq', value: 'new'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentFormCard(
          form: form,
          onSubmit: (_, answer) async => submittedAnswer = answer,
        ),
      ),
    );

    expect(
      find.byKey(const Key('form-field-frm_conditional-path')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('form-option-frm_conditional-mode-new')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('form-field-frm_conditional-path')),
      findsOneWidget,
    );
    await _enterFormInput(tester, 'frm_conditional', 'path', 'C:/deploy');
    await tester.tap(
      find.byKey(const Key('form-option-frm_conditional-mode-existing')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-submit-frm_conditional')));
    await tester.pumpAndSettle();

    expect(submittedAnswer, {'mode': 'existing'});
  });

  testWidgets('live Agent approval submits its allow decision', (tester) async {
    bool? decision;
    const permission = AgentPermission(
      id: 'per_live',
      sessionId: 'ses_live',
      action: 'bash',
      resources: ['echo safe'],
      toolId: 'bash',
    );
    await tester.pumpWidget(
      _componentApp(
        AgentPermissionCard(
          permission: permission,
          onResolve: (_, allow) async => decision = allow,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('permission-allow-per_live')));
    await tester.pumpAndSettle();

    expect(decision, isTrue);
    expect(find.text('已允许执行一次'), findsOneWidget);
  });

  testWidgets('failed approval remains actionable and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    bool? decision;
    const permission = AgentPermission(
      id: 'per_retry',
      sessionId: 'ses_live',
      action: 'write',
      resources: ['src/main.dart'],
    );
    await tester.pumpWidget(
      _componentApp(
        AgentPermissionCard(
          permission: permission,
          onResolve: (_, allow) async {
            attempts++;
            if (attempts == 1) throw StateError('temporary network failure');
            decision = allow;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('permission-allow-per_retry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary network failure'), findsOneWidget);
    expect(find.byKey(const Key('permission-allow-per_retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('permission-allow-per_retry')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(decision, isTrue);
    expect(find.text('已允许执行一次'), findsOneWidget);
  });

  testWidgets('navigation opens files and connection views', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(RemoteAISyncApp(controller: DemoController()));

    await tester.scrollUntilVisible(
      find.byKey(const Key('approve-approval-1')),
      180,
      scrollable: _messageScrollable(),
    );
    expect(find.text('等待人工审批'), findsOneWidget);
    await tester.tap(find.byKey(const Key('navigation-文件')));
    await tester.pumpAndSettle();
    expect(find.text('尚未连接主机'), findsOneWidget);
    expect(find.text('main.py'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('disconnected-files-page'))).height,
      greaterThan(300),
    );

    await tester.tap(find.byKey(const Key('navigation-连接')));
    await tester.pumpAndSettle();
    expect(find.text('设备配对'), findsOneWidget);
    await tester.tap(find.text('自托管中继'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection-relay-url')), findsOneWidget);
    await tester.tap(find.text('局域网直连'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connection-host')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('链路状态'),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('connection-page-scroll'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('链路状态'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('navigation-会话')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('navigation-连接')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const PageStorageKey<String>('connection-page-scroll')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('设备配对'),
      -180,
      scrollable: find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('connection-page-scroll'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('设备配对'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('files page stays interactive while a directory request hangs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late HttpServer server;
    late StreamSubscription<HttpRequest> serverSubscription;
    WebSocket? hostSocket;
    var listRequests = 0;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        hostSocket = socket;
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['kind'] == 'client.hello') {
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'host.ready',
                'payload': {'workspaceDirectory': r'C:\workspace'},
              }),
            );
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'host.snapshot',
                'payload': {'sessions': []},
              }),
            );
            return;
          }
          if (frame['kind'] != 'workspace.list') return;

          listRequests++;
          if (listRequests == 1) return;
          socket.add(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'command.result',
              'payload': {
                'commandId': frame['commandId'],
                'ok': true,
                'path': r'C:\workspace',
                'entries': [
                  {
                    'name': 'sample.txt',
                    'path': r'C:\workspace\sample.txt',
                    'isDirectory': false,
                    'sizeBytes': 12,
                  },
                ],
              },
            }),
          );
        });
      });
    });

    final controller = DemoController();
    try {
      await tester.runAsync(
        () => controller.connect(
          address: '127.0.0.1',
          port: server.port,
          pairingToken: 'x' * 40,
        ),
      );
      await tester.pumpWidget(RemoteAISyncApp(controller: controller));
      await tester.pump();
      await tester.tap(find.byKey(const Key('navigation-文件')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (listRequests == 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      await tester.tap(find.byKey(const Key('navigation-文件')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.byKey(const Key('file-list-loading')),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('files-page-scroll-view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const Key('file-list-loading')), findsOneWidget);

      await tester.tap(find.byKey(const Key('navigation-连接')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('设备配对'), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigation-文件')));
      await tester.pump(const Duration(milliseconds: 300));

      final refreshButton = find.byKey(const Key('file-refresh-button'));
      expect(tester.widget<ShadButton>(refreshButton).onPressed, isNotNull);
      await tester.tap(refreshButton);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (listRequests < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(listRequests, 2);
      expect(find.text('sample.txt'), findsOneWidget);
      await tester.tap(find.byKey(const Key('file-selection-toggle')));
      await tester.pump();
      expect(find.text('取消选择'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(() async {
        await controller.disconnect();
        await hostSocket?.close();
        await serverSubscription.cancel();
        await server.close(force: true);
      });
      controller.dispose();
    }
  });

  testWidgets('disconnected production mode shows no demo content', (
    tester,
  ) async {
    final controller = DemoController(demo: false);
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));

    expect(find.text('未连接'), findsWidgets);
    expect(find.textContaining('参数解析和页面代码已经完成'), findsNothing);
    expect(find.text('等待人工审批'), findsNothing);

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('尚未连接主机'), findsOneWidget);
    expect(find.text('main.py'), findsNothing);
  });

  testWidgets('approval buttons update the displayed local demo status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    final approveButton = find.byKey(const Key('approve-approval-1'));
    await tester.scrollUntilVisible(
      approveButton,
      180,
      scrollable: _messageScrollable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(approveButton);
    await tester.pumpAndSettle();

    expect(find.text('已允许（本地演示）'), findsOneWidget);
  });

  testWidgets('session timeline lists non-previewable attachments', (
    tester,
  ) async {
    final controller = DemoController();
    controller.sendReply(
      '',
      attachments: const [
        AgentAttachment(
          id: 'archive-1',
          name: 'source_bundle.zip',
          sizeBytes: 2048,
        ),
      ],
    );
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.scrollUntilVisible(
      find.text('source_bundle.zip'),
      180,
      scrollable: _messageScrollable(),
    );
    expect(find.text('source_bundle.zip'), findsOneWidget);
    expect(find.textContaining('不可预览，可作为附件发送'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('尚未传至电脑 Agent'),
      180,
      scrollable: _messageScrollable(),
    );
    expect(find.textContaining('尚未传至电脑 Agent'), findsOneWidget);
  });

  testWidgets('connection form validates port and pairing token', (
    tester,
  ) async {
    final controller = DemoController();
    await tester.pumpWidget(RemoteAISyncApp(controller: controller));
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    final portField = find.descendant(
      of: find.byKey(const Key('connection-port')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(portField).controller.text, '8910');

    await _enterShadField(tester, 'connection-port', '70000');
    await _tapConnect(tester);
    await tester.pumpAndSettle();
    expect(find.text('端口需为 1–65535'), findsOneWidget);
    expect(controller.connectionStatus, HostConnectionStatus.disconnected);

    await _enterShadField(tester, 'connection-port', '8910');
    expect(controller.connectionStatus, HostConnectionStatus.disconnected);
    await _tapConnect(tester);
    await tester.pumpAndSettle();
    expect(find.text('请输入主机生成的限时配对邀请'), findsOneWidget);
    expect(controller.connectionStatus, HostConnectionStatus.disconnected);
  });

  testWidgets('live host mode does not expose demo interactions', (
    tester,
  ) async {
    late HttpServer server;
    late StreamSubscription<HttpRequest> serverSubscription;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {
          socket.add(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'host.ready',
              'payload': {
                'openCodeVersion': null,
                'codexVersion': 'codex-cli test',
              },
            }),
          );
          socket.add(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'host.snapshot',
              'payload': {'sessions': []},
            }),
          );
        });
      });
    });
    final controller = DemoController();
    try {
      await tester.runAsync(
        () => controller.connect(
          address: '127.0.0.1',
          port: server.port,
          pairingToken: 'x' * 40,
        ),
      );

      await tester.pumpWidget(RemoteAISyncApp(controller: controller));
      await tester.pumpAndSettle();

      expect(controller.isDemo, isFalse);
      expect(find.byKey(const Key('create-codex-session')), findsOneWidget);
      expect(find.text('Codex'), findsWidgets);
      expect(find.text('在线 · 0'), findsOneWidget);
      expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
      expect(find.byKey(const Key('agent-choice-opencode')), findsOneWidget);
      expect(find.byKey(const Key('agent-choice-claude')), findsOneWidget);
      await tester.tap(find.byKey(const Key('agent-choice-opencode')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('create-opencode-session')), findsOneWidget);
      expect(find.text('未发现'), findsNWidgets(2));
      expect(
        tester
            .widget<ShadButton>(
              find.byKey(const Key('create-opencode-session')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('agent-choice-claude')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('create-claude-session')), findsOneWidget);
      expect(find.byKey(const Key('agent-empty-mark-claude')), findsOneWidget);
      expect(find.text('未发现'), findsNWidgets(2));
      expect(
        tester
            .widget<ShadButton>(find.byKey(const Key('create-claude-session')))
            .onPressed,
        isNull,
      );
      expect(find.text('等待人工审批'), findsNothing);
      expect(find.text('请选择一个端口。'), findsNothing);
      expect(find.textContaining('演示数据'), findsNothing);
      expect(
        tester
            .widget<ShadTextarea>(find.byKey(const Key('message-composer')))
            .enabled,
        isFalse,
      );
    } finally {
      await tester.runAsync(() async {
        await controller.disconnect();
        await serverSubscription.cancel();
        await server.close(force: true);
      });
      controller.dispose();
    }
  });

  testWidgets('selected Codex desktop session shows queued messages', (
    tester,
  ) async {
    late HttpServer server;
    late StreamSubscription<HttpRequest> serverSubscription;
    String? withdrawnQueueId;
    String? choiceReply;
    String? selectedEffort;
    var interrupted = false;
    final actions = <String>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final commandId = frame['commandId'];
          if (frame['kind'] == 'client.hello') {
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'host.ready',
                'payload': {'codexVersion': 'codex-cli test'},
              }),
            );
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'host.snapshot',
                'payload': {
                  'sessions': [
                    {
                      'id': 'codex:desktop',
                      'agentId': 'codex',
                      'title': 'Desktop session',
                      'updatedAt': '12:00',
                    },
                    {
                      'id': 'codex:remote',
                      'agentId': 'codex',
                      'remoteManaged': true,
                      'pendingCount': 2,
                      'title': 'Remote session',
                      'updatedAt': '12:01',
                    },
                  ],
                },
              }),
            );
          } else if (frame['kind'] == 'session.select') {
            final payload = frame['payload'] as Map;
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'session.snapshot',
                'payload': {
                  'sessionId': payload['sessionId'],
                  'selectionGeneration': payload['selectionGeneration'],
                  'messages': payload['sessionId'] == 'codex:desktop'
                      ? [
                          {
                            'id': 'choice-1',
                            'author': 'assistant',
                            'text': '请选择哪个模式？\n- A. 安全\n- B. 快速',
                            'time': '12:01',
                          },
                        ]
                      : [],
                  'forms': [],
                  'permissions': [],
                  'queuedMessages': [
                    {
                      'id': 'queued-1',
                      'text': 'Queued from phone',
                      'imageCount': 1,
                    },
                  ],
                  'queueWarning': 'temporary queue failure',
                },
              }),
            );
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          } else if (frame['kind'] == 'session.reply') {
            choiceReply = (frame['payload'] as Map)['text']?.toString();
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          } else if (frame['kind'] == 'session.controls') {
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {
                  'commandId': commandId,
                  'ok': true,
                  'models': [
                    {
                      'id': 'gpt-6-sol',
                      'name': 'GPT-6 Sol',
                      'efforts': ['medium', 'high'],
                      'defaultEffort': 'medium',
                    },
                  ],
                  'skills': ['review'],
                  'settings': {
                    'model': 'gpt-6-sol',
                    'effort': 'medium',
                    'running': !interrupted,
                  },
                },
              }),
            );
          } else if (frame['kind'] == 'session.settings.update') {
            selectedEffort = (frame['payload'] as Map)['effort']?.toString();
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          } else if (frame['kind'] == 'session.interrupt') {
            interrupted = true;
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          } else if (frame['kind'] == 'session.action') {
            actions.add((frame['payload'] as Map)['action'].toString());
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          } else if (frame['kind'] == 'session.queue.delete') {
            withdrawnQueueId = (frame['payload'] as Map)['queuedSubmissionId']
                ?.toString();
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'session.snapshot',
                'payload': {
                  'sessionId': 'codex:desktop',
                  'messages': [
                    {
                      'id': 'choice-1',
                      'author': 'assistant',
                      'text': '请选择哪个模式？\n- A. 安全\n- B. 快速',
                      'time': '12:01',
                    },
                  ],
                  'forms': [],
                  'permissions': [],
                  'queuedMessages': [],
                },
              }),
            );
            socket.add(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'command.result',
                'payload': {'commandId': commandId, 'ok': true},
              }),
            );
          }
        });
      });
    });
    final controller = DemoController();
    try {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.runAsync(() async {
        await controller.connect(
          address: '127.0.0.1',
          port: server.port,
          pairingToken: 'x' * 40,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (controller.sessions.isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await controller.selectSession(
          controller.sessions.firstWhere(
            (session) => session.id == 'codex:desktop',
          ),
        );
        expect(controller.queuedMessages, hasLength(1));
      });
      await tester.pumpWidget(RemoteAISyncApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agent-integration-hint')), findsNothing);
      expect(find.textContaining('历史线程可能来自 CLI 或桌面端'), findsNothing);
      tester.state<ScrollableState>(_messageScrollable()).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Codex 桌面会话'), findsNothing);
      final pendingNotice = find.text('其他会话有待处理请求');
      await tester.scrollUntilVisible(
        pendingNotice,
        180,
        scrollable: _messageScrollable(),
      );
      expect(pendingNotice, findsOneWidget);
      expect(find.textContaining('共 2 项提问或审批等待处理'), findsOneWidget);
      final refreshButton = find.byKey(const Key('refresh-sessions'));
      expect(refreshButton, findsOneWidget);
      expect(tester.widget<ShadIconButton>(refreshButton).onPressed, isNotNull);
      expect(find.byKey(const Key('fork-codex-session')), findsNothing);
      expect(
        tester
            .widget<ShadTextarea>(find.byKey(const Key('message-composer')))
            .enabled,
        isTrue,
      );
      expect(find.text('发送到 Codex 桌面会话…'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('Queued from phone'),
        180,
        scrollable: _messageScrollable(),
      );
      expect(find.textContaining('Queued from phone'), findsOneWidget);
      expect(find.textContaining('附带 1 张图片'), findsOneWidget);
      expect(find.text('Codex 队列状态暂不可确认'), findsOneWidget);
      final withdrawButton = find.byKey(const Key('withdraw-queued-queued-1'));
      await tester.ensureVisible(withdrawButton);
      await tester.pumpAndSettle();
      await tester.tap(withdrawButton);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (controller.queuedMessages.isNotEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(withdrawnQueueId, 'queued-1');
      expect(find.byKey(const Key('queued-message-queued-1')), findsNothing);
      expect(find.text('Codex 队列状态暂不可确认'), findsNothing);

      final questionButton = find.byKey(
        const Key('open-text-question-choice-1'),
      );
      await tester.scrollUntilVisible(
        questionButton,
        180,
        scrollable: _messageScrollable(),
      );
      await tester.drag(_messageScrollable(), const Offset(0, -160));
      await tester.pumpAndSettle();
      await tester.tap(questionButton);
      await tester.pumpAndSettle();
      expect(find.text('识别到文字选择题'), findsWidgets);
      await tester.tap(find.byKey(const Key('questionnaire-option-B. 快速')));
      await tester.pumpAndSettle();
      expect(choiceReply, isNull);
      await tester.tap(find.byKey(const Key('questionnaire-submit-option')));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (choiceReply == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(choiceReply, 'B. 快速');
      final questionCloseDeadline = DateTime.now().add(
        const Duration(seconds: 2),
      );
      while (find.text('识别到文字选择题').evaluate().isNotEmpty &&
          DateTime.now().isBefore(questionCloseDeadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('识别到文字选择题'), findsNothing);
      expect(find.byType(ShadDialog), findsNothing);

      await tester.runAsync(
        () => controller.selectSession(
          controller.sessions.firstWhere(
            (session) => session.id == 'codex:remote',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.selectedSessionId, 'codex:remote');
      final modelButton = find.byKey(const Key('codex-model-settings'));
      await tester.scrollUntilVisible(
        modelButton,
        180,
        scrollable: _messageScrollable(),
      );
      await tester.tap(modelButton);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(find.text('模型与思考强度'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-codex-settings')));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (selectedEffort == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(selectedEffort, 'medium');
      expect(find.byType(ShadDialog), findsNothing);
      final composer = find.byKey(const Key('message-composer'));
      await tester.enterText(composer, '/ski');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('composer-suggestion-/skills')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('composer-suggestion-\$review')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('composer-suggestion-\$review')));
      expect(
        tester.widget<ShadTextarea>(composer).controller?.text,
        '\$review ',
      );
      final stopButton = find.byKey(const Key('send-reply'));
      await tester.scrollUntilVisible(
        stopButton,
        180,
        scrollable: _messageScrollable(),
      );
      await tester.tap(stopButton);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (!interrupted && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(interrupted, isTrue);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(composer, '/review');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('composer-suggestion-/review')));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (actions.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(actions, ['review']);
      await tester.enterText(composer, '/compact');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('composer-suggestion-/compact')));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (actions.length < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(actions, ['review', 'compact']);
    } finally {
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.runAsync(() async {
        await controller.disconnect();
        await serverSubscription.cancel();
        await server.close(force: true);
      });
      controller.dispose();
    }
  });
}

Widget _componentApp(Widget child) {
  return ShadApp.custom(
    theme: buildShadTheme(),
    appBuilder: (context) => MaterialApp(
      theme: buildShadMaterialTheme(),
      builder: (context, child) => ShadAppBuilder(child: child),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
}

Finder _formInput(WidgetTester tester, String formId, String fieldKey) =>
    find.descendant(
      of: find.byKey(Key('form-field-$formId-$fieldKey')),
      matching: find.byType(EditableText),
    );

Finder _messageScrollable() => find
    .descendant(
      of: find.byType(AgentMessageScroller),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _enterFormInput(
  WidgetTester tester,
  String formId,
  String fieldKey,
  String value,
) async {
  await tester.enterText(_formInput(tester, formId, fieldKey), value);
}

Future<void> _enterShadField(
  WidgetTester tester,
  String key,
  String value,
) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(EditableText),
    ),
    value,
  );
}

Future<void> _tapConnect(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -520));
  await tester.pumpAndSettle();
  final button = find.byKey(const Key('connect-local-host'));
  await tester.ensureVisible(button);
  await tester.tap(button);
}
