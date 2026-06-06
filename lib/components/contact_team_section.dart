import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spendiq/components/optimized_asset_image.dart';
import 'package:spendiq/theme.dart';

class ContactTeamSection extends StatefulWidget {
  final String imageAssetPath;
  const ContactTeamSection({super.key, required this.imageAssetPath});

  @override
  State<ContactTeamSection> createState() => _ContactTeamSectionState();
}

class _ContactTeamSectionState extends State<ContactTeamSection> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  String? _inquiryType;
  bool _agreed = false;
  bool _submitting = false;

  static const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://pawyrcjodzfzupuyiybb.supabase.co');
  static const String _supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBhd3lyY2pvZHpmenVwdXlpeWJiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMwMjQ1MjYsImV4cCI6MjA4ODYwMDUyNn0.jH7-Hd9cCM52Z0wjLqsVlUoYYskXJrLOObAhSKdOww8',
  );

  Uri _contactSubmitEndpoint() => Uri.parse('${_supabaseUrl.replaceAll(RegExp(r"/+\$"), "")}/functions/v1/contact_submit');

  Future<void> _submitToSupabase({
    required String name,
    required String email,
    required String inquiryType,
    required String message,
  }) async {
    if (_supabaseUrl.isEmpty || _supabaseAnonKey.isEmpty) {
      throw Exception('Supabase env not configured (SUPABASE_URL / SUPABASE_ANON_KEY).');
    }

    final res = await http
        .post(
          _contactSubmitEndpoint(),
          headers: {
            'content-type': 'application/json',
            'apikey': _supabaseAnonKey,
            'authorization': 'Bearer $_supabaseAnonKey',
          },
          body: jsonEncode({
            'name': name,
            'email': email,
            'inquiryType': inquiryType,
            'message': message,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('contact_submit failed: status=${res.statusCode} body=${utf8.decode(res.bodyBytes)}');
      throw Exception('Request failed (${res.statusCode})');
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) return;
    if (!_agreed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please agree to the privacy policy to continue.'),
      ));
      return;
    }

    setState(() => _submitting = true);
    try {
      debugPrint(
        'ContactTeamSection submit: name=${_nameCtrl.text.trim()} email=${_emailCtrl.text.trim()} inquiry=${_inquiryType ?? ''} messageLen=${_messageCtrl.text.trim().length}',
      );

      await _submitToSupabase(
        name: _nameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        inquiryType: (_inquiryType ?? 'General').trim(),
        message: _messageCtrl.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Thanks — your message was sent.'),
      ));

      _formKey.currentState?.reset();
      _nameCtrl.clear();
      _emailCtrl.clear();
      _messageCtrl.clear();
      setState(() {
        _inquiryType = null;
        _agreed = false;
      });
    } catch (e) {
      debugPrint('ContactTeamSection submit failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'We couldn\'t send your message right now. Please try again in a moment.',
        ),
      ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 860;

        final form = _ContactFormCard(
          formKey: _formKey,
          nameCtrl: _nameCtrl,
          emailCtrl: _emailCtrl,
          messageCtrl: _messageCtrl,
          inquiryType: _inquiryType,
          onInquiryChanged: (v) => setState(() => _inquiryType = v),
          agreed: _agreed,
          onAgreedChanged: (v) => setState(() => _agreed = v),
          submitting: _submitting,
          onSubmit: _submit,
        );

        final photo = _ContactPhoto(assetPath: widget.imageAssetPath);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Contact us',
              style: context.textStyles.headlineLarge.bold
                  .withColor(Colors.white)
                  .copyWith(height: 1.08),
            ),
            const SizedBox(height: 12),
            Text(
              'Need help? Contact us below and we’ll get back to you soon.',
              style: context.textStyles.bodyLarge
                  .withColor(Colors.white.withValues(alpha: 0.75)),
            ),
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: form),
                        const SizedBox(width: AppSpacing.lg),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: photo,
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        form,
                        const SizedBox(height: AppSpacing.lg),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                              border: Border.all(
                                color: cs.outline.withValues(alpha: 0.22),
                              ),
                            ),
                            child: photo,
                          ),
                        )
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ContactPhoto extends StatelessWidget {
  final String assetPath;
  const _ContactPhoto({required this.assetPath});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: OptimizedAssetImage(
        assetPath: assetPath,
        width: 360,
        height: 480,
        borderRadius: AppRadius.lg,
        fit: BoxFit.cover,
        fallback: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.25),
                Colors.black.withValues(alpha: 0.25),
              ],
            ),
          ),
          child: const Center(
            child: Icon(Icons.groups_2_rounded, color: Colors.white38, size: 42),
          ),
        ),
      ),
    );
  }
}

