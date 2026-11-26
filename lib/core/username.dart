const reservedUsernames = <String>{
  'admin',
  'administrator',
  'support',
  'system',
  'provisional',
  'moderator',
  'mod',
  'help',
  'everyone',
  'here',
};

final _usernamePattern = RegExp(r'^[a-z0-9_]{3,24}$');

String normalizeUsername(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');

bool usernameLooksValid(String value) =>
    _usernamePattern.hasMatch(value) && !reservedUsernames.contains(value);

String? usernameError(String value) {
  if (value.isEmpty) return null;
  if (value.length < 3) return 'Use at least 3 characters.';
  if (value.length > 24) return 'Use 24 characters or fewer.';
  if (!_usernamePattern.hasMatch(value)) {
    return 'Use lowercase letters, numbers, or underscore.';
  }
  if (reservedUsernames.contains(value)) {
    return 'That username is reserved. Choose another.';
  }
  return null;
}
