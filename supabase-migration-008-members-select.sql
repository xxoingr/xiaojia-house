/*
  小佳专属小屋：成员表权限调整（迁移 008）

  原因：
  原策略只允许成员查询自己那一行（xj_members_select_self），
  导致「聊天备注」功能查不到对方账号，必须先聊天才能备注。

  调整：同一个小屋的成员可以互相查看成员信息（仍然只有本屋成员能看）。
  安全性：仅限小屋成员（xj_is_house_member 校验），不影响其他小屋。

  在 Supabase SQL Editor 中完整运行一次即可。
*/

drop policy if exists xj_members_select_self on public.xj_house_members;

drop policy if exists xj_members_select_member on public.xj_house_members;
create policy xj_members_select_member
  on public.xj_house_members for select to authenticated
  using ((select public.xj_is_house_member(house_id)));
