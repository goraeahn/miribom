-- ============================================================================
-- 미리봄 — 9) 방문 카운터 (visits) : 페이지 로드마다 1건 기록. keep-alive 겸용.
-- ----------------------------------------------------------------------------
-- 설계(개인정보 최소):
--   - 경로(pathname)와 시각(created_at)만 기록. IP·브라우저(UA)·쿼리(공유토큰) 미기록.
--   - 비로그인 방문자도 '기록(insert)'만 가능. 읽기 권한은 주지 않음
--     → 방문자는 카운트를 못 봄. 숫자는 사장님이 SQL Editor에서 확인.
--   - 봇이 부풀릴 수 있으니 '참고용' 수치(보안·정산용 아님).
--   - 부수효과: 방문이 곧 DB 활동 → 무료 플랜 7일 일시정지 방지(keep-alive) 겸용.
--
-- 적용: Supabase 대시보드 → SQL Editor 에 붙여넣고 실행.
-- ============================================================================

create table if not exists public.visits (
  id         uuid primary key default gen_random_uuid(),
  path       text,
  created_at timestamptz not null default now()
);
create index if not exists visits_created_idx on public.visits (created_at);

alter table public.visits enable row level security;

-- 누구나(비로그인 포함) 방문 1건 '기록(insert)'만 가능. 읽기(select)는 주지 않는다.
drop policy if exists visits_insert_any on public.visits;
create policy visits_insert_any on public.visits
  for insert to anon, authenticated with check (true);

grant insert on public.visits to anon, authenticated;

-- ----------------------------------------------------------------------------
-- today_visits() : 오늘(한국시간) 방문 수만 정수로 반환.
--   - 로그인 사용자가 화면에 "오늘의 방문자 N명"을 띄우는 용도.
--   - SECURITY DEFINER 라 방문 로그 원본은 안 열고 '합계 숫자'만 돌려준다.
-- ----------------------------------------------------------------------------
create or replace function public.today_visits()
returns integer
language sql
security definer
set search_path = public
as $$
  select count(*)::int from public.visits
   where (created_at at time zone 'Asia/Seoul')::date = (now() at time zone 'Asia/Seoul')::date;
$$;

grant execute on function public.today_visits() to authenticated;

-- ── 보는 법(사장님, SQL Editor에서) ─────────────────────────────
--   전체 방문수:   select count(*) from public.visits;
--   오늘:          select count(*) from public.visits where created_at >= current_date;
--   최근 7일:      select count(*) from public.visits where created_at >= now() - interval '7 days';
--   일자별:        select date(created_at) as 날짜, count(*) as 방문
--                    from public.visits group by 1 order by 1 desc limit 30;
--   페이지별:      select path, count(*) from public.visits group by 1 order by 2 desc;
