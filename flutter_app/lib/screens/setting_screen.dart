import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model_setting_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool vibration = true;
  bool speech = true;
  bool subtitle = true;
  double speechSpeed = 0.5;
  String selectedModel = 'FastVLM 0.5B (Default)';

  final List<String> models = ['FastVLM 0.5B (Default)'];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      vibration = prefs.getBool('vibration') ?? true;
      speech = prefs.getBool('speech') ?? true;
      subtitle = prefs.getBool('subtitle') ?? true;
      speechSpeed = prefs.getDouble('speechSpeed') ?? 0.5;
      selectedModel = prefs.getString('selectedModel') ?? models.first;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vibration', vibration);
    await prefs.setBool('speech', speech);
    await prefs.setBool('subtitle', subtitle);
    await prefs.setDouble('speechSpeed', speechSpeed);
    await prefs.setString('selectedModel', selectedModel);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.grey.shade100,
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text(
              'Alert Settings',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            _buildSwitchTile('Vibration', vibration, (v) {
              setState(() => vibration = v);
              _savePrefs();
            }),
            _buildSwitchTile('Speech', speech, (v) {
              setState(() => speech = v);
              _savePrefs();
            }),
            _buildSwitchTile('Subtitle', subtitle, (v) {
              setState(() => subtitle = v);
              _savePrefs();
            }),

            const SizedBox(height: 16),
            const Text(
              'Speech Volume',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            Slider(
              value: speechSpeed,
              min: 0,
              max: 1,
              activeColor: Colors.white,
              onChanged: (v) {
                setState(() => speechSpeed = v);
                _savePrefs();
              },
            ),

            const SizedBox(height: 16),
            const Text(
              'Model',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButton<String>(
                value: selectedModel,
                isExpanded: true,
                underline: const SizedBox(),
                items: models.map((m) {
                  return DropdownMenuItem(value: m, child: Text(m));
                }).toList(),
                onChanged: (v) {
                  setState(() => selectedModel = v!);
                  _savePrefs();
                },
              ),
            ),

            const SizedBox(height: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ModelSettingsScreen(),
                  ),
                );
                _loadPrefs(); // refresh in case model changed
              },
              child: const Text('Model Settings'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchTile(String title, bool value, Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.black)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.black,
      contentPadding: EdgeInsets.zero,
    );
  }
}
