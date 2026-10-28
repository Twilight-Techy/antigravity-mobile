import 'package:flutter/material.dart';

import '../../services/agy_service.dart';
import '../../services/message_builder.dart';
import '../../state/chat_controller.dart';
import '../../state/session_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/markdown_view.dart';

/// Shows reports agy answers headlessly (`agy -p /usage`, `/credits`,
/// `/skills`…), so quota and the like don't need the terminal.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.session, required this.title, required this.commands});

  /// Passed in because pushed routes sit outside the session's providers.
  final SessionState session;
  final String title;
  final List<String> commands;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Future<List<AgyReport>> _reports = _load();

  Future<List<AgyReport>> _load() async {
    final agy = widget.session.agy;
    if (agy == null) throw StateError('Not connected.');
    return [for (final c in widget.commands) await agy.report(c)];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => setState(() => _reports = _load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<AgyReport>>(
        future: _reports,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorPanel(
                message: snap.error.toString(), onRetry: () => setState(() => _reports = _load()));
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [for (final r in snap.data!) _ReportSection(report: r, session: widget.session)],
          );
        },
      ),
    );
  }
}

class _ReportSection extends StatelessWidget {
  const _ReportSection({required this.report, required this.session});
  final AgyReport report;
  final SessionState session;

  @override
  Widget build(BuildContext context) {
    final error = report.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('agy -p ${report.command}', style: monoStyle(size: 11.5, color: AppColors.textFaint)),
          const SizedBox(height: 8),
          if (error != null) ...[
            SelectableText(error, style: monoStyle(size: 12.5, color: AppColors.danger)),
            if (needsSignIn(error))
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await session.reopenSetup();
                },
                child: const Text('Sign in'),
              ),
          ] else if (report.text.trim().isEmpty)
            Text(_emptyText(report), style: const TextStyle(color: AppColors.textMuted))
          else
            MarkdownView(commandReportMarkdown(report.text)),
        ],
      ),
    );
  }

  static String _emptyText(AgyReport r) => switch (r.command) {
        '/usage' => 'No quota information. agy reports quota for Google sign-in, not for a Gemini API key.',
        '/hooks' => 'No hooks configured.',
        '/agents' => 'No custom agents.',
        _ => 'Nothing to show.',
      };
}
