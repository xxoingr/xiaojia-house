/*
  小佳专属小屋：切换并加入时自动清理旧小屋（迁移 003）

  新逻辑：
  当用户已经有自己的小屋，再输入别人的邀请码切换时：
  - 旧小屋没有任何记录/照片 → 直接清理（和原来一样）；
  - 旧小屋有记录/照片 → 网页会先弹窗列出旧小屋内容，用户点确定后
    调用本函数（p_drop_old = true），把旧小屋的云端记录、照片记录、
    照片文件、成员记录、空小屋一起删除，再加入新小屋。

  安全：只有当旧小屋没有其他成员时才会清理；删除前由网页弹窗让用户确认。

  在 Supabase SQL Editor 中完整运行一次即可。
*/

drop function if exists public.xj_switch_house(text, text);

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
  on conflict (house_id, user_id) do update
    set display_name = excluded.display_name;

  return query select v_house.id, v_house.name, v_house.invite_code;
end;
$$;

revoke all on function public.xj_switch_house(text, text, boolean) from public;
grant execute on function public.xj_switch_house(text, text, boolean) to authenticated;
