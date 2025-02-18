{{={= =}=}}
import { initEmailSender } from "./core/index.js";
import { EmailSender } from "./core/types.js";

// TODO: We need to validate all the env variables
// For now, we are letting the runtime throw if they are not provided
{=# isSmtpProviderUsed =}
const emailProvider = { 
    type: "smtp",
    host: process.env.SMTP_HOST!,
    port: parseInt(process.env.SMTP_PORT!, 10),
    username: process.env.SMTP_USERNAME!,
    password: process.env.SMTP_PASSWORD!,
} as const;
{=/ isSmtpProviderUsed =}
{=# isSendGridProviderUsed =}
const emailProvider = {
  type: "sendgrid",
  apiKey: process.env.SENDGRID_API_KEY!,
} as const;
{=/ isSendGridProviderUsed =}
{=# isMailgunProviderUsed =}
const emailProvider = {
  type: "mailgun",
  apiKey: process.env.MAILGUN_API_KEY!,
  domain: process.env.MAILGUN_DOMAIN!,
  apiUrl: process.env.MAILGUN_API_URL!,
} as const;
{=/ isMailgunProviderUsed =}
{=# isDummyProviderUsed =}
const emailProvider = {
  type: "dummy",
} as const;
{=/ isDummyProviderUsed =}

// PUBLIC API
export const emailSender: EmailSender = initEmailSender(emailProvider);

// PUBLIC API
export type { Email, EmailFromField, EmailSender, SentMessageInfo } from "./core/types.js";
