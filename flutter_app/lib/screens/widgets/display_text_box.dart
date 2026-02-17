import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

class DisplayTextBox extends StatelessWidget {
  final ValueListenable<String> textListenable;
  final bool Function(String) isCritical;
  final bool subtitleEnabled;

  const DisplayTextBox({
    super.key,
    required this.textListenable,
    required this.isCritical,
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
          Color borderColor = Colors.white24;

          if (isCritical(text)) {
            borderColor = Colors.red;
          } else {
            final lower = text.toLowerCase();
            if (lower.contains('unclear') || lower.contains('difficult')) {
              borderColor = Colors.orange;
            }
          }

          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              // ignore: deprecated_member_use
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 2),
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
          );
        },
      ),
    );
  }
}
