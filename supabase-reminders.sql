+/*
  小佳专属小屋：小佳 iPhone 待办提醒
  只保存推送订阅和待办提醒时间；正文仍在 xj_house_state 里。
*/
create table if not exists public.xj_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  house_id uuid not null references public.xj_houses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  recipient_kind text not null default 'xiaojia'
    check (recipient_kind in ('xiaojia')),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists xj_push_subscriptions_house_idx
  on public.xj_push_subscriptions(house_id, recipient_kind);

create table if not exists public.xj_todo_reminders (
  id uuid primary key default gen_random_uuid(),
  house_id uuid not null references public.xj_houses(id) on delete cascade,
  todo_id text not null,
  todo_text text not null default '',
  due_at timestamptz not null,
  remind_at timestamptz not null,
  reminder_minutes integer not null
    check (reminder_minutes between 1 and 525600),
  reminder_hours smallint
    check (reminder_hours is null or reminder_hours in (30,48)),
  status text not null default 'pending'
    check (status in ('pending','sending','sent','cancelled','failed')),
  attempts integer not null default 0,
  processing_at timestamptz,
  sent_at timestamptz,
  last_error text,
  next_retry_at timestamptz,
  failed_at timestamptz,
  failure_code text,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (house_id, todo_id)
);

create index if not exists xj_todo_reminders_due_idx
  on public.xj_todo_reminders(status, next_retry_at, remind_at, due_at);

create index if not exists xj_todo_reminders_house_idx
  on public.xj_todo_reminders(house_id);

create index if not exists xj_todo_reminders_created_by_idx
  on public.xj_todo_reminders(created_by);

grant select, insert, update, delete on public.xj_push_subscriptions to authenticated;
grant select, insert, update, delete on public.xj_todo_reminders to authenticated;

alter table public.xj_push_subscriptions enable row level security;
alter table public.xj_todo_reminders enable row level security;

drop policy if exists xj_push_select_own on public.xj_push_subscriptions;
create policy xj_push_select_own
  on public.xj_push_subscriptions for select to authenticated
  using (user_id = (select auth.uid()) and (select public.xj_is_house_member(house_id)));

drop policy if exists xj_push_insert_own on public.xj_push_subscriptions;
create policy xj_push_insert_own
  on public.xj_push_subscriptions for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.xj_is_house_member(house_id)));

drop policy if exists xj_push_update_own on public.xj_push_subscriptions;
create policy xj_push_update_own
  on public.xj_push_subscriptions for update to authenticated
  using (user_id = (select auth.uid()) and (select public.xj_is_house_member(house_id)))
  with check (user_id = (select auth.uid()) and (select public.xj_is_house_member(house_id)));

drop policy if exists xj_push_delete_own on public.xj_push_subscriptions;
create policy xj_push_delete_own
  on public.xj_push_subscriptions for delete to authenticated
  using (user_id = (select auth.uid()) and (select public.xj_is_house_member(house_id)));

drop policy if exists xj_reminders_select_member on public.xj_todo_reminders;
create policy xj_reminders_select_member
  on public.xj_todo_reminders for select to authenticated
  using ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_reminders_insert_member on public.xj_todo_reminders;
create policy xj_reminders_insert_member
  on public.xj_todo_reminders for insert to authenticated
  with check ((select public.xj_is_house_member(house_id)) and created_by = (select auth.uid()));

drop policy if exists xj_reminders_update_member on public.xj_todo_reminders;
create policy xj_reminders_update_member
  on public.xj_todo_reminders for update to authenticated
  using ((select public.xj_is_house_member(house_id)))
  with check ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_reminders_delete_member on public.xj_todo_reminders;
create policy xj_reminders_delete_member
  on public.xj_todo_reminders for delete to authenticated
  using ((select public.xj_is_house_member(house_id)));
