import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_setting_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Preference keys (stable)
  static const String _kVibrationKey = 'ui.vibration';
  static const String _kSpeechKey = 'ui.speech';
  static const String _kSubtitleKey = 'ui.subtitle';
  static const String _kSpeechRateKey = 'tts.speechRate';
  static const String _kSelectedModelKey = 'model.selected';

  // Defaults
  bool _vibration = true;
  bool _speech = true;
  bool _subtitle = true;
  double _speechRate = 0.5;

  final List<String> _models = const ['FastVLM 0.5B (Default)'];
  late String _selectedModel;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selectedModel = _models.first;
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      _vibration = prefs.getBool(_kVibrationKey) ?? true;
      _speech = prefs.getBool(_kSpeechKey) ?? true;
      _subtitle = prefs.getBool(_kSubtitleKey) ?? true;
      _speechRate = prefs.getDouble(_kSpeechRateKey) ?? 0.5;
      _selectedModel = prefs.getString(_kSelectedModelKey) ?? _models.first;
      _loading = false;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVibrationKey, _vibration);
    await prefs.setBool(_kSpeechKey, _speech);
    await prefs.setBool(_kSubtitleKey, _subtitle);
    await prefs.setDouble(_kSpeechRateKey, _speechRate);
    await prefs.setString(_kSelectedModelKey, _selectedModel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = theme.scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: const Text('Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle('Alert Settings'),
                const SizedBox(height: 8),
                _switchTile(
                  title: 'Vibration',
                  subtitle: 'Vibrate when an alert is spoken.',
                  value: _vibration,
                  onChanged: (v) async {
                    setState(() => _vibration = v);
                    await _savePrefs();
                  },
                ),
                _switchTile(
                  title: 'Speech',
                  subtitle: 'Enable text-to-speech output.',
                  value: _speech,
                  onChanged: (v) async {
                    setState(() => _speech = v);
                    await _savePrefs();
                  },
                ),
                _switchTile(
                  title: 'Subtitle',
                  subtitle: 'Show on-screen text overlay.',
                  value: _subtitle,
                  onChanged: (v) async {
                    setState(() => _subtitle = v);
                    await _savePrefs();
                  },
                ),
                const SizedBox(height: 20),
                _sectionTitle('Speech Rate'),
                const SizedBox(height: 6),
                Text(
                  'Controls how fast the voice speaks.',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _speechRate,
                        min: 0.0,
                        max: 1.0,
                        divisions: 20,
                        label: _speechRate.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _speechRate = v),
                        onChangeEnd: (_) => _savePrefs(),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        _speechRate.toStringAsFixed(2),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _sectionTitle('Model'),
                const SizedBox(height: 8),
                _modelDropdown(theme),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ModelSettingsScreen()),
                    );
                    // In case the model page changed prefs, refresh.
                    await _loadPrefs();
                  },
                  child: const Text('Model Settings'),
                ),
              ],
            ),
    );
  }

  Widget _modelDropdown(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButton<String>(
        value: _selectedModel,
        isExpanded: true,
        underline: const SizedBox(),
        dropdownColor: Colors.black,
        iconEnabledColor: Colors.white,
        style: const TextStyle(color: Colors.white),
        items: _models
            .map(
              (m) => DropdownMenuItem(
                value: m,
                child: Text(m, style: const TextStyle(color: Colors.white)),
              ),
            )
            .toList(),
        onChanged: (v) async {
          if (v == null) return;
          setState(() => _selectedModel = v);
          await _savePrefs();
        },
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
