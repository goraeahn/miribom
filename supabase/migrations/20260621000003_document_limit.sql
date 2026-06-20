-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 3) 사용자별 원고 20개 상한 (서버 강제)
-- ----------------------------------------------------------------------------
-- 봇/우회 방지: 프론트의 버튼 비활성화만으로는 막을 수 없으므로,
--   DB 트리거로 21번째 insert 를 거부한다(실제 방어선).
-- ============================================================================

create or replace function public.enforce_document_limit()
returns trigger
language plpgsql
security definer            -- RLS 영향 없이 사용자의 전체 보유 수를 센다
set search_path = public
as $$
declare
  cnt integer;
begin
  select count(*) into cnt
    from public.documents
   where owner_id = new.owner_id;

  if cnt >= 20 then
    raise exception 'document_limit_reached (max 20 documents per user)'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists documents_limit_before_insert on public.documents;
create trigger documents_limit_before_insert
  before insert on public.documents
  for each row execute function public.enforce_document_limit();

comment on function public.enforce_document_limit() is
  '사용자(owner_id)당 documents 최대 20개. 21번째 insert 를 서버에서 거부.';
