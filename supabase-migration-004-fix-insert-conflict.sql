/*
  小佳专属小屋：修复切换/加入时 on conflict 列名歧义（迁移 004）
  原因：函数内变量 v_house（一整行小屋数据）也有 house_id 字段，
        insert ... on conflict (house_id, user_id) 里的列名被当成表达式解析，
        与变量撞名，报 column reference "house_id" is ambiguous。
  修复：on conflict 改用主键约束名 xj_house_members_pkey，不再写列名。
  说明：在 Supabase SQL Editor 中完整运行一次即可，安全覆盖旧函数，不碰数据。
*/
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
  on conflict on constraint xj_house_members_pkey do update
    set display_name = excluded.display_name;

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

revoke all on function public.xj_create_house(text, text) from public;
revoke all on function public.xj_join_house(text, text) from public;
grant execute on function public.xj_create_house(text, text) to authenticated;
grant execute on function public.xj_join_house(text, text) to authenticated;

create or replace function public.xj_switch_house(p_invite_code text, p_display_name text default null, p_drop_old boolean default false)
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
  v_other_members boolean;
  v_has_state boolean;
  v_has_photos boolean;
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
    select exists(
      select 1 from public.xj_house_members m
      where m.house_id = v_current_house_id and m.user_id <> v_user_id
    ) into v_other_members;
    select exists(select 1 from public.xj_house_state s where s.house_id = v_current_house_id) into v_has_state;
    select exists(select 1 from public.xj_photos p where p.house_id = v_current_house_id) into v_has_photos;

    if v_other_members then
      raise exception '当前小屋还有其他成员，不能切换';
    end if;

    if not p_drop_old and (v_has_state or v_has_photos) then
      raise exception '当前小屋已经有云端记录或照片，请先备份或手动处理';
    end if;

    -- 清理旧小屋（用户已在网页确认）：照片文件、照片记录、云端记录、成员、空小屋
    if v_has_photos then
      begin
        delete from storage.objects
        where bucket_id = 'xiaojia-photos'
          and (storage.foldername(name))[1] = v_current_house_id::text;
      exception when others then
        null; -- 文件删除失败不阻断切换
      end;
    end if;
    delete from public.xj_house_state s where s.house_id = v_current_house_id;
    delete from public.xj_photos p where p.house_id = v_current_house_id;
    delete from public.xj_house_members m where m.house_id = v_current_house_id and m.user_id = v_user_id;
    delete from public.xj_houses
    where id = v_current_house_id
      and created_by = v_user_id
      and not exists (
        select 1 from public.xj_house_members m where m.house_id = v_current_house_id
      );
  end if;

  insert into public.xj_house_members(house_id, user_id, display_name, role)
  values (v_house.id, v_user_id, v_display, 'member')
  on conflict on constraint xj_house_members_pkey do update
    set display_name = excluded.display_name;

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

revoke all on function public.xj_switch_house(text, text, boolean) from public;
grant execute on function public.xj_switch_house(text, text, boolean) to authenticated;
