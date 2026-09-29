/*
  小佳专属小屋：待办手机提醒有限重试
  attempts 记录实际推送尝试次数；next_retry_at 控制下一次允许执行的时间。
  超过 5 次推送失败后进入 failed，不再每分钟重复发送。
*/
alter table public.xj_todo_reminders
  add column if not exists next_retry_at timestamptz;

alter table public.xj_todo_reminders
  add column if not exists failed_at timestamptz;

alter table public.xj_todo_reminders
  add column if not exists failure_code text;

create index if not exists xj_todo_reminders_retry_idx
  on public.xj_todo_reminders(status, next_retry_at, remind_at, due_at);

update public.xj_todo_reminders
set status = 'failed',
    failed_at = coalesce(failed_at, now()),
    failure_code = coalesce(failure_code, 'retry_limit_reached'),
    next_retry_at = null,
    processing_at = null,
    updated_at = now()
where status in ('pending', 'sending')
  and attempts >= 5;
