-- ============================================
-- 迁移 009：小屋自定义图标（方案 B）
-- 给 xj_houses 表加 icon 字段，并放开成员更新权限
-- ============================================

-- 1) 小屋表加图标字段（默认小房子，成员可改）
alter table public.xj_houses
  add column if not exists icon text not null default '🏡';

-- 2) 小屋成员可以更新小屋资料（名字/图标）
drop policy if exists xj_houses_update_member on public.xj_houses;
create policy xj_houses_update_member
  on public.xj_houses for update to authenticated
  using ((select public.xj_is_house_member(id)))
  with check ((select public.xj_is_house_member(id)));

-- 验证：
-- select id, name, icon from public.xj_houses;
