/*
  小佳专属小屋：小屋聊天（迁移 006）

  用途：
  - 新增聊天消息表 xj_messages：小屋成员之间发文字消息；
  - 实时：网页打开时，对方发的消息 1 秒内自动出现（Supabase Realtime）；
  - 注意：手机锁屏/后台时收不到推送，重新打开 App 才会看到新消息（浏览器限制）。

  在 Supabase SQL Editor 中完整运行一次即可。
*/

create table if not exists public.xj_messages (
  id uuid primary key default gen_random_uuid(),
  house_id uuid not null references public.xj_houses(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null default '',
  content text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists xj_messages_house_idx
  on public.xj_messages(house_id, created_at);

alter table public.xj_messages enable row level security;

drop policy if exists xj_messages_select_member on public.xj_messages;
create policy xj_messages_select_member
  on public.xj_messages for select to authenticated
  using ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_messages_insert_member on public.xj_messages;
create policy xj_messages_insert_member
  on public.xj_messages for insert to authenticated
  with check (
    (select public.xj_is_house_member(house_id))
    and sender_id = (select auth.uid())
  );

grant select, insert on public.xj_messages to authenticated;
