import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/auth/supabase_auth_manager.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/models/user.dart';
import 'package:spendiq/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _authManager = SupabaseAuthManager();
  final _userService = UserService();
  User? _user;
  AppUser? _appUser;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _user = _authManager.currentUser;
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    if (_user != null) {
      final userData = await _userService.getCurrentUser();
      if (mounted) {
        setState(() {
          _appUser = userData;
          _isLoading = false;
        });
      }
    } else {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleSignOut() async {
    await _authManager.signOut();
    if (mounted) context.go(AppRoutes.landing);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.landing),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _user == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.account_circle_outlined, size: 80),
                  const SizedBox(height: 24),
                  const Text('Not signed in'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => context.go(AppRoutes.auth),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign In'),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Profile Card
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 50,
                                backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                                child: Icon(
                                  Icons.account_circle,
                                  size: 80,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _user?.email ?? 'No email',
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'User ID: ${_user?.id.substring(0, 8)}...',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Subscription Status
                      if (_appUser != null) ...[
                        Card(
                          color: _appUser!.hasActiveSubscription 
                              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                              : theme.colorScheme.surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(
                                  _appUser!.hasActiveSubscription ? Icons.workspace_premium : Icons.workspace_premium_outlined,
                                  color: _appUser!.hasActiveSubscription 
                                      ? theme.colorScheme.primary 
                                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                  size: 32,
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _appUser!.hasActiveSubscription ? 'Pro Subscription' : 'Free Plan',
                                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                      ),
                                      if (_appUser!.hasActiveSubscription && _appUser!.subscriptionExpiry != null)
                                        Text(
                                          'Expires: ${_appUser!.subscriptionExpiry!.toLocal().toString().split(' ')[0]}',
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                          ),
                                        ),
                                      if (!_appUser!.hasActiveSubscription)
                                        Text(
                                          'Upgrade to unlock all features',
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (!_appUser!.hasActiveSubscription)
                                  FilledButton(
                                    onPressed: () => context.go(AppRoutes.pricing),
                                    child: const Text('Upgrade'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],

                      // Account Settings
                      Text(
                        'Account Settings',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),

                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.email_outlined),
                              title: const Text('Email'),
                              subtitle: Text(_user?.email ?? 'Not set'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _showUpdateEmailDialog(),
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.lock_outline),
                              title: const Text('Change Password'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _showChangePasswordDialog(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Actions
                      FilledButton.icon(
                        onPressed: _handleSignOut,
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign Out'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _showDeleteAccountDialog(),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete Account'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  void _showUpdateEmailDialog() {
    final emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Email'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'New Email',
            hintText: 'Enter your new email address',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final email = emailController.text.trim();
              if (email.isNotEmpty && email.contains('@')) {
                _authManager.updateEmail(email: email, context: this.context);
                context.pop();
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change Password'),
        content: const Text('A password reset link will be sent to your email address.'),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (_user?.email != null) {
                _authManager.resetPassword(email: _user!.email!, context: this.context);
                context.pop();
              }
            },
            child: const Text('Send Reset Link'),
          ),
        ],
      ),
    );
  }

  void _showDeleteAccountDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text(
          'Are you sure you want to delete your account? This action cannot be undone. Please contact support to complete account deletion.',
        ),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _authManager.deleteUser(this.context);
              context.pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
