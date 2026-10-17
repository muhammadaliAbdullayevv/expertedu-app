import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// One line in the command bar: an action to run, a place to go, or a
/// person to open.
class PaletteEntry {
  const PaletteEntry({
    required this.group,
    required this.label,
    required this.icon,
    required this.run,
    this.subtitle,
    this.keywords = const [],
  });

  final String group;
  final String label;
  final String? subtitle;
  final IconData icon;

  /// Extra words that also find this entry ("kassa" for the payment action).
  final List<String> keywords;
  final VoidCallback run;
}

/// Uzbek is typed with several apostrophes (', ʻ, ’, `) and in any case;
/// searching treats them all as one.
String normalizeQuery(String text) =>
    text.toLowerCase().replaceAll(RegExp('[ʻʼ‘’`´]'), '\'').trim();

/// The entries matching [query], best first: label starts with it, then
/// a word in the label starts with it, then anywhere in label, subtitle or
/// keywords. An empty query keeps everything in its given order.
List<PaletteEntry> filterEntries(List<PaletteEntry> entries, String query) {
  final q = normalizeQuery(query);
  if (q.isEmpty) return List.of(entries);
  final scored = <(int, int, PaletteEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final label = normalizeQuery(e.label);
    int? score;
    if (label.startsWith(q)) {
      score = 0;
    } else if (label.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) {
      score = 1;
    } else if (label.contains(q)) {
      score = 2;
    } else if ([
      e.subtitle ?? '',
      ...e.keywords,
    ].any((t) => normalizeQuery(t).contains(q))) {
      score = 3;
    }
    if (score != null) scored.add((score, i, e));
  }
  scored.sort(
    (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
  );
  return [for (final s in scored) s.$3];
}

/// Opens the command bar. [entries] are the actions and destinations (kept
/// in view and filtered as you type); [searchRemote] adds people found by
/// the server once at least two characters are typed.
Future<void> showCommandPalette(
  BuildContext context, {
  required List<PaletteEntry> entries,
  Future<List<PaletteEntry>> Function(String query)? searchRemote,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x7317171A),
    builder: (context) => Align(
      alignment: const Alignment(0, -0.55),
      child: _CommandPalette(entries: entries, searchRemote: searchRemote),
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.entries, this.searchRemote});

  final List<PaletteEntry> entries;
  final Future<List<PaletteEntry>> Function(String query)? searchRemote;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  int _requestId = 0;
  int _highlight = 0;
  bool _searching = false;
  List<PaletteEntry> _remote = const [];

  List<PaletteEntry> get _results => [
    ...filterEntries(widget.entries, _controller.text),
    ..._remote,
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() => _highlight = 0);
    _debounce?.cancel();
    final query = text.trim();
    if (widget.searchRemote == null || query.length < 2) {
      setState(() {
        _remote = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final id = ++_requestId;
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      List<PaletteEntry> found;
      try {
        found = await widget.searchRemote!(query);
      } catch (_) {
        // Offline or a server hiccup: the local entries still work.
        found = const [];
      }
      if (!mounted || id != _requestId) return;
      setState(() {
        _remote = found;
        _searching = false;
      });
    });
  }

  void _move(int delta) {
    final count = _results.length;
    if (count == 0) return;
    setState(() => _highlight = (_highlight + delta) % count);
  }

  void _run(PaletteEntry entry) {
    Navigator.of(context).pop();
    // After the dialog is gone, so the action's own dialogs stack cleanly.
    WidgetsBinding.instance.addPostFrameCallback((_) => entry.run());
  }

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    final results = _results;
    if (_highlight >= results.length) _highlight = 0;
    return Material(
      color: Colors.transparent,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        },
        child: Semantics(
          label: s.commandBarTitle,
          scopesRoute: true,
          explicitChildNodes: true,
          child: Container(
            width: 580,
            constraints: const BoxConstraints(maxHeight: 460),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card + 2),
              border: Border.all(color: AppColors.border),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x2617171A),
                  blurRadius: 40,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.search_rounded,
                        color: AppColors.inkMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          autofocus: true,
                          onChanged: _onChanged,
                          onSubmitted: (_) {
                            if (results.isNotEmpty) _run(results[_highlight]);
                          },
                          style: const TextStyle(fontSize: 16),
                          decoration: InputDecoration(
                            hintText: s.commandBarHint,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                          ),
                        ),
                      ),
                      const _KeyHint('Esc'),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.border),
                Flexible(
                  child: results.isEmpty && !_searching
                      ? Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text(
                            s.commandNothingFound,
                            style: const TextStyle(color: AppColors.inkMuted),
                          ),
                        )
                      : ListView(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          children: <Widget>[
                            for (
                              var i = 0;
                              i < results.length;
                              i++
                            ) ...<Widget>[
                              if (i == 0 ||
                                  results[i - 1].group != results[i].group)
                                _GroupHeader(results[i].group),
                              _EntryTile(
                                entry: results[i],
                                highlighted: i == _highlight,
                                onTap: () => _run(results[i]),
                                onHover: () => setState(() => _highlight = i),
                              ),
                            ],
                            if (_searching)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  10,
                                  20,
                                  10,
                                ),
                                child: Text(
                                  s.commandSearching,
                                  style: const TextStyle(
                                    color: AppColors.inkMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.88,
          color: AppColors.inkMuted,
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final PaletteEntry entry;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => onHover(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: highlighted ? AppColors.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                entry.icon,
                size: 19,
                color: highlighted
                    ? AppColors.accentText
                    : AppColors.inkSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: highlighted
                            ? AppColors.accentText
                            : AppColors.ink,
                      ),
                    ),
                    if (entry.subtitle != null)
                      Text(
                        entry.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (highlighted) const _KeyHint('Enter'),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyHint extends StatelessWidget {
  const _KeyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderStrong),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
