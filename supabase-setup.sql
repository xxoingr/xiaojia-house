/*
  小佳专属小屋：Supabase 第一阶段数据库与私有照片桶

  用法：在 Supabase 项目的 SQL Editor 中一次性运行本文件。
  这份 SQL 只允许“已登录且属于同一小屋”的两个人访问数据。
  照片桶是私有的，网页通过短时签名地址显示照片，不使用公开图片地址。
*/

create extension if not exists pgcrypto;

create table if not exists public.xj_houses (
  id uuid primary key default gen_random_uuid(),
  name text not null default '小佳专属小屋',
  invite_code text not null unique default upper(encode(gen_random_bytes(4), 'hex')),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.xj_house_members (
  house_id uuid not null references public.xj_houses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null default '',
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (house_id, user_id)
);

create index if not exists xj_house_members_user_idx
  on public.xj_house_members(user_id);

create table if not exists public.xj_house_state (
  house_id uuid primary key references public.xj_houses(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_by uuid not null references auth.users(id) on delete cascade,
  updated_at timestamptz not null default now()
);

create table if not exists public.xj_photos (
  id uuid primary key default gen_random_uuid(),
  house_id uuid not null references public.xj_houses(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  record_kind text not null check (record_kind in ('meal', 'sport', 'diary', 'wall')),
  record_id text not null,
  storage_path text not null unique,
  original_name text not null default '',
  mime_type text not null default 'image/jpeg',
  byte_size bigint not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists xj_photos_house_created_idx
  on public.xj_photos(house_id, created_at desc);

/* 这个函数只用于 RLS 判断，使用者不能直接借它绕过权限。 */
create or replace function public.xj_is_house_member(p_house_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.xj_house_members m
    where m.house_id = p_house_id
      and m.user_id = (select auth.uid())
  );
$$;

revoke all on function public.xj_is_house_member(uuid) from public;
grant execute on function public.xj_is_house_member(uuid) to authenticated;

/* 第一个人创建小屋，第二个人用邀请码加入。 */
create or replace function public.xj_create_house(p_name text, p_display_name text default null)
returns table (house_id uuid, house_name text, invite_code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_house public.xj_houses;
  v_name text := coalesce(nullif(trim(p_name), ''), '小佳专属小屋');
  v_display text := coalesce(nullif(trim(p_display_name), ''), '我');
begin
  if v_user_id is null then
    raise exception '请先登录';
  end if;

  if exists (select 1 from public.xj_house_members where user_id = v_user_id) then
    raise exception '这个账号已经加入过小屋';
  end if;

  insert into public.xj_houses(name, created_by)
  values (v_name, v_user_id)
  returning * into v_house;

  insert into public.xj_house_members(house_id, user_id, display_name, role)
  values (v_house.id, v_user_id, v_display, 'owner');

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

create or replace function public.xj_join_house(p_invite_code text, p_display_name text default null)
returns table (house_id uuid, house_name text, invite_code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_house public.xj_houses;
  v_display text := coalesce(nullif(trim(p_display_name), ''), '小佳');
begin
  if v_user_id is null then
    raise exception '请先登录';
  end if;

  select * into v_house
  from public.xj_houses
  where upper(public.xj_houses.invite_code) = upper(trim(coalesce(p_invite_code, '')))
  limit 1;

  if not found then
    raise exception '邀请码不正确';
  end if;

  if exists (
    select 1 from public.xj_house_members m
    where m.user_id = v_user_id and m.house_id <> v_house.id
  ) then
    raise exception '这个账号已经加入了另一间小屋';
  end if;

  insert into public.xj_house_members(house_id, user_id, display_name, role)
  values (v_house.id, v_user_id, v_display, 'member')
  on conflict (house_id, user_id) do update
    set display_name = excluded.display_name;

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

revoke all on function public.xj_create_house(text, text) from public;
revoke all on function public.xj_join_house(text, text) from public;
grant execute on function public.xj_create_house(text, text) to authenticated;
grant execute on function public.xj_join_house(text, text) to authenticated;

/* 账号误建空小屋后的安全切换：只允许清理当前账号独占、没有数据和照片的空小屋。 */
create or replace function public.xj_switch_house(p_invite_code text, p_display_name text default null)
returns table (house_id uuid, house_name text, invite_code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_current_house_id uuid;
  v_house public.xj_houses;
  v_display text := coalesce(nullif(trim(p_display_name), ''), '小佳');
begin
  if v_user_id is null then
    raise exception '请先登录';
  end if;

  select * into v_house
  from public.xj_houses
  where upper(public.xj_houses.invite_code) = upper(trim(coalesce(p_invite_code, '')))
  limit 1;

  if not found then
    raise exception '邀请码不正确';
  end if;

  select m.house_id into v_current_house_id
  from public.xj_house_members m
  where m.user_id = v_user_id
  limit 1;

  if v_current_house_id is not null and v_current_house_id <> v_house.id then
    if exists (
      select 1 from public.xj_house_members m
      where m.house_id = v_current_house_id and m.user_id <> v_user_id
    ) then
      raise exception '当前小屋还有其他成员，不能直接切换';
    end if;
    if exists (select 1 from public.xj_house_state s where s.house_id = v_current_house_id) then
      raise exception '当前小屋已经有云端记录，请先备份或手动处理';
    end if;
    if exists (select 1 from public.xj_photos p where p.house_id = v_current_house_id) then
      raise exception '当前小屋已经有照片，请先备份或手动处理';
    end if;

    delete from public.xj_house_members m
    where m.house_id = v_current_house_id and m.user_id = v_user_id;
    delete from public.xj_houses
    where id = v_current_house_id
      and created_by = v_user_id
      and not exists (
        select 1 from public.xj_house_members m where m.house_id = v_current_house_id
      );
  end if;

  insert into public.xj_house_members(house_id, user_id, display_name, role)
  values (v_house.id, v_user_id, v_display, 'member')
  on conflict (house_id, user_id) do update
    set display_name = excluded.display_name;

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

revoke all on function public.xj_switch_house(text, text) from public;
grant execute on function public.xj_switch_house(text, text) to authenticated;

/* 数据库表权限 + RLS。浏览器里只会使用 publishable/anon key。 */
grant select on public.xj_houses, public.xj_house_members to authenticated;
grant select, insert, update, delete on public.xj_house_state, public.xj_photos to authenticated;

alter table public.xj_houses enable row level security;
alter table public.xj_house_members enable row level security;
alter table public.xj_house_state enable row level security;
alter table public.xj_photos enable row level security;

drop policy if exists xj_houses_select_member on public.xj_houses;
create policy xj_houses_select_member
  on public.xj_houses for select to authenticated
  using ((select public.xj_is_house_member(id)));

drop policy if exists xj_members_select_self on public.xj_house_members;
create policy xj_members_select_self
  on public.xj_house_members for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists xj_state_select_member on public.xj_house_state;
create policy xj_state_select_member
  on public.xj_house_state for select to authenticated
  using ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_state_insert_member on public.xj_house_state;
create policy xj_state_insert_member
  on public.xj_house_state for insert to authenticated
  with check (
    (select public.xj_is_house_member(house_id))
    and updated_by = (select auth.uid())
  );

drop policy if exists xj_state_update_member on public.xj_house_state;
create policy xj_state_update_member
  on public.xj_house_state for update to authenticated
  using ((select public.xj_is_house_member(house_id)))
  with check (
    (select public.xj_is_house_member(house_id))
    and updated_by = (select auth.uid())
  );

drop policy if exists xj_state_delete_member on public.xj_house_state;
create policy xj_state_delete_member
  on public.xj_house_state for delete to authenticated
  using ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_photos_select_member on public.xj_photos;
create policy xj_photos_select_member
  on public.xj_photos for select to authenticated
  using ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_photos_insert_member on public.xj_photos;
create policy xj_photos_insert_member
  on public.xj_photos for insert to authenticated
  with check (
    (select public.xj_is_house_member(house_id))
    and owner_id = (select auth.uid())
  );

drop policy if exists xj_photos_update_member on public.xj_photos;
create policy xj_photos_update_member
  on public.xj_photos for update to authenticated
  using ((select public.xj_is_house_member(house_id)))
  with check ((select public.xj_is_house_member(house_id)));

drop policy if exists xj_photos_delete_member on public.xj_photos;
create policy xj_photos_delete_member
  on public.xj_photos for delete to authenticated
  using ((select public.xj_is_house_member(house_id)));

/* 私有照片桶；若已经创建过同名桶，这句只会把它保持为私有。 */
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'xiaojia-photos',
  'xiaojia-photos',
  false,
  20971520,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']::text[]
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists xj_storage_select_member on storage.objects;
create policy xj_storage_select_member
  on storage.objects for select to authenticated
  using (
    bucket_id = 'xiaojia-photos'
    and (storage.foldername(name))[1] in (
      select house_id::text
      from public.xj_house_members
      where user_id = (select auth.uid())
    )
  );

drop policy if exists xj_storage_insert_member on storage.objects;
create policy xj_storage_insert_member
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'xiaojia-photos'
    and (storage.foldername(name))[1] in (
      select house_id::text
      from public.xj_house_members
      where user_id = (select auth.uid())
    )
  );

drop policy if exists xj_storage_update_member on storage.objects;
create policy xj_storage_update_member
  on storage.objects for update to authenticated
  using (
    bucket_id = 'xiaojia-photos'
    and (storage.foldername(name))[1] in (
      select house_id::text
      from public.xj_house_members
      where user_id = (select auth.uid())
    )
  )
  with check (
    bucket_id = 'xiaojia-photos'
    and (storage.foldername(name))[1] in (
      select house_id::text
      from public.xj_house_members
      where user_id = (select auth.uid())
    )
  );

drop policy if exists xj_storage_delete_member on storage.objects;
create policy xj_storage_delete_member
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'xiaojia-photos'
    and (storage.foldername(name))[1] in (
      select house_id::text
      from public.xj_house_members
      where user_id = (select auth.uid())
    )
  );

/* 给实时订阅用；已经加入过时不会重复报错。 */
do $$
begin
  alter publication supabase_realtime add table public.xj_house_state;
exception
  when duplicate_object then null;
end
$$;
