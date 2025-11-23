import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ModelSettingsScreen extends StatefulWidget {
  const ModelSettingsScreen({super.key});

  @override
  State<ModelSettingsScreen> createState() => _ModelSettingsScreenState();
}

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  double temperature = 0.5;
  double maxTokens = 128;
  double freeGB = 1.5;
  double totalGB = 6.0;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      temperature = prefs.getDouble('temperature') ?? 0.5;
      maxTokens = prefs.getDouble('maxTokens') ?? 128;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('temperature', temperature);
    await prefs.setDouble('maxTokens', maxTokens);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.grey.shade100,
        elevation: 0,
        title: const Text(
          'Model Settings',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Temperature',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            Slider(
              value: temperature,
              min: 0,
              max: 1,
              divisions: 20,
              activeColor: Colors.white,
              label: temperature.toStringAsFixed(2),
              onChanged: (v) {
                setState(() => temperature = v);
                _savePrefs();
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Max Tokens',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            Slider(
              value: maxTokens,
              min: 32,
              max: 512,
              divisions: 16,
              activeColor: Colors.white,
              label: '${maxTokens.toInt()}',
              onChanged: (v) {
                setState(() => maxTokens = v);
                _savePrefs();
              },
            ),
            const Spacer(),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Free Memory : ${freeGB.toStringAsFixed(1)} GB of ${totalGB.toStringAsFixed(1)} GB',
                  style: const TextStyle(color: Colors.black),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
