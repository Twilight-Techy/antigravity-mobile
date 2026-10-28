import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import 'common.dart';

/// Renders agent markdown with Antigravity-style code blocks.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.data, {super.key, this.selectable = true});

  final String data;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!.copyWith(fontSize: 15, height: 1.5, color: AppColors.text);
    return MarkdownBody(
      data: data,
      selectable: selectable,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBlockBuilder()},
      onTapLink: (text, href, title) {
        if (href != null) launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: base,
        listBullet: base,
        h1: base.copyWith(fontSize: 21, fontWeight: FontWeight.w700, height: 1.3),
        h2: base.copyWith(fontSize: 18.5, fontWeight: FontWeight.w700, height: 1.3),
        h3: base.copyWith(fontSize: 16.5, fontWeight: FontWeight.w600),
        h4: base.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        a: base.copyWith(color: AppColors.accent, decoration: TextDecoration.underline),
        code: monoStyle(size: 13, color: const Color(0xFFE6B673)).copyWith(
          backgroundColor: AppColors.surfaceHigh,
        ),
        blockquote: base.copyWith(color: AppColors.textMuted),
        blockquoteDecoration: const BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.border, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        tableHead: base.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5),
        tableBody: base.copyWith(fontSize: 13.5),
        tableBorder: TableBorder.all(color: AppColors.border),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        blockSpacing: 10,
        listIndent: 22,
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String? language;
    final first = element.children?.isNotEmpty == true ? element.children!.first : null;
    if (first is md.Element) {
      final cls = first.attributes['class'];
      if (cls != null && cls.startsWith('language-')) language = cls.substring(9);
    }
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return CodeBlock(code: code, language: language);
  }
}

/// A highlighted, horizontally scrollable code block with a copy button.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language, this.maxHeight});

  final String code;
  final String? language;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SelectableText.rich(
        TextSpan(
          style: monoStyle(size: 12.5, color: const Color(0xFFD5D9E0)),
          children: highlightSpans(code, language),
        ),
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.codeBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Text(language?.isNotEmpty == true ? language! : 'code',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: () => copyText(context, code),
                  icon: const Icon(Icons.copy_rounded, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (maxHeight != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight!),
              child: SingleChildScrollView(child: body),
            )
          else
            body,
        ],
      ),
    );
  }
}

/// Syntax-highlights [code]; falls back to plain text for unknown languages
/// or very large inputs.
List<TextSpan> highlightSpans(String code, String? language) {
  if (code.length > 200000) return [TextSpan(text: code)];
  try {
    final lang = _aliases[language?.toLowerCase()] ?? language?.toLowerCase();
    final result = lang == null || lang.isEmpty
        ? highlight.parse(code, autoDetection: code.length < 20000)
        : highlight.parse(code, language: lang);
    final nodes = result.nodes;
    if (nodes == null) return [TextSpan(text: code)];
    return _convert(nodes);
  } catch (_) {
    return [TextSpan(text: code)];
  }
}

List<TextSpan> _convert(List<Node> nodes) {
  final spans = <TextSpan>[];
  var current = spans;
  final stack = <List<TextSpan>>[];

  void traverse(Node node) {
    final style = node.className == null ? null : atomOneDarkTheme[node.className!];
    if (node.value != null) {
      current.add(TextSpan(text: node.value, style: style?.copyWith(backgroundColor: Colors.transparent)));
    } else if (node.children != null) {
      final children = <TextSpan>[];
      current.add(TextSpan(children: children, style: style?.copyWith(backgroundColor: Colors.transparent)));
      stack.add(current);
      current = children;
      for (final n in node.children!) {
        traverse(n);
      }
      current = stack.removeLast();
    }
  }

  for (final node in nodes) {
    traverse(node);
  }
  return spans;
}

const _aliases = {
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'js': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'rb': 'ruby',
  'yml': 'yaml',
  'kt': 'kotlin',
  'rs': 'rust',
  'md': 'markdown',
  'html': 'xml',
  'vue': 'xml',
  'c++': 'cpp',
  'h': 'cpp',
  'cs': 'cs',
  'ps1': 'powershell',
  'dockerfile': 'dockerfile',
  'tf': 'hcl',
  'patch': 'diff',
};

/// Guesses a highlight.js language from a file name.
String? languageForFile(String name) {
  final lower = name.toLowerCase();
  if (lower == 'dockerfile') return 'dockerfile';
  if (lower == 'makefile') return 'makefile';
  final ext = lower.contains('.') ? lower.split('.').last : '';
  const map = {
    'dart': 'dart', 'py': 'python', 'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
    'jsx': 'javascript', 'ts': 'typescript', 'tsx': 'typescript', 'json': 'json', 'yaml': 'yaml',
    'yml': 'yaml', 'md': 'markdown', 'sh': 'bash', 'bash': 'bash', 'zsh': 'bash', 'go': 'go',
    'rs': 'rust', 'java': 'java', 'kt': 'kotlin', 'kts': 'kotlin', 'swift': 'swift', 'rb': 'ruby',
    'php': 'php', 'c': 'cpp', 'h': 'cpp', 'cc': 'cpp', 'cpp': 'cpp', 'hpp': 'cpp', 'cs': 'cs',
    'html': 'xml', 'xml': 'xml', 'svg': 'xml', 'css': 'css', 'scss': 'scss', 'sql': 'sql',
    'toml': 'ini', 'ini': 'ini', 'cfg': 'ini', 'conf': 'ini', 'ps1': 'powershell', 'lua': 'lua',
    'r': 'r', 'scala': 'scala', 'gradle': 'gradle', 'diff': 'diff', 'patch': 'diff', 'tf': 'hcl',
    'vue': 'xml', 'proto': 'protobuf', 'ex': 'elixir', 'exs': 'elixir', 'hs': 'haskell',
  };
  return map[ext];
}
