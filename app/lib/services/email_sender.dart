import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import 'onedrive_auth.dart';

class EmailAttachment {
  final String filename;
  final Uint8List bytes;
  final String contentType;

  const EmailAttachment({
    required this.filename,
    required this.bytes,
    this.contentType = 'image/jpeg',
  });
}

class GraphEmailSender {
  static const _sendMailUrl = 'https://graph.microsoft.com/v1.0/me/sendMail';

  final OneDriveAuth auth;
  GraphEmailSender(this.auth);

  Future<void> send({
    required String to,
    required String subject,
    required String bodyText,
    required List<EmailAttachment> attachments,
  }) async {
    final token = await auth.getAccessToken();
    final payload = {
      'message': {
        'subject': subject,
        'body': {'contentType': 'Text', 'content': bodyText},
        'toRecipients': [
          {
            'emailAddress': {'address': to},
          }
        ],
        'attachments': attachments
            .map((a) => {
                  '@odata.type': '#microsoft.graph.fileAttachment',
                  'name': a.filename,
                  'contentType': a.contentType,
                  'contentBytes': base64Encode(a.bytes),
                })
            .toList(),
      },
      'saveToSentItems': true,
    };

    final res = await http.post(
      Uri.parse(_sendMailUrl),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Email send failed (HTTP ${res.statusCode}): ${res.body}');
    }
  }
}
