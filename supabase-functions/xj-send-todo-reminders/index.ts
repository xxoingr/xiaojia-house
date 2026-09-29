import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import * as webpush from "jsr:@negrel/webpush";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import {
  MAX_ATTEMPTS,
  noDevicePlan,
  pushFailurePlan,
} from "./retry-policy.mjs";

const dbUrl = Deno.env.get("SUPABASE_DB_URL");
if (!dbUrl) throw new Error("SUPABASE_DB_URL is missing");
const sql = postgres(dbUrl, { max: 1 });
const APP_URL = "https://xxoingr.github.io/xiaojia-house-pages/";

async function secret(name: string): Promise<string> {
  const rows = await sql`select decrypted_secret from vault.decrypted_secrets where name = ${name} limit 1`;
  const value = rows[0]?.decrypted_secret;
  if (!value) throw new Error("Missing Vault secret: " + name);
  return String(value);
}

function dueText(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(value));
}

function reminderLeadText(minutesValue: unknown, legacyHoursValue: unknown): string {
  let minutes = Number(minutesValue);
  if (!Number.isInteger(minutes) || minutes <= 0) minutes = Number(legacyHoursValue) * 60;
  if (!Number.isInteger(minutes) || minutes <= 0) return "提前一段时间";
  if (minutes % (24 * 60) === 0) return "提前 " + (minutes / (24 * 60)) + " 天";
  if (minutes % 60 === 0) return "提前 " + (minutes / 60) + " 小时";
  return "提前 " + minutes + " 分钟";
}

async function pushErrorText(error: unknown): Promise<string> {
  if (!error || typeof error !== "object") return String(error || "unknown push error");
  const record = error as Record<string, unknown>;
  const parts = [String(record.name || error.constructor?.name || "push error")];
  if (record.response instanceof Response) {
    let responseBody = "";
    try { responseBody = await record.response.clone().text(); } catch { /* diagnostic only */ }
    parts.push("http=" + record.response.status + " " + record.response.statusText);
    if (responseBody) parts.push("body=" + responseBody);
  }
  for (const key of Object.getOwnPropertyNames(error)) {
    if (key === "stack" || key === "name") continue;
    const value = record[key];
    if (value === undefined || value === null || value === "") continue;
    try {
      parts.push(key + "=" + (typeof value === "string" ? value : JSON.stringify(value)));
    } catch {
      parts.push(key + "=" + String(value));
    }
  }
  return parts.join("; ").slice(0, 800);
}

async function markWaitingForDevice(id: string, message: string) {
  const plan = noDevicePlan();
  await sql`
    update public.xj_todo_reminders
    set status = ${plan.status},
        next_retry_at = now() + (${plan.delayMinutes} * interval '1 minute'),
        processing_at = null,
        last_error = ${message},
        failure_code = ${plan.failureCode},
        failed_at = null,
        updated_at = now()
    where id = ${id}::uuid
  `;
}

