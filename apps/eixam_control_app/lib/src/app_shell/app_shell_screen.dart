import 'package:flutter/material.dart';

class AppShellScreen extends StatelessWidget {
  const AppShellScreen({
    super.key,
    required this.onOpenOperationalDemo,
    required this.onOpenTechnicalLab,
  });

  final VoidCallback onOpenOperationalDemo;
  final VoidCallback onOpenTechnicalLab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EIXAM Control Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _IntroCard(),
          const SizedBox(height: 16),
          _SurfaceCard(
            title: 'Operational Demo',
            subtitle:
                'High-level SDK validation for SOS, tracking, device summary, Death Man, contacts, and realtime status.',
            actionLabel: 'Open operational surface',
            onTap: onOpenOperationalDemo,
            accent: Colors.green,
            icon: Icons.dashboard_customize_outlined,
          ),
          const SizedBox(height: 16),
          _SurfaceCard(
            title: 'Technical Lab',
            subtitle:
                'Diagnostics, permissions, notifications, pairing, BLE runtime visibility, and technical actions through SDK APIs.',
            actionLabel: 'Open technical surface',
            onTap: onOpenTechnicalLab,
            accent: Colors.blue,
            icon: Icons.bluetooth_searching_outlined,
          ),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Thin host app shell',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              'The reference app is now a thin SDK host with two separate surfaces: operational validation and technical diagnostics.',
            ),
          ],
        ),
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
    required this.accent,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: accent.withValues(alpha: 0.12),
                    foregroundColor: accent,
                    child: Icon(icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(subtitle),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onTap,
                child: Text(actionLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
