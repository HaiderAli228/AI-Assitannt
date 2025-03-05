import 'package:aicodeassistant/utils/assistant_message.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../model/language.dart';
import 'model/conversion_item.dart';

enum OutputFormat { textOnly, audioOnly, both }

class VoiceAssistantPage extends StatefulWidget {
  const VoiceAssistantPage({super.key});

  @override
  _VoiceAssistantPageState createState() => _VoiceAssistantPageState();
}

class _VoiceAssistantPageState extends State<VoiceAssistantPage> {
  late stt.SpeechToText _speech;
  bool _speechEnabled = false;
  String _transcribedText = "";
  final FlutterTts _flutterTts = FlutterTts();
  double _soundLevel = 0.0; // onSoundLevelChange not supported.

  // Conversation history.
  List<ConversationItem> _conversationHistory = [];

  // Latest assistant response.
  String? _latestAssistantResponse;

  // Supported languages.
  final List<Language> _supportedLanguages = [
    Language(name: "Urdu", code: "ur"),
    Language(name: "Hindi", code: "hi"),
    Language(name: "Punjabi", code: "pa"),
    Language(name: "Turkish", code: "tr"),
  ];
  Language? _selectedLanguage;

  // Output format.
  OutputFormat _outputFormat = OutputFormat.both;

  // Rate limiting: last API call timestamp.
  DateTime? _lastApiCall;
  final int _rateLimitSeconds = 5;

  // Controller for manual text input.
  final TextEditingController _textController = TextEditingController();

  // Indicates if audio is currently loading/playing.
  bool _isAudioLoading = false;

  @override
  void initState() {
    super.initState();
    print("Initializing permissions and speech engine.");
    _initPermissions();
    _initSpeech();
    _selectedLanguage = _supportedLanguages[0]; // Default language.
  }

  /// Request microphone permission.
  Future<void> _initPermissions() async {
    print("Requesting microphone permission.");
    await Permission.microphone.request();
  }

  /// Initialize the speech recognition engine.
  void _initSpeech() async {
    _speech = stt.SpeechToText();
    print("Initializing speech engine.");
    _speechEnabled = await _speech.initialize(
      onStatus: (status) => print("Speech Status: $status"),
      onError: (error) => print("Speech Error: $error"),
    );
    setState(() {});
    print("Speech engine initialized: $_speechEnabled");
  }

  /// Start listening and transcribe speech.
  void _startListening() async {
    print("Starting listening.");
    await _speech.listen(
      onResult: (result) {
        setState(() {
          _transcribedText = result.recognizedWords;
        });
        print("Transcribed text updated: $_transcribedText");
      },
      localeId: _selectedLanguage?.code,
      listenMode: stt.ListenMode.confirmation,
    );
    setState(() {});
  }

  /// Stop listening and process captured text.
  void _stopListening() async {
    print("Stopping listening.");
    await _speech.stop();
    setState(() {});
    if (_transcribedText.isNotEmpty) {
      print("User input captured (from mic): $_transcribedText");
      _addToConversation("User", _transcribedText);
      _textController.text = _transcribedText;
      _processInput(_transcribedText);
      _transcribedText = "";
    } else {
      print("No transcribed text available.");
    }
  }

  /// Called when user manually submits text.
  void _handleSubmitted(String value) {
    String inputText = value.trim();
    if (inputText.isNotEmpty) {
      print("Manual input submitted: $inputText");
      _addToConversation("User", inputText);
      _processInput(inputText);
      _textController.clear();
    }
  }

  /// Add a message to the conversation history.
  void _addToConversation(String sender, String message) {
    print("Adding message from $sender: $message");
    setState(() {
      _conversationHistory.add(ConversationItem(sender: sender, message: message));
    });
  }

