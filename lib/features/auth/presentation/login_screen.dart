import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../application/session_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Card(
                  elevation: 0,
                  color: context.colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(color: context.colors.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          context.strings.appName,
                          textAlign: TextAlign.center,
                          style: context.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 24),
                        UzPhoneField(
                          controller: _phoneController,
                          labelText: context.strings.phone,
                          validator: (value) =>
                              (value == null || value.trim().isEmpty)
                              ? context.strings.requiredField
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: context.strings.password,
                          ),
                          validator: (value) => (value == null || value.isEmpty)
                              ? context.strings.requiredField
                              : null,
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        if (session.errorText != null) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            session.errorText!,
                            style: TextStyle(color: context.colors.error),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _submitting ? null : _submit,
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(context.strings.login),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final phone = UzPhoneField.toE164(_phoneController.text);
    final password = _passwordController.text;

    ref.read(sessionControllerProvider).clearError();
    setState(() => _submitting = true);
    try {
      await ref
          .read(sessionControllerProvider)
          .login(phone: phone, password: password);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}
