-- ============================================
-- 迁移 012：修复上传照片/小屋头像/聊天发图报错
-- "违反检查约束 xj_photos_record_kind_check"
-- 原因：旧约束只允许 meal/sport/diary/wall，
--       新功能上传小屋头像(house_icon)、聊天发图(chat)被拒
-- ============================================

alter table public.xj_photos
  drop constraint if exists xj_photos_record_kind_check;

alter table public.xj_photos
  add constraint xj_photos_record_kind_check
  check (record_kind in ('meal', 'sport', 'diary', 'wall', 'chat', 'house_icon'));

-- 验证：select record_kind, count(*) from public.xj_photos group by record_kind;