  /// Process the input: translate, call Gemini API, translate back, and display native text.
  Future<void> _processInput(String inputText) async {
    print("Starting _processInput with input: $inputText");

    // Rate limiting check.
    DateTime now = DateTime.now();
    if (_lastApiCall != null && now.difference(_lastApiCall!).inSeconds < _rateLimitSeconds) {
      _showError("Rate limit exceeded. Please wait a few seconds before trying again.");
      print("Rate limit exceeded. Skipping API call.");
      return;
    }
    _lastApiCall = now;
    print("Rate limit check passed.");

    // Translate native text to English.
    print("Translating native text to English.");
    String englishText = await _translateText(
      inputText,
      from: _selectedLanguage!.code,
      to: "en",
    );
    print("Translation to English successful: $englishText");

    // Call Gemini API.
    String geminiResponse = "";
    try {
      print("Calling Gemini API with prompt.");
      geminiResponse = await _callGemini(englishText);
      print("Received Gemini response: $geminiResponse");
    } catch (e) {
      print("Error during Gemini API call: $e");
      _addToConversation("Assistant", "Error: $e");
      _latestAssistantResponse = "Error: $e";
      _showError("Gemini API error: $e");
      return;
    }

    // Translate Gemini response back to native language.
    print("Translating Gemini response back to native language.");
    String translatedResponse = await _translateText(
      geminiResponse,
      from: "en",
      to: _selectedLanguage!.code,
    );
    print("Translation back to native language successful: $translatedResponse");

    // Display native text.
    _addToConversation("Assistant", translatedResponse);
    setState(() {
      _latestAssistantResponse = translatedResponse;
    });
  }

  /// Translate text using the Google Translate endpoint.
  Future<String> _translateText(String text, {required String from, required String to}) async {
    print("Starting translation from $from to $to for text: $text");
    if (from == to) {
      print("Source and target language are the same. Skipping translation.");
      return text;
    }
    final encodedText = Uri.encodeComponent(text);
    final url = Uri.parse(
        "https://translate.googleapis.com/translate_a/single?client=gtx&sl=$from&tl=$to&dt=t&q=$encodedText");

    try {
      final http.Response response = await http.get(url);
      if (response.statusCode == 200) {
        final List<dynamic> jsonResponse = json.decode(response.body);
        // Join all segments into one complete string.
        String translatedText = (jsonResponse[0] as List)
            .map((seg) => seg[0])
            .join(" ");
        print("Translation API successful: $translatedText");
        return translatedText;
      } else {
        print("Translation API error: ${response.body}");
        throw Exception("Translation API error: ${response.body}");
      }
    } catch (e) {
      print("Translation failed with error: $e");
      throw Exception("Translation failed: $e");
    }
  }

  /// Call Gemini API using the Gemini endpoint.
  Future<String> _callGemini(String prompt) async {
    // Replace with your actual Gemini API key.
    const String geminiApiKey = 'AIzaSyCi6SzKDvBeLZP-esQAQuqIuXxhIcuhrmU';
    final Uri url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey'
    );

    final Map<String, dynamic> payload = {
      "contents": [
        {
          "parts": [
            {
              "text":
              "Explain in detail with points, history, advantages, disadvantages and real world examples of $prompt"
            }
          ]
        }
      ]
    };

