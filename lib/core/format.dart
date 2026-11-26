import 'package:intl/intl.dart';

import 'server_clock.dart';

String formatDuration(int milliseconds) {
  final total = (milliseconds / 1000).round().clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatChatListTime(DateTime date) {
  final now = serverClock.now();
  final local = date.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return DateFormat.jm().format(local);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.E().format(local);
  return '${local.day}/${local.month}';
}

String formatMessageTime(DateTime date) =>
    DateFormat.jm().format(date.toLocal());

String formatDateHeader(DateTime date) {
  final now = serverClock.now();
  final local = date.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.EEEE().format(local);
  return DateFormat.yMMMd().format(local);
}

String dayKey(DateTime date) {
  final local = date.toLocal();
  return '${local.year}-${local.month}-${local.day}';
}

String formatRemaining(Duration duration) {
  if (duration.inSeconds <= 0) return 'Expired';
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  final seconds = duration.inSeconds % 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

String expiryLabel(int seconds) {
  switch (seconds) {
    case 3600:
      return '1 hour';
    case 21600:
      return '6 hours';
    case 86400:
      return '24 hours';
    case 259200:
      return '3 days';
    case 604800:
      return '7 days';
    default:
      if (seconds >= 86400) {
        final days = seconds ~/ 86400;
        return '$days ${days == 1 ? 'day' : 'days'}';
      }
      final hours = (seconds / 3600).ceil();
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
  }
}

String expiryShortLabel(int seconds) {
  if (seconds % 86400 == 0) return '${seconds ~/ 86400}d';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
  return '${(seconds / 60).ceil()}m';
}

String formatExpiryDate(DateTime date) {
  final local = date.toLocal();
  final now = serverClock.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return 'today at ${DateFormat.jm().format(local)}';
  }
  if (local.year == now.year) {
    return DateFormat('MMM d').add_jm().format(local);
  }
  return DateFormat.yMMMd().add_jm().format(local);
}

String initialsFor(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed[0].toUpperCase();
}

String extensionOf(String fileName) {
  final index = fileName.lastIndexOf('.');
  if (index < 0 || index == fileName.length - 1) return '';
  return fileName.substring(index + 1).toLowerCase();
}

String withoutExtension(String fileName) {
  final index = fileName.lastIndexOf('.');
  if (index <= 0) return fileName;
  return fileName.substring(0, index);
}

String humanFileType(String mime, String name) {
  if (mime.startsWith('image/')) return 'Photo';
  if (mime.startsWith('video/')) return 'Video';
  if (mime.startsWith('audio/')) return 'Audio';
  if (mime == 'application/pdf') return 'PDF';
  final ext = extensionOf(name);
  if (ext.isNotEmpty) return ext.toUpperCase();
  return 'File';
}
