// supabase edge function: contact_submit
// Receives contact form submissions, stores them in Postgres, and sends email notifications.

const CORS_HEADERS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-max-age": "86400",
};

const SUPPORT_EMAIL = "Support@SpendIQCards.com";

type ContactPayload = {
  name: string;
  email: string;
  inquiryType: string;
  message: string;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json; charset=utf-8" },
  });
}

async function sendEmailNotification(
  name: string,
  email: string,
  inquiryType: string,
  message: string
) {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  
  if (!resendApiKey) {
    console.error("RESEND_API_KEY not configured");
    return { error: "Email service not configured" };
  }

  const emailHtml = `
    <h2>New Contact Form Submission</h2>
    <p><strong>Name:</strong> ${name}</p>
    <p><strong>Email:</strong> ${email}</p>
    <p><strong>Inquiry Type:</strong> ${inquiryType}</p>
    <p><strong>Message:</strong></p>
    <p>${message.replace(/\n/g, '<br>')}</p>
    <hr>
    <p style="color: #666; font-size: 12px;">This email was sent from the SpendIQ contact form.</p>
  `;

  const emailText = `
New Contact Form Submission

Name: ${name}
Email: ${email}
Inquiry Type: ${inquiryType}

Message:
${message}

---
This email was sent from the SpendIQ contact form.
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "SpendIQ Contact Form <noreply@spendiqcards.com>",
        to: [SUPPORT_EMAIL],
        reply_to: email,
        subject: `SpendIQ Contact: ${inquiryType} - ${name}`,
        html: emailHtml,
        text: emailText,
      }),
    });

    if (!res.ok) {
      const errorText = await res.text();
      console.error("Resend API error:", errorText);
      return { error: `Email sending failed: ${res.status}` };
    }

    return { ok: true };
  } catch (e) {
    console.error("Failed to send email:", e);
    return { error: `Email error: ${e}` };
  }
}

Deno.serve(async (req) => {
  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
    if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

    const contentType = req.headers.get("content-type") ?? "";
    if (!contentType.toLowerCase().includes("application/json")) {
      return jsonResponse({ error: "Expected application/json" }, 400);
    }

    const payload = (await req.json()) as Partial<ContactPayload>;
    const name = (payload.name ?? "").trim();
    const email = (payload.email ?? "").trim();
    const inquiryType = (payload.inquiryType ?? "General").trim();
    const message = (payload.message ?? "").trim();

    if (name.length < 2) return jsonResponse({ error: "Name too short" }, 400);
    if (!email.includes("@") || !email.includes(".")) return jsonResponse({ error: "Invalid email" }, 400);
    if (message.length < 10) return jsonResponse({ error: "Message too short" }, 400);

    const { createClient } = await import("npm:@supabase/supabase-js@2");

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Server not configured" }, 500);
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    });

    const userAgent = req.headers.get("user-agent") ?? null;
    const origin = req.headers.get("origin") ?? null;

    // Store in database
    const { error: dbError } = await supabase.from("contact_submissions").insert({
      name,
      email,
      inquiry_type: inquiryType,
      message,
      user_agent: userAgent,
      origin,
    });

    if (dbError) return jsonResponse({ error: dbError.message }, 500);

    // Send email notification
    const emailResult = await sendEmailNotification(name, email, inquiryType, message);
    
    if (emailResult.error) {
      console.error("Email notification failed:", emailResult.error);
      // Don't fail the request if email fails - the submission was stored successfully
    }

    return jsonResponse({ ok: true });
  } catch (e) {
    return jsonResponse({ error: `${e}` }, 500);
  }
});
