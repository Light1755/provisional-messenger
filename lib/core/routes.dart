import 'package:flutter/material.dart';

/// Soft fade + horizontal slide used throughout the app.
PageRouteBuilder<T> appPageRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, animation, secondaryAnimation) => page,
  transitionDuration: const Duration(milliseconds: 320),
  reverseTransitionDuration: const Duration(milliseconds: 240),
  transitionsBuilder: (_, animation, secondaryAnimation, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(.045, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  },
);
