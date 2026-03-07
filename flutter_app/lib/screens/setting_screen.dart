import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String _kTranslateToThaiKey = 'ui.translateToThai';
  static const String _kSpeechRateKey = 'tts.speechRate';

  // Defaults
  bool _vibration = true;
  bool _speech = true;
  bool _subtitle = true;
  bool _translateToThai = true;
  double _speechRate = 0.5;

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
      _vibration = prefs.getBool(_kVibrationKey) ?? true;
      _speech = prefs.getBool(_kSpeechKey) ?? true;
      _subtitle = prefs.getBool(_kSubtitleKey) ?? true;
      _translateToThai = prefs.getBool(_kTranslateToThaiKey) ?? true;
      _speechRate = prefs.getDouble(_kSpeechRateKey) ?? 0.5;
      _loading = false;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVibrationKey, _vibration);
    await prefs.setBool(_kSpeechKey, _speech);
    await prefs.setBool(_kSubtitleKey, _subtitle);
    await prefs.setBool(_kTranslateToThaiKey, _translateToThai);
    await prefs.setDouble(_kSpeechRateKey, _speechRate);
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
        title: const Text('การตั้งค่า'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle('การแจ้งเตือน'),
                const SizedBox(height: 8),
                _switchTile(
                  title: 'การสั่น',
                  subtitle: 'สั่นเมื่อมีการแจ้งเตือนด้วยเสียง',
                  value: _vibration,
                  onChanged: (v) async {
                    setState(() => _vibration = v);
                    await _savePrefs();
                  },
                ),
                _switchTile(
                  title: 'เสียงพูด',
                  subtitle: 'เปิดการอ่านข้อความด้วยเสียง',
                  value: _speech,
                  onChanged: (v) async {
                    setState(() => _speech = v);
                    await _savePrefs();
                  },
                ),
                _switchTile(
                  title: 'คำบรรยาย',
                  subtitle: 'แสดงข้อความบนหน้าจอ',
                  value: _subtitle,
                  onChanged: (v) async {
                    setState(() => _subtitle = v);
                    await _savePrefs();
                  },
                ),
                _switchTile(
                  title: 'แปลผลลัพธ์เป็นภาษาไทย',
                  subtitle: 'แปลคำอธิบายภาษาอังกฤษจาก AI เป็นภาษาไทยก่อนพูด',
                  value: _translateToThai,
                  onChanged: (v) async {
                    setState(() => _translateToThai = v);
                    await _savePrefs();
                  },
                ),
                const SizedBox(height: 20),
                _sectionTitle('ความเร็วเสียงพูด'),
                const SizedBox(height: 6),
                Text(
                  'ปรับความเร็วในการอ่านออกเสียง',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                Text(
                  'โหมดความปลอดภัยถูกตั้งเป็นค่าเริ่มต้นตลอดเวลา',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
