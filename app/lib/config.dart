/// Microsoft Azure AD app registration values.
///
/// These are filled in once after the user registers an app at
/// https://portal.azure.com → App registrations → New registration.
///
/// Required Azure AD setup:
///   1. Register a new application (Single tenant or "Personal Microsoft accounts").
///   2. Under Authentication → Add a platform → Mobile and desktop applications.
///      Tick the pre-listed `msal[clientid]://auth (MSAL only)` checkbox.
///   3. Under API permissions → Add a permission → Microsoft Graph → Delegated:
///        - Files.Read
///        - Mail.Send
///        - User.Read
///        - offline_access
///   4. Copy "Application (client) ID" into [azureClientId] below.
///
/// Until [azureClientId] is set to a real value, the OneDrive sign-in screen
/// will show a "Setup needed" message with these instructions.
class AzureConfig {
  static const String azureClientId = 'a2cebed4-8049-4aba-b454-2af36c3c0b82';

  static const String redirectUri = 'msala2cebed4-8049-4aba-b454-2af36c3c0b82://auth';

  // MUST use /consumers/ — Azure app is configured for "Personal Microsoft accounts only".
  // /common/ rejects requests for personal-only apps with AADSTS9002346.
  static const String authority = 'https://login.microsoftonline.com/consumers/v2.0';
  static const String authorizationEndpoint =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize';
  static const String tokenEndpoint =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
  static const String deviceCodeEndpoint =
      'https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode';

  // Mail.Send removed — we now use the device's email app (flutter_email_sender)
  // instead of Microsoft Graph sendMail. Personal Microsoft accounts that use
  // a Gmail address don't have an outlook.com mailbox, so Graph sendMail returns
  // 403. The device email approach works with any account, any provider.
  static const List<String> scopes = [
    'openid',
    'profile',
    'offline_access',
    'Files.Read',
    'User.Read',
  ];

  static bool get isConfigured =>
      azureClientId.isNotEmpty && azureClientId != 'PASTE_CLIENT_ID_HERE';
}
