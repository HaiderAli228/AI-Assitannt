import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';

class AssistantMessageWidget extends StatelessWidget {
  final String message;
  const AssistantMessageWidget({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.contains("```")) {
      // Split on code block markers.
      List<String> parts = message.split("```");
      List<Widget> widgets = [];
      for (int i = 0; i < parts.length; i++) {
        if (i % 2 == 0) {
          // Regular text.
          if (parts[i].trim().isNotEmpty) {
            widgets.add(Text(parts[i]));
          }
        } else {
          // Code block: assume Dart.
          widgets.add(Container(
            margin: EdgeInsets.symmetric(vertical: 8),
            padding: EdgeInsets.all(8),
            color: Colors.grey.shade200,
            child: HighlightView(
              parts[i],
              language: "dart",
              theme: githubTheme,
              padding: EdgeInsets.all(8),
              textStyle: TextStyle(fontFamily: 'Courier', fontSize: 14),
            ),
          ));
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      );
    } else {
      return Text(message);
    }
  }
}
