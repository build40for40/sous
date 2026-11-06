import 'dart:convert';

/// The signed-in WorkOS user, as AuthKit returns it.
class AuthUser {
  const AuthUser({
    required this.id,
    this.email,
    this.firstName,
    this.lastName,
    this.profilePictureUrl,
  });

  factory AuthUser.fromJson(Map<String, Object?> json) => AuthUser(
    id: json['id'] as String,
    email: json['email'] as String?,
    firstName: json['first_name'] as String?,
    lastName: json['last_name'] as String?,
    profilePictureUrl: json['profile_picture_url'] as String?,
  );

  final String id;
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? profilePictureUrl;

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'first_name': firstName,
    'last_name': lastName,
    'profile_picture_url': profilePictureUrl,
  };
}

/// An AuthKit session: a short-lived access token (a JWT the brain verifies)
/// and a single-use refresh token.
class SessionTokens {
  SessionTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  }) : expiresAt = _expiry(accessToken);

  /// Reads the body of `POST /user_management/authenticate`.
  factory SessionTokens.fromAuthenticateResponse(Map<String, Object?> json) =>
      SessionTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        user: AuthUser.fromJson(json['user'] as Map<String, Object?>),
      );

  factory SessionTokens.fromJson(Map<String, Object?> json) => SessionTokens(
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    user: AuthUser.fromJson(json['user'] as Map<String, Object?>),
  );

  final String accessToken;
  final String refreshToken;
  final AuthUser user;

  /// From the access token's `exp` claim, or null if it can't be read.
  final DateTime? expiresAt;

  bool expiresWithin(Duration margin, DateTime now) =>
      expiresAt == null || !now.add(margin).isBefore(expiresAt!);

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'user': user.toJson(),
  };

  static DateTime? _expiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final exp = payload is Map ? payload['exp'] : null;
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        (exp * 1000).round(),
        isUtc: true,
      );
    } on FormatException {
      return null;
    }
  }
}
