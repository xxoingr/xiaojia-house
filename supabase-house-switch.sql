/*
  小佳专属小屋：误建小屋后的安全切换补丁

  用途：
  - 小佳误点“创建新小屋”后，可以输入你原来小屋的邀请码切换过去。
  - 只有当前小屋只有她一个成员、没有云端记录、没有照片时，才会自动清理当前空小屋。
  - 如果当前小屋里已经有数据，函数会拒绝操作，避免误删。

  在 Supabase SQL Editor 中完整运行一次即可。
*/

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
