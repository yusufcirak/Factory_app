import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/station_auth.dart';

/// Tablet henüz istasyon olarak tanınmıyor: kodu göster, panelden onay bekle.
class EnrollmentPage extends StatelessWidget {
  const EnrollmentPage({super.key});

  @override
  Widget build(BuildContext context) {
    final a = context.watch<StationAuth>();
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget body;
    switch (a.state) {
      case StationState.loading:
      case StationState.ready:
        body = const CircularProgressIndicator();
      case StationState.enrolling:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text('This tablet needs approval', style: t.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('In the Device Service admin panel, find this code under "Pending requests" and approve it.',
              textAlign: TextAlign.center),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SelectableText(
              a.code ?? '',
              style: t.displayMedium?.copyWith(
                  fontFamily: 'monospace', fontWeight: FontWeight.bold, letterSpacing: 4, color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(height: 12),
          Text(a.deviceName ?? '', style: t.bodyMedium),
          const SizedBox(height: 32),
          const Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Waiting for approval...'),
          ]),
          if (a.expiresAt != null) ...[
            const SizedBox(height: 8),
            Text('Code valid until ${TimeOfDay.fromDateTime(a.expiresAt!.toLocal()).format(context)}',
                style: t.bodySmall),
          ],
        ]);
      case StationState.rejected:
      case StationState.expired:
      case StationState.error:
        final msg = switch (a.state) {
          StationState.rejected => 'The request was rejected in the panel.',
          StationState.expired => 'The code has expired.',
          _ => a.error ?? 'Something went wrong.',
        };
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(a.state == StationState.rejected ? Icons.block : Icons.error_outline, size: 56, color: scheme.error),
          const SizedBox(height: 16),
          Text(msg, style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: a.startEnrollment,
            icon: const Icon(Icons.refresh),
            label: const Text('Get a new code'),
          ),
        ]);
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/images/app_icon.jpg', height: 72),
              ),
              const SizedBox(height: 12),
              Text('Zemits Control', style: t.headlineSmall),
              const SizedBox(height: 40),
              body,
            ]),
          ),
        ),
      ),
    );
  }
}
