import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/server_profile.dart';
import '../../state/servers_state.dart';
import '../theme/app_theme.dart';

/// A hard-to-guess ntfy topic name; anyone who knows it can read the pushes.
String randomTopic() {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return 'agm-${List.generate(20, (_) => chars[r.nextInt(chars.length)]).join()}';
}

/// Add or edit a server. Pops with the saved profile.
class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({super.key, required this.profile, required this.isNew});

  final ServerProfile profile;
  final bool isNew;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile.name);
  late final _host = TextEditingController(text: widget.profile.host);
  late final _port = TextEditingController(text: '${widget.profile.port}');
  late final _user = TextEditingController(text: widget.profile.username);
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  final _apiKey = TextEditingController();
  late AuthMethod _auth = widget.profile.authMethod;
  late bool _useTmux = widget.profile.useTmux;
  late bool _notify = widget.profile.notifyOnFinish;
  late final _ntfy = TextEditingController(text: widget.profile.ntfyUrl ?? '');
  bool _showPassword = false;
  bool _saving = false;
  bool _loadingSecrets = true;

  @override
  void initState() {
    super.initState();
    _loadSecrets();
  }

  Future<void> _loadSecrets() async {
    if (!widget.isNew) {
      final s = await context.read<ServersState>().storage.loadSecrets(widget.profile.id);
      _password.text = s.password ?? '';
      _key.text = s.privateKey ?? '';
      _passphrase.text = s.passphrase ?? '';
      _apiKey.text = s.geminiApiKey ?? '';
    }
    if (mounted) setState(() => _loadingSecrets = false);
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _password, _key, _passphrase, _apiKey, _ntfy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _key.text = data!.text!.trim());
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final servers = context.read<ServersState>();
    final p = widget.profile
      ..host = _host.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? 22
      ..username = _user.text.trim()
      ..authMethod = _auth
      ..useTmux = _useTmux
      ..notifyOnFinish = _notify
      ..ntfyUrl = _ntfy.text.trim().isEmpty ? null : _ntfy.text.trim();
    p.name = _name.text.trim().isEmpty ? p.host : _name.text.trim();
    String? orNull(String s) => s.trim().isEmpty ? null : s;
    await servers.save(
      p,
      ServerSecrets(
        password: _auth == AuthMethod.password ? orNull(_password.text) : null,
        privateKey: _auth == AuthMethod.privateKey ? orNull(_key.text.trim()) : null,
        passphrase: _auth == AuthMethod.privateKey ? orNull(_passphrase.text) : null,
        geminiApiKey: orNull(_apiKey.text.trim()),
      ),
    );
    if (mounted) Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isNew ? 'Add server' : 'Edit server')),
      body: _loadingSecrets
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  _label('Connection'),
                  TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(
                        labelText: 'Host', hintText: '203.0.113.10 or vps.example.com'),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: (v) => v == null || v.trim().isEmpty ? 'Enter the server address' : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _user,
                          decoration: const InputDecoration(labelText: 'Username'),
                          autocorrect: false,
                          validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _port,
                          decoration: const InputDecoration(labelText: 'Port'),
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            return n == null || n < 1 || n > 65535 ? 'Invalid' : null;
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                        labelText: 'Display name (optional)', hintText: 'My VPS'),
                  ),
                  _label('Authentication'),
                  SegmentedButton<AuthMethod>(
                    segments: const [
                      ButtonSegment(
                          value: AuthMethod.password,
                          icon: Icon(Icons.password),
                          label: Text('Password')),
                      ButtonSegment(
                          value: AuthMethod.privateKey,
                          icon: Icon(Icons.key),
                          label: Text('Private key')),
                    ],
                    selected: {_auth},
                    onSelectionChanged: (s) => setState(() => _auth = s.first),
                  ),
                  const SizedBox(height: 14),
                  if (_auth == AuthMethod.password)
                    TextFormField(
                      controller: _password,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      validator: (v) => v == null || v.isEmpty ? 'Enter the password' : null,
                    )
                  else ...[
                    TextFormField(
                      controller: _key,
                      minLines: 4,
                      maxLines: 8,
                      style: monoStyle(size: 11.5),
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Private key (OpenSSH / PEM)',
                        hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                        alignLabelWithHint: true,
                        suffixIcon: IconButton(
                          tooltip: 'Paste',
                          icon: const Icon(Icons.content_paste),
                          onPressed: _pasteKey,
                        ),
                      ),
                      validator: (v) => v == null || !v.contains('PRIVATE KEY')
                          ? 'Paste a private key (it contains "PRIVATE KEY")'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passphrase,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Key passphrase (if any)'),
                    ),
                  ],
                  const SizedBox(height: 6),
                  const Text(
                    'Credentials are kept in the device keystore and only sent to this server.',
                    style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                  ),
                  _label('Options'),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: _useTmux,
                          onChanged: (v) => setState(() => _useTmux = v),
                          title: const Text('Keep terminal sessions alive'),
                          subtitle: const Text(
                              'Runs the interactive terminal in tmux so agy keeps running when your phone disconnects.'),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: _notify,
                          onChanged: (v) => setState(() => _notify = v),
                          title: const Text('Notify me when the agent finishes'),
                          subtitle: const Text(
                              'While the app is in the background. On iOS the system only allows this for a short while, so see the option below for long tasks.'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ntfy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: monoStyle(size: 13),
                    decoration: InputDecoration(
                      labelText: 'Push via ntfy (optional)',
                      hintText: 'https://ntfy.sh/your-topic',
                      helperText:
                          'The server posts here when a task ends, so you get a push even if the app is closed. Subscribe to the topic in the ntfy app. Only the workspace name is sent.',
                      helperMaxLines: 4,
                      suffixIcon: IconButton(
                        tooltip: 'Generate a private topic',
                        icon: const Icon(Icons.casino_outlined),
                        onPressed: () => setState(() => _ntfy.text = 'https://ntfy.sh/${randomTopic()}'),
                      ),
                    ),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return null;
                      final uri = Uri.tryParse(t);
                      return uri == null || !uri.isScheme('https') && !uri.isScheme('http') || uri.pathSegments.isEmpty
                          ? 'Enter a topic URL like https://ntfy.sh/my-topic'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _apiKey,
                    obscureText: true,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API key (optional)',
                      helperText: 'Only needed if you use an API key instead of Google sign-in.',
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(widget.isNew ? 'Save and connect' : 'Save'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: AppColors.textFaint,
                fontSize: 12,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600)),
      );
}
