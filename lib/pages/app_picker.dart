import 'package:flutter/material.dart';

import '../engine/engine_client.dart';
import '../theme/app_theme.dart';
import '../widgets/icons.dart';
import '../widgets/ui.dart';

/// 目标应用选择面板：加载 / 空 / 错误+重试 / 搜索过滤，四种状态齐备。
Future<void> showAppPicker(BuildContext context, EngineModel engine) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AppPickerSheet(engine: engine),
  );
}

class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet({required this.engine});

  final EngineModel engine;

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  late Future<List<AppEntry>> _future = widget.engine.listApps();
  String _query = '';

  void _retry() => setState(() => _future = widget.engine.listApps());

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.74;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(T.pad, 0, T.pad, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TARGET APP', style: tm(9, ls: 2.7)),
                const SizedBox(height: 8),
                Text('选择目标应用', style: ts(22, ls: 1.2)),
                const Hint('只列出有启动入口的应用；选中后会直接启动到眼镜屏', top: 10),
                const SizedBox(height: 14),
                _SearchField(
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<AppEntry>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _SheetState(text: '正在读取应用列表…', busy: true);
                }
                if (snap.hasError) {
                  return _SheetState(
                    text: '${snap.error}',
                    actionLabel: '重试',
                    onAction: _retry,
                  );
                }
                final all = snap.data ?? const <AppEntry>[];
                final list = _query.isEmpty
                    ? all
                    : all
                        .where((a) =>
                            a.label.toLowerCase().contains(_query.toLowerCase()))
                        .toList();
                if (all.isEmpty) {
                  return const _SheetState(text: '设备上没有带启动入口的应用');
                }
                if (list.isEmpty) {
                  return const _SheetState(text: '没有匹配的应用，换个关键词试试');
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(T.pad, 0, T.pad, 24),
                  itemCount: list.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _AppRow(
                      app: list[i],
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.engine.setHostedApp(list[i]);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: T.hair1),
      ),
      child: Row(
        children: [
          LineIcon(icoSearch, size: 16, color: T.faint, stroke: 1.4),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onChanged,
              cursorHeight: 14,
              style: ts(13, ls: 0.3),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索应用',
                hintStyle: ts(13, color: T.faint, ls: 0.3),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _controller.clear();
                widget.onChanged('');
                setState(() {});
              },
              child: LineIcon(icoClose, size: 14, color: T.faint),
            ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.onTap});

  final AppEntry app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initial = app.label.isEmpty ? '?' : app.label.substring(0, 1);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: T.hair1),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: T.wisteria.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: T.wisteria.withValues(alpha: 0.26),
                ),
              ),
              child: Center(
                child: Text(initial, style: ts(13, color: A.petalA)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(13.5, ls: 0.3),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    app.component.split('/').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tm(9.5, color: T.code, ls: 0.4),
                  ),
                ],
              ),
            ),
            LineIcon(icoChevron, size: 14, color: T.arrow),
          ],
        ),
      ),
    );
  }
}

/// 面板内的加载 / 空 / 错误态：一行等宽字 + 可选按钮。
class _SheetState extends StatelessWidget {
  const _SheetState({
    required this.text,
    this.busy = false,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final bool busy;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(height: 14),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: ts(11.5, color: T.faint, height: 1.7, ls: 0.3),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              MiniButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}