class _ContactFormCard extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController nameCtrl;
  final TextEditingController emailCtrl;
  final TextEditingController messageCtrl;
  final String? inquiryType;
  final ValueChanged<String?> onInquiryChanged;
  final bool agreed;
  final ValueChanged<bool> onAgreedChanged;
  final bool submitting;
  final VoidCallback onSubmit;

  const _ContactFormCard({
    required this.formKey,
    required this.nameCtrl,
    required this.emailCtrl,
    required this.messageCtrl,
    required this.inquiryType,
    required this.onInquiryChanged,
    required this.agreed,
    required this.onAgreedChanged,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    InputDecoration decoration(String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.9)),
          ),
          labelStyle:
              context.textStyles.labelLarge.withColor(Colors.white70),
          hintStyle:
              context.textStyles.bodyMedium.withColor(Colors.white30),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        );

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Need help? Contact us below',
            style: context.textStyles.titleMedium
                .semiBold
                .withColor(Colors.white),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextFormField(
            controller: nameCtrl,
            textInputAction: TextInputAction.next,
            style: context.textStyles.bodyLarge.withColor(Colors.white),
            decoration: decoration('Full name', hint: 'Your name'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Please enter your name.';
              if (v.trim().length < 2) return 'Name looks too short.';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: emailCtrl,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.emailAddress,
            style: context.textStyles.bodyLarge.withColor(Colors.white),
            decoration: decoration('Email address', hint: 'email@website.com'),
            validator: (v) {
              final value = (v ?? '').trim();
              if (value.isEmpty) return 'Please enter your email.';
              if (!value.contains('@') || !value.contains('.')) {
                return 'Please enter a valid email.';
              }
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String>(
            value: inquiryType,
            dropdownColor: Theme.of(context).colorScheme.surface,
            iconEnabledColor: Colors.white70,
            style: context.textStyles.bodyLarge.withColor(Colors.white),
            decoration: decoration('Inquiry type', hint: 'Select one...'),
            items: const [
              DropdownMenuItem(
                  value: 'Troubleshooting', child: Text('Troubleshooting')),
              DropdownMenuItem(value: 'Billing', child: Text('Billing')),
              DropdownMenuItem(value: 'Feature request', child: Text('Feature request')),
              DropdownMenuItem(value: 'Other', child: Text('Other')),
            ],
            onChanged: onInquiryChanged,
            validator: (v) => (v == null || v.isEmpty)
                ? 'Please choose an inquiry type.'
                : null,
          ),
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: messageCtrl,
            minLines: 4,
            maxLines: 7,
            keyboardType: TextInputType.multiline,
            style: context.textStyles.bodyLarge.withColor(Colors.white),
            decoration: decoration('How can we assist you?', hint: 'Type your message...'),
            validator: (v) {
              final value = (v ?? '').trim();
              if (value.isEmpty) return 'Please add a short message.';
              if (value.length < 10) return 'Please add a bit more detail.';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Checkbox(
                value: agreed,
                onChanged: submitting ? null : (v) => onAgreedChanged(v ?? false),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                activeColor: cs.primary,
                checkColor: cs.onPrimary,
              ),
              Expanded(
                child: Text(
                  'I agree to the privacy policy.',
                  style: context.textStyles.bodyMedium
                      .withColor(Colors.white.withValues(alpha: 0.78)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: submitting ? null : onSubmit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: submitting
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.onPrimary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.send_rounded, color: cs.onPrimary, size: 18),
                        const SizedBox(width: 8),
                        Text('Submit',
                            style: context.textStyles.labelLarge
                                .semiBold
                                .withColor(cs.onPrimary)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}
