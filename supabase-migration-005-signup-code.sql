/*
  小佳专属小屋：注册通行码保护（迁移 005）

  用途：
  - 新用户注册时，必须输入正确的「通行码」才能注册成功；
  - 通行码存在云端数据库里（不在网页代码中，别人扒源码也找不到）；
  - 老用户登录不需要通行码。

  换通行码的方法（想换时在 SQL Editor 运行下面这句，把 NEWCODE 换成新码）：
    update public.xj_app_config set value = 'NEWCODE' where key = 'signup_code';

  在 Supabase SQL Editor 中完整运行一次即可。
  注意：运行前先把下面的 CHANGE_ME 换成你自己的通行码；已上线的项目再次运行会覆盖现有通行码。
*/

create table if not exists public.xj_app_config (
  key text primary key,
  value text not null
);

insert into public.xj_app_config(key, value)
values ('signup_code', 'CHANGE_ME')
on conflict (key) do update set value = excluded.value;

create or replace function public.xj_check_signup_code(p_code text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select (select value from public.xj_app_config where key = 'signup_code') = coalesce(p_code, '')
$$;

revoke all on function public.xj_check_signup_code(text) from public;
grant execute on function public.xj_check_signup_code(text) to anon, authenticated;
