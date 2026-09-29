-- ============================================
-- 迁移 011：聊天支持发图片
-- ============================================

alter table public.xj_messages
  add column if not exists photo_path text;

-- 验证：
-- select id, content, photo_path from public.xj_messages order by created_at desc limit 5;
