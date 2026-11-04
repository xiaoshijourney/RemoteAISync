import 'package:flutter/material.dart';

import '../application/demo_controller.dart';
import 'screens/connection_screen.dart';
import 'screens/files_screen.dart';
import 'screens/session_screen.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({required this.controller, super.key});

  final DemoController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _BrandBar(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: IndexedStack(
                  index: _selectedIndex,
                  children: [
                    SessionScreen(controller: widget.controller),
                    const FilesScreen(),
                    const ConnectionScreen(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '会话',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '文件',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: '连接',
          ),
        ],
      ),
    );
  }
}

class _BrandBar extends StatelessWidget {
  const _BrandBar();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: appLine)),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: appGreen,
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Icon(Icons.sync_alt, color: Colors.white, size: 19),
            ),
            const SizedBox(width: 10),
            Text(
              'RemoteAISync',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontSize: 16, letterSpacing: 0),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4DF),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '本地演示',
                style: TextStyle(
                  color: appAmber,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
