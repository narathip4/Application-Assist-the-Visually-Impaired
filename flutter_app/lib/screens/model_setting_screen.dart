import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ModelSettingsScreen extends StatefulWidget {
  const ModelSettingsScreen({super.key});

  @override
  State<ModelSettingsScreen> createState() => _ModelSettingsScreenState();
}

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  // Keep keys stable (used by SettingsScreen / other parts later)
  static const String _kTemperatureKey = 'model.temperature';
  static const String _kMaxTokensKey = 'model.maxTokens';

  // Defaults (match your current app assumptions)
  static const double _defaultTemperature = 0.5;
  static const int _defaultMaxTokens = 32;

  double _temperature = _defaultTemperature;
  int _maxTokens = _defaultMaxTokens;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      _temperature = prefs.getDouble(_kTemperatureKey) ?? _defaultTemperature;
      _maxTokens = prefs.getInt(_kMaxTokensKey) ?? _defaultMaxTokens;
      _loading = false;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTemperatureKey, _temperature);
    await prefs.setInt(_kMaxTokensKey, _maxTokens);
  }

  Future<void> _resetDefaults() async {
    setState(() {
      _temperature = _defaultTemperature;
      _maxTokens = _defaultMaxTokens;
    });
    await _savePrefs();
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
        title: const Text('Model Settings'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _resetDefaults,
            child: const Text('Reset'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle('Temperature'),
                _helperText(
                  'Higher = more creative (can be less stable). Lower = more consistent.',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _temperature,
                        min: 0.0,
                        max: 1.0,
                        divisions: 20,
                        label: _temperature.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _temperature = v),
                        onChangeEnd: (_) => _savePrefs(),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        _temperature.toStringAsFixed(2),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _sectionTitle('Max Tokens'),
                _helperText(
                  'Higher = longer explanations (slower). Lower = shorter responses (can cut sentences).',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _maxTokens.toDouble(),
                        min: 0,
                        max: 128,
                        divisions: 16,
                        label: '$_maxTokens',
                        onChanged: (v) => setState(() => _maxTokens = v.round()),
                        onChangeEnd: (_) => _savePrefs(),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '$_maxTokens',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Note: These values are saved locally. Ensure your VLM service reads these preferences when building the request.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    );
  }

  Widget _helperText(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.3),
    );
  }
}
