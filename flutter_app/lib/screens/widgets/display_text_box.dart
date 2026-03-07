import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

class DisplayTextBox extends StatelessWidget {
  final ValueListenable<String> textListenable;
  final bool subtitleEnabled;

  const DisplayTextBox({
    super.key,
    required this.textListenable,
    required this.subtitleEnabled,
  });

  @override
  Widget build(BuildContext context) {
    if (!subtitleEnabled) return const SizedBox.shrink();

    return Positioned(
      bottom: 120,
      left: 20,
      right: 20,
      child: ValueListenableBuilder<String>(
        valueListenable: textListenable,
        builder: (context, text, child) {
          return Semantics(
            liveRegion: true,
            label: 'สถานะการมองเห็น',
            value: text,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24, width: 1.5),
              ),
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
      ),
    );
  }
}
