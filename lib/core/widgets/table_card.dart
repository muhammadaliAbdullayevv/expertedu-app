import 'package:flutter/material.dart';

import '../extensions/build_context_x.dart';

class TableColumn {
  const TableColumn(
    this.label, {
    this.flex = 1,
    this.width,
    this.alignEnd = false,
  });

  final String label;
  final int flex;

  /// Fixed width instead of a [flex] share -- for icon/action columns.
  final double? width;
  final bool alignEnd;
}

/// A bordered card holding a header row and scrollable data rows -- the
/// desktop's table look (Settings' groups and teachers lists). Fills the
/// height it's given, so put it in an Expanded.
class TableCard extends StatelessWidget {
  const TableCard({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.cell,
    this.onRowTap,
    this.emptyText = 'Hali hech narsa yo\'q',
  });

  final List<TableColumn> columns;
  final int rowCount;
  final Widget Function(BuildContext context, int row, int column) cell;
  final ValueChanged<int>? onRowTap;
  final String emptyText;

  static const double _columnGap = 16;

  Widget _layout(List<Widget> cells) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < columns.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: _columnGap),
          if (columns[i].width != null)
            SizedBox(width: columns[i].width, child: cells[i])
          else
            Expanded(
              flex: columns[i].flex,
              child: Align(
                alignment: columns[i].alignEnd
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: cells[i],
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final headerStyle = context.textTheme.labelMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Container(
            color: context.colors.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: _layout(<Widget>[
              for (final column in columns)
                Text(column.label, style: headerStyle),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: rowCount == 0
                ? Center(
                    child: Text(
                      emptyText,
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: rowCount,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, row) => InkWell(
                      onTap: onRowTap == null ? null : () => onRowTap!(row),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: _layout(<Widget>[
                          for (var c = 0; c < columns.length; c++)
                            cell(context, row, c),
                        ]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
