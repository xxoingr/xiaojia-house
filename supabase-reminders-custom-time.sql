/*
  小佳专属小屋：允许待办提醒使用自定义的分钟数。
  旧的 30/48 小时提醒会保留；reminder_hours 只作为旧字段和快捷选项兼容。
*/
alter table public.xj_todo_reminders
  alter column reminder_hours drop not null;

alter table public.xj_todo_reminders
  drop constraint if exists xj_todo_reminders_reminder_hours_check;

alter table public.xj_todo_reminders
  add column if not exists reminder_minutes integer;

update public.xj_todo_reminders
set reminder_minutes = reminder_hours * 60
where reminder_minutes is null
  and reminder_hours is not null;

alter table public.xj_todo_reminders
  alter column reminder_minutes set not null;

alter table public.xj_todo_reminders
  add constraint xj_todo_reminders_reminder_minutes_check
  check (reminder_minutes between 1 and 525600);

alter table public.xj_todo_reminders
  add constraint xj_todo_reminders_reminder_hours_check
  check (reminder_hours is null or reminder_hours in (30,48));

create index if not exists xj_todo_reminders_created_by_idx
  on public.xj_todo_reminders(created_by);
