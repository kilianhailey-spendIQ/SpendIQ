# Subscription Tracking Setup Guide

## ✅ Implementation Complete

All 4 steps for subscription tracking have been implemented:

### Step 1: User Model Updated ✓
- Added subscription fields to `AppUser` model:
  - `isPro`: Boolean flag for Pro status
  - `subscriptionExpiry`: When subscription expires
  - `stripeCustomerId`: Link to Stripe customer
  - `stripeSubscriptionId`: Link to Stripe subscription
- Added `hasActiveSubscription` helper method

### Step 2: Supabase Database Schema Created ✓
- Created `lib/supabase/supabase_tables.sql`:
  - Users table with foreign key to `auth.users`
  - Subscription tracking columns
  - Indexes for fast lookups
  - Auto-update timestamp trigger
- Created `lib/supabase/supabase_policies.sql`:
  - Row-Level Security enabled
  - Policies allow users to manage their own data

### Step 3: User Service Created ✓
- Created `lib/services/user_service.dart`:
  - `getCurrentUser()`: Fetch user subscription status
  - `updateSubscriptionStatus()`: Update after payment
  - `hasActiveSubscription()`: Check Pro status
  - `getUserByStripeCustomerId()`: For webhook lookups

### Step 4: Stripe Webhook Handler Created ✓
- Created Supabase Edge Function at `lib/supabase/functions/stripe-webhook/`:
  - Handles `checkout.session.completed` (new subscriptions)
  - Handles `customer.subscription.updated` (renewals)
  - Handles `customer.subscription.deleted` (cancellations)
  - Handles `invoice.payment_failed` (payment issues)
  - Automatically updates user Pro status in database

## 🚀 Deployment Steps

### 1. Apply Database Migrations
1. Open Supabase panel in left sidebar
2. Go to "Migrations" tab
3. Click "Apply Migrations" to create the users table

### 2. Deploy Stripe Webhook
1. Open Supabase panel in left sidebar
2. Go to "Edge Functions" tab
3. Find `stripe-webhook` function
4. Click "Deploy"
5. Set required secrets:
   - `STRIPE_SECRET_KEY`: Your Stripe secret key (sk_test_... or sk_live_...)
   - `STRIPE_WEBHOOK_SECRET`: Stripe webhook signing secret (whsec_...)

### 3. Configure Stripe Webhook in Stripe Dashboard
1. Go to Stripe Dashboard → Developers → Webhooks
2. Click "Add endpoint"
3. Endpoint URL: `https://pawyrcjodzfzupuyiybb.supabase.co/functions/v1/stripe-webhook`
4. Select events to listen to:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.payment_failed`
5. Copy the "Signing secret" (whsec_...) and add it to Edge Function secrets

### 4. Update Pricing Page Checkout Link
- The current checkout link in `lib/pages/pricing_page.dart` is:
  ```
  https://buy.stripe.com/aFadR36M8eCu0HU07UgUM00
  ```
- Make sure this Stripe Checkout Session is configured to:
  - Collect customer email
  - Create a subscription (not one-time payment)
  - Set to annual billing (\$19/year)

## 📱 How It Works

1. **User pays on Stripe Checkout**:
   - Customer email is collected
   - Stripe creates subscription

2. **Stripe sends webhook to your edge function**:
   - Webhook is verified with signing secret
   - Function finds user by email in database
   - Updates user's `is_pro`, `subscription_expiry`, and Stripe IDs

3. **App checks subscription status**:
   - Use `UserService().getCurrentUser()` to get user with subscription data
   - Check `user.hasActiveSubscription` to gate Pro features
   - Show "Unlock Pro" for locked features when `!isPro`

## 🔒 Security Notes

- Webhook verification prevents unauthorized updates
- RLS policies ensure users can only read/update their own data
- Stripe customer ID index speeds up webhook processing
- Service role key in edge function allows admin updates

## 💡 Next Steps

To gate Pro features in your app:

```dart
import 'package:spendiq/services/user_service.dart';

final userService = UserService();
final user = await userService.getCurrentUser();

if (user?.hasActiveSubscription ?? false) {
  // Show Pro features
} else {
  // Show "Unlock Pro" overlay or paywall
  context.push('/pricing');
}
```

## ✅ iOS Upload Bug Fixed

Changed all `FilePicker` calls from `FileType.custom` to `FileType.any` with post-pick validation:
- CSV upload validates `.csv` extension after pick
- TXT upload validates `.txt` extension after pick
- PDF upload validates `.pdf` extension after pick
- Shows SnackBar if `pickFiles()` returns null or wrong file type
- Fixes iOS file picker issues while maintaining type safety
