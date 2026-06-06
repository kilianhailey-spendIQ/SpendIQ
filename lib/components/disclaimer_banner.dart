import 'package:flutter/material.dart';
import 'package:spendiq/theme.dart';

/// A small, low-emphasis disclaimer shown at the bottom of screens.
class DisclaimerBanner extends StatelessWidget {
  final String text;
  const DisclaimerBanner({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