    try {
      final http.Response response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // Join all parts of the response into one string.
        final List<dynamic> parts = data["candidates"][0]["content"]["parts"];
        String resultText = parts.map((part) => part["text"]).join("\n");
        print("Gemini API call successful. Reply: $resultText");
        return resultText;
      } else {
        print("Gemini API error: ${response.body}");
        throw Exception("Gemini API error: ${response.body}");
      }
    } catch (e) {
      print("Gemini API call failed with error: $e");
      throw Exception("Gemini API call failed: $e");
    }
  }

  /// Convert text to speech.
  Future _speakText(String text, String languageCode) async {
    print("Converting text to speech for language: $languageCode with text: $text");
    try {
      await _flutterTts.setLanguage(languageCode);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(1.3);
      await _flutterTts.awaitSpeakCompletion(true);
      await _flutterTts.speak(text);
      print("Text-to-speech completed.");
    } catch (e) {
      print("TTS error: $e");
      _showError("TTS error: $e");
    }
  }

  /// Play the native response audio when user taps the button.
  Future<void> _playNativeAudio() async {
    if (_latestAssistantResponse != null && !_isAudioLoading) {
      setState(() {
        _isAudioLoading = true;
      });
      try {
        // Clean the native response text by removing markdown symbols and replacing newlines.
        String cleanText = _latestAssistantResponse!
            .replaceAll(RegExp(r'[*_#`]'), '')
            .replaceAll('\n', '. ');
        await _flutterTts.setLanguage(_selectedLanguage!.code);
        await _flutterTts.setPitch(1.0);
        await _flutterTts.setSpeechRate(1.3);
        await _flutterTts.awaitSpeakCompletion(true);
        await _flutterTts.speak(cleanText);
      } catch (e) {
        _showError("TTS error: $e");
      }
      setState(() {
        _isAudioLoading = false;
      });
    }
  }

  /// Display an error message.
  void _showError(String errorMessage) {
    print("Error: $errorMessage");
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(errorMessage)));
  }

  /// Allow editing of an assistant response.
  void _editResponse(int index) {
    ConversationItem item = _conversationHistory[index];
    TextEditingController controller = TextEditingController(text: item.message);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Edit Response"),
          content: TextField(
            controller: controller,
            maxLines: null,
            decoration: InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _conversationHistory[index] =
                      ConversationItem(sender: "Assistant", message: controller.text);
                });
                print("Assistant response edited: ${controller.text}");
                Navigator.of(context).pop();
              },
              child: Text("Save"),
            ),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text("Cancel")
            ),
          ],
        );
      },
    );
  }

  /// Build the responsive UI.
  @override
  Widget build(BuildContext context) {
    bool isWide = MediaQuery.of(context).size.width > 600;
    return Scaffold(
      appBar: AppBar(title: Text("Multilingual Voice Assistant")),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isWide ? 800 : double.infinity),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Manual text input field.
                TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: "Enter code or text manually",
                  ),
                  onSubmitted: _handleSubmitted,
                ),
                SizedBox(height: 20),
                // Audio level display.
                Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.blue.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    "Audio Level: ${_soundLevel.toStringAsFixed(2)}\n(Note: updating audio level is not supported in this version)",
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(height: 20),
                // Conversation history.
                Text("Conversation History:",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(height: 10),
                Container(
                  height: 300,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _conversationHistory.length,
                    itemBuilder: (context, index) {
                      ConversationItem item = _conversationHistory[index];
                      return ListTile(
                        title: item.sender == "Assistant"
                            ? GestureDetector(
                          onLongPress: () => _editResponse(index),
                          child: AssistantMessageWidget(message: item.message),
                        )
                            : Text(item.message),
                      );
                    },
                  ),
                ),
                SizedBox(height: 20),
                // Dedicated area for latest assistant response.
                if (_latestAssistantResponse != null)
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      border: Border.all(color: Colors.green),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      "Assistant Response:\n\n$_latestAssistantResponse",
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                SizedBox(height: 20),
                // Play Audio button for native response.
                if (_latestAssistantResponse != null)
                  ElevatedButton.icon(
                    onPressed: _isAudioLoading ? null : _playNativeAudio,
                    icon: _isAudioLoading
                        ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                        : Icon(Icons.play_arrow),
                    label: Text(_isAudioLoading ? "Playing Audio..." : "Play Audio"),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: TextStyle(fontSize: 18),
                    ),
                  ),
                SizedBox(height: 20),
                // Microphone button.
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _speech.isListening ? _stopListening : _startListening,
                    icon: Icon(_speech.isListening ? Icons.stop : Icons.mic),
                    label: Text(_speech.isListening ? "Stop Listening" : "Start Listening"),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Text(
                  "Status: ${_speech.isListening ? 'Listening...' : 'Not listening'}",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