async function markPushFailure(id: string, message: string, attemptNumber: number) {
  const plan = pushFailurePlan(attemptNumber);
  if (plan.status === "failed") {
    await sql`
      update public.xj_todo_reminders
      set status = 'failed',
          attempts = ${attemptNumber},
          next_retry_at = null,
          processing_at = null,
          sent_at = null,
          failed_at = now(),
          failure_code = ${plan.failureCode},
          last_error = ${message},
          updated_at = now()
      where id = ${id}::uuid
    `;
    return plan;
  }

  await sql`
    update public.xj_todo_reminders
    set status = 'pending',
        attempts = ${attemptNumber},
        next_retry_at = now() + (${plan.delayMinutes} * interval '1 minute'),
        processing_at = null,
        sent_at = null,
        failed_at = null,
        failure_code = ${plan.failureCode},
        last_error = ${message},
        updated_at = now()
    where id = ${id}::uuid
  `;
  return plan;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  let cronToken: string;
  try {
    cronToken = await secret("xj_reminder_cron_token");
  } catch (error) {
    console.error(error);
    return Response.json({ ok: false, error: "scheduler secret unavailable" }, { status: 500 });
  }
  if (req.headers.get("x-xj-cron-token") !== cronToken) {
    return Response.json({ ok: false, error: "unauthorized" }, { status: 401 });
  }

  try {
    const vapid = JSON.parse(await secret("xj_vapid_private_jwk"));
    const vapidKeys = await webpush.importVapidKeys(vapid, { extractable: false });
    const appServer = await webpush.ApplicationServer.new({
      // 推送服务要求的联系方式；在 Supabase 函数环境变量里设置 XJ_VAPID_CONTACT
      contactInformation: Deno.env.get("XJ_VAPID_CONTACT") ?? "mailto:admin@example.com",
      vapidKeys,
    });

    const reminders = await sql`
      with picked as (
        select id
        from public.xj_todo_reminders
        where (
          (status = 'pending' and (next_retry_at is null or next_retry_at <= now()))
          or (status = 'sending' and processing_at < now() - interval '10 minutes')
        )
        and attempts < ${MAX_ATTEMPTS}
        and remind_at <= now()
        and due_at > now()
        order by remind_at asc
        limit 25
        for update skip locked
      )
      update public.xj_todo_reminders r
      set status = 'sending', processing_at = now(), updated_at = now()
      from picked
      where r.id = picked.id
      returning r.id, r.house_id, r.todo_id, r.todo_text, r.due_at,
                r.reminder_hours, r.reminder_minutes, r.attempts
    `;

    const result = {
      picked: reminders.length,
      sent: 0,
      retried: 0,
      waitingForDevice: 0,
      failed: 0,
      removedSubscriptions: 0,
      errors: 0,
      failureDetails: [] as string[],
    };

    for (const reminder of reminders) {
      const subscriptions = await sql`
        select id, endpoint, p256dh, auth
        from public.xj_push_subscriptions
        where house_id = ${reminder.house_id}::uuid
          and recipient_kind = 'xiaojia'
          and endpoint like 'https://web.push.apple.com/%'
      `;

      if (!subscriptions.length) {
        result.waitingForDevice++;
        await markWaitingForDevice(String(reminder.id), "小佳手机还没有开启通知");
        continue;
      }

      const safeText = String(reminder.todo_text || "待办事项").replace(/["\\]/g, " ").slice(0, 160);
      const leadText = reminderLeadText(reminder.reminder_minutes, reminder.reminder_hours);
      const body = "小佳，提醒你：" + safeText + "。约在 " + dueText(String(reminder.due_at))
        + "，这是" + leadText + "提醒。";
      const topic = "todo-" + String(reminder.id).replace(/-/g, "").slice(0, 24);
      const payload = JSON.stringify({
        title: "小佳专属小屋提醒",
        body,
        icon: APP_URL + "icons/icon-192.png",
        badge: APP_URL + "icons/icon-192.png",
        tag: topic,
        url: APP_URL + "?from=push",
      });

      let delivered = 0;
      let removedForReminder = 0;
      const failureMessages: string[] = [];
      for (const sub of subscriptions) {
        try {
          const subscriber = appServer.subscribe({
            endpoint: String(sub.endpoint),
            keys: { p256dh: String(sub.p256dh), auth: String(sub.auth) },
          });
          await subscriber.pushTextMessage(payload, {
            urgency: webpush.Urgency.High,
            ttl: 86400,
          });
          delivered++;
        } catch (error) {
          if (error && typeof error.isGone === "function" && error.isGone()) {
            await sql`delete from public.xj_push_subscriptions where id = ${sub.id}::uuid`;
            result.removedSubscriptions++;
            removedForReminder++;
          } else {
            result.errors++;
            const message = await pushErrorText(error);
            failureMessages.push(message);
            result.failureDetails.push(message);
            console.error("push failed", String(sub.endpoint), error);
          }
        }
      }

      const activeSubscriptions = subscriptions.length - removedForReminder;
      if (activeSubscriptions === 0) {
        result.waitingForDevice++;
        await markWaitingForDevice(String(reminder.id), "小佳手机的通知设备已失效，请重新开启通知");
      } else if (delivered === activeSubscriptions) {
        result.sent++;
        await sql`
          update public.xj_todo_reminders
          set status = 'sent', sent_at = now(), processing_at = null,
              next_retry_at = null, failed_at = null,
              failure_code = null, last_error = null, updated_at = now()
          where id = ${reminder.id}::uuid
        `;
      } else {
        const detail = failureMessages.join(" | ").slice(0, 800);
        const attemptNumber = Number(reminder.attempts || 0) + 1;
        const plan = await markPushFailure(
          String(reminder.id),
          detail || "手机通知发送失败",
          attemptNumber,
        );
        if (plan.status === "failed") {
          result.failed++;
          console.error("reminder reached retry limit", String(reminder.id), attemptNumber);
        } else {
          result.retried++;
          console.warn(
            "reminder delivery will retry",
            String(reminder.id),
            "attempt=" + attemptNumber,
            "delay_minutes=" + plan.delayMinutes,
          );
        }
      }
    }

    return Response.json({ ok: true, ...result });
  } catch (error) {
    console.error(error);
    return Response.json({ ok: false, error: String(error) }, { status: 500 });
  }
});
