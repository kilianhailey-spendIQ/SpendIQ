import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.9.0?target=deno";

const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-max-age": "86400",
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    const stripeWebhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");

    if (!stripeSecretKey || !stripeWebhookSecret) {
      throw new Error("Missing Stripe configuration");
    }

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2023-10-16",
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Verify webhook signature
    const signature = req.headers.get("stripe-signature");
    if (!signature) {
      return new Response(
        JSON.stringify({ error: "No signature provided" }),
        { status: 400, headers: { ...CORS_HEADERS, "content-type": "application/json" } }
      );
    }

    const body = await req.text();
    let event: Stripe.Event;

    try {
      event = stripe.webhooks.constructEvent(body, signature, stripeWebhookSecret);
    } catch (err) {
      console.error("Webhook signature verification failed:", err);
      return new Response(
        JSON.stringify({ error: "Invalid signature" }),
        { status: 400, headers: { ...CORS_HEADERS, "content-type": "application/json" } }
      );
    }

    console.log("Processing webhook event:", event.type);

    // Handle the event
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutCompleted(session);
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(subscription);
        break;
      }

      case "customer.subscription.deleted": {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionCanceled(subscription);
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        await handlePaymentFailed(invoice);
        break;
      }

      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    return new Response(
      JSON.stringify({ received: true }),
      { headers: { ...CORS_HEADERS, "content-type": "application/json" } }
    );
  } catch (error) {
    console.error("Webhook error:", error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...CORS_HEADERS, "content-type": "application/json" } }
    );
  }
});

async function handleCheckoutCompleted(session: Stripe.Checkout.Session) {
  console.log("Checkout completed for customer:", session.customer);

  // Get customer email from session
  const customerEmail = session.customer_email || session.customer_details?.email;
  
  if (!customerEmail) {
    console.error("No customer email in checkout session");
    return;
  }

  // Import Supabase client
  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2.39.0");
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  // Find user by email
  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("id")
    .eq("email", customerEmail)
    .maybeSingle();

  if (userError || !userData) {
    console.error("User not found for email:", customerEmail, userError);
    return;
  }

  // Calculate subscription expiry (1 year from now for annual plan)
  const subscriptionExpiry = new Date();
  subscriptionExpiry.setFullYear(subscriptionExpiry.getFullYear() + 1);

  // Update user subscription status
  const { error: updateError } = await supabase
    .from("users")
    .update({
      is_pro: true,
      subscription_expiry: subscriptionExpiry.toISOString(),
      stripe_customer_id: session.customer as string,
      stripe_subscription_id: session.subscription as string,
      updated_at: new Date().toISOString(),
    })
    .eq("id", userData.id);

  if (updateError) {
    console.error("Error updating user subscription:", updateError);
    return;
  }

  console.log("User subscription activated:", userData.id);
}

async function handleSubscriptionUpdate(subscription: Stripe.Subscription) {
  console.log("Subscription updated:", subscription.id);

  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2.39.0");
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  // Find user by Stripe customer ID
  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("id")
    .eq("stripe_customer_id", subscription.customer as string)
    .maybeSingle();

  if (userError || !userData) {
    console.error("User not found for customer:", subscription.customer);
    return;
  }

  // Update subscription expiry based on current period end
  const subscriptionExpiry = new Date(subscription.current_period_end * 1000);
  const isActive = subscription.status === "active" || subscription.status === "trialing";

  const { error: updateError } = await supabase
    .from("users")
    .update({
      is_pro: isActive,
      subscription_expiry: subscriptionExpiry.toISOString(),
      stripe_subscription_id: subscription.id,
      updated_at: new Date().toISOString(),
    })
    .eq("id", userData.id);

  if (updateError) {
    console.error("Error updating subscription:", updateError);
    return;
  }

  console.log("Subscription updated for user:", userData.id);
}

async function handleSubscriptionCanceled(subscription: Stripe.Subscription) {
  console.log("Subscription canceled:", subscription.id);

  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2.39.0");
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  const { data: userData, error: userError } = await supabase
    .from("users")
    .select("id")
    .eq("stripe_customer_id", subscription.customer as string)
    .maybeSingle();

  if (userError || !userData) {
    console.error("User not found for customer:", subscription.customer);
    return;
  }

  // Set subscription as inactive but keep expiry date
  const { error: updateError } = await supabase
    .from("users")
    .update({
      is_pro: false,
      updated_at: new Date().toISOString(),
    })
    .eq("id", userData.id);

  if (updateError) {
    console.error("Error canceling subscription:", updateError);
    return;
  }

  console.log("Subscription canceled for user:", userData.id);
}

async function handlePaymentFailed(invoice: Stripe.Invoice) {
  console.log("Payment failed for invoice:", invoice.id);
  
  // You could send an email notification here or update user status
  // For now, just log it
  console.log("Customer:", invoice.customer);
  console.log("Amount due:", invoice.amount_due);
}
