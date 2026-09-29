-- ============================================
-- 迁移 010：成员可以修改自己在小屋里的称呼
-- ============================================

drop policy if exists xj_members_update_self on public.xj_house_members;
create policy xj_members_update_self
  on public.xj_house_members for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- 验证：
-- update public.xj_house_members set display_name = '测试' where user_id = auth.uid();
